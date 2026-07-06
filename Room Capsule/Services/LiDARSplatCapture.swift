import Foundation
@preconcurrency import ARKit
import simd

/// LiDAR 深度 + カメラ映像から「面に沿った扁平ガウス」を集めるスプラットスキャナ。
///
/// 学習(最適化)は行わないが、以下で見た目を学習済み 3DGS に近づけている:
/// - 深度マップから法線を推定し、球ではなく表面に張り付く円盤状のガウスとして書き出す
/// - 1cm ボクセルで重複排除しつつ全深度ピクセルをサンプリング(最大 100 万点)
/// - 近くで撮れたサンプルを優先する距離重み付きの色平均
/// - 書き出し時に孤立ボクセル(フローター)を除去
struct LiDARSplatPreviewChunk: Sendable {
    var startIndex: Int
    var previewCount: Int
    var totalPointCount: Int
    var positions: [Float]
    var colors: [UInt8]
}

struct LiDARSplatExport: Sendable {
    var data: Data
    var count: Int
}

final class LiDARSplatAccumulator: @unchecked Sendable {

    /// LiDAR 深度(sceneDepth)が使える端末か
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// 重複排除のボクセルサイズ(m)
    let voxelSize: Float = 0.01
    /// レンダラ(GaussianSplatLoader.maxSplats)と揃えた上限
    let maxPoints = 1_000_000

    private struct VoxelSample {
        var position: SIMD3<Float>
        /// 距離重み付きの色合計
        var colorSum: SIMD3<Float>
        var weightSum: Float
        /// 法線の合計(向きの平均に使う。ゼロなら等方ガウスで書き出す)
        var normalSum: SIMD3<Float>
        var sampleCount: UInt16
    }

    private var voxels: [Int64: VoxelSample] = [:]

    // ライブプレビュー用の追記専用配列(新規ボクセルの初回サンプルのみ。
    // 色の平均化や法線の更新は反映しない — プレビュー用途なので十分)
    private(set) var previewPositions: [Float] = []
    private(set) var previewColors: [UInt8] = []
    var previewCount: Int { previewPositions.count / 3 }

    var pointCount: Int { voxels.count }
    var isFull: Bool { voxels.count >= maxPoints }

    func ingestAndMakePreviewChunk(frame: ARFrame, from startIndex: Int) -> LiDARSplatPreviewChunk {
        ingest(frame: frame)
        return previewChunk(from: startIndex)
    }

    func previewChunk(from startIndex: Int) -> LiDARSplatPreviewChunk {
        let endIndex = min(previewCount, maxPoints)
        let startIndex = min(max(startIndex, 0), endIndex)
        guard endIndex > startIndex else {
            return LiDARSplatPreviewChunk(
                startIndex: startIndex,
                previewCount: endIndex,
                totalPointCount: pointCount,
                positions: [],
                colors: []
            )
        }

        return LiDARSplatPreviewChunk(
            startIndex: startIndex,
            previewCount: endIndex,
            totalPointCount: pointCount,
            positions: Array(previewPositions[(startIndex * 3)..<(endIndex * 3)]),
            colors: Array(previewColors[(startIndex * 4)..<(endIndex * 4)])
        )
    }

    // MARK: - フレーム取り込み

    /// 1 フレームぶんの深度を点として取り込む(呼び出し側で 0.1〜0.2 秒間隔に間引く)
    func ingest(frame: ARFrame) {
        guard !isFull else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidenceMap = depthData.confidenceMap else { return }

        let depthMap = depthData.depthMap
        let image = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(image) >= 2 else { return }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap),
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)

        let imageWidth = CVPixelBufferGetWidth(image)
        let imageHeight = CVPixelBufferGetHeight(image)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)

        let depth = depthBase.assumingMemoryBound(to: Float32.self)
        let confidence = confidenceBase.assumingMemoryBound(to: UInt8.self)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // intrinsics は capturedImage の解像度基準
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let cameraToWorld = frame.camera.transform
        let rotationToWorld = simd_float3x3(
            SIMD3<Float>(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
            SIMD3<Float>(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
            SIMD3<Float>(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        )

        let scaleX = Float(imageWidth) / Float(depthWidth)
        let scaleY = Float(imageHeight) / Float(depthHeight)

        // 全深度ピクセルをサンプリング(256×192 ≈ 4.9 万点 / tick)
        var y = 0
        while y < depthHeight {
            var x = 0
            while x < depthWidth {
                defer { x += 1 }

                // 信頼度 high のみ採用
                guard confidence[y * confidenceStride + x] >= UInt8(ARConfidenceLevel.high.rawValue) else { continue }
                let d = depth[y * depthStride + x]
                guard d.isFinite, d > 0.2, d < 5.0 else { continue }

                // 深度ピクセル → capturedImage ピクセル → カメラ空間(画像系: y 下・z 前)
                let px = (Float(x) + 0.5) * scaleX
                let py = (Float(y) + 0.5) * scaleY
                let local = SIMD3<Float>((px - cx) / fx * d, (py - cy) / fy * d, d)
                // 画像座標系 → ARKit カメラ座標系(y 上・z 手前)
                let cameraPoint = SIMD3<Float>(local.x, -local.y, -local.z)
                let world4 = cameraToWorld * SIMD4<Float>(cameraPoint.x, cameraPoint.y, cameraPoint.z, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)

                let key = voxelKey(world)
                let existing = voxels[key]
                if let sample = existing, sample.sampleCount >= 6 { continue }
                if existing == nil, voxels.count >= maxPoints { continue }

                // 右・下の隣接ピクセルから面の法線を推定(深度の段差があればスキップ)
                var normalWorld = SIMD3<Float>(repeating: 0)
                if x + 1 < depthWidth, y + 1 < depthHeight {
                    let dRight = depth[y * depthStride + x + 1]
                    let dDown = depth[(y + 1) * depthStride + x]
                    let tolerance = max(0.03, d * 0.03)
                    if dRight.isFinite, dDown.isFinite,
                       abs(dRight - d) < tolerance, abs(dDown - d) < tolerance {
                        let pxRight = (Float(x) + 1.5) * scaleX
                        let pyDown = (Float(y) + 1.5) * scaleY
                        let localRight = SIMD3<Float>((pxRight - cx) / fx * dRight, (py - cy) / fy * dRight, dRight)
                        let localDown = SIMD3<Float>((px - cx) / fx * dDown, (pyDown - cy) / fy * dDown, dDown)
                        let cameraRight = SIMD3<Float>(localRight.x, -localRight.y, -localRight.z)
                        let cameraDown = SIMD3<Float>(localDown.x, -localDown.y, -localDown.z)
                        let cross = simd_cross(cameraRight - cameraPoint, cameraDown - cameraPoint)
                        if simd_length_squared(cross) > 1e-14 {
                            var normalCamera = simd_normalize(cross)
                            // カメラ側(視線の逆)を向かせる
                            if simd_dot(normalCamera, cameraPoint) > 0 {
                                normalCamera = -normalCamera
                            }
                            normalWorld = rotationToWorld * normalCamera
                        }
                    }
                }

                // 近くで撮れたサンプルほど色の重みを大きくする
                let weight = min(1.0 / max(d, 0.3), 3.0)
                let rgb = sampleColor(
                    px: Int(px), py: Int(py),
                    luma: luma, lumaStride: lumaStride,
                    chroma: chroma, chromaStride: chromaStride,
                    width: imageWidth, height: imageHeight
                )

                if var sample = existing {
                    sample.colorSum += rgb * weight
                    sample.weightSum += weight
                    sample.normalSum += normalWorld
                    sample.sampleCount += 1
                    voxels[key] = sample
                } else {
                    voxels[key] = VoxelSample(
                        position: world,
                        colorSum: rgb * weight,
                        weightSum: weight,
                        normalSum: normalWorld,
                        sampleCount: 1
                    )
                    // ライブプレビューへ追記
                    previewPositions.append(world.x)
                    previewPositions.append(world.y)
                    previewPositions.append(world.z)
                    previewColors.append(UInt8(min(max(rgb.x, 0), 1) * 255))
                    previewColors.append(UInt8(min(max(rgb.y, 0), 1) * 255))
                    previewColors.append(UInt8(min(max(rgb.z, 0), 1) * 255))
                    previewColors.append(235)
                }
            }
            y += 1
        }
    }

    // MARK: - .splat 書き出し

    /// フローターを除去し、法線があれば面に沿った扁平ガウスとしてエンコードする。
    /// 3DGS の慣例(y 下向き)に合わせて位置・法線の y / z を反転
    /// (ビューア側の反転補正で正立する)。
    func makeSplatData() -> Data {
        let survivors = pruneFloaters()

        // 面に沿う円盤(接線方向 × 2、法線方向は薄く)
        let tangentSigma = voxelSize * 1.0
        let normalSigma = voxelSize * 0.2
        let isotropicSigma = voxelSize * 0.8
        let zAxis = SIMD3<Float>(0, 0, 1)

        var bytes = [UInt8](repeating: 0, count: survivors.count * 32)
        bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            for sample in survivors {
                raw.storeBytes(of: sample.position.x, toByteOffset: offset + 0, as: Float32.self)
                raw.storeBytes(of: -sample.position.y, toByteOffset: offset + 4, as: Float32.self)
                raw.storeBytes(of: -sample.position.z, toByteOffset: offset + 8, as: Float32.self)

                // 法線が取れていれば扁平ガウス + 向きのクォータニオン、なければ等方
                var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                var scales = SIMD3<Float>(repeating: isotropicSigma)
                let normalLengthSquared = simd_length_squared(sample.normalSum)
                if normalLengthSquared > 1e-6 {
                    // 位置と同じ y/z 反転を法線にも適用してから向きを作る
                    let n = simd_normalize(sample.normalSum)
                    let flippedNormal = SIMD3<Float>(n.x, -n.y, -n.z)
                    if simd_dot(zAxis, flippedNormal) < -0.999 {
                        rotation = simd_quatf(angle: .pi, axis: [1, 0, 0])
                    } else {
                        rotation = simd_quatf(from: zAxis, to: flippedNormal)
                    }
                    scales = SIMD3<Float>(tangentSigma, tangentSigma, normalSigma)
                }
                raw.storeBytes(of: scales.x, toByteOffset: offset + 12, as: Float32.self)
                raw.storeBytes(of: scales.y, toByteOffset: offset + 16, as: Float32.self)
                raw.storeBytes(of: scales.z, toByteOffset: offset + 20, as: Float32.self)

                let color = sample.colorSum / max(sample.weightSum, 1e-4)
                raw[offset + 24] = UInt8(min(max(color.x, 0), 1) * 255)
                raw[offset + 25] = UInt8(min(max(color.y, 0), 1) * 255)
                raw[offset + 26] = UInt8(min(max(color.z, 0), 1) * 255)
                raw[offset + 27] = 245 // alpha ≈ 0.96

                // クォータニオンは (w, x, y, z) を v*128+128 でエンコード
                raw[offset + 28] = quantize(rotation.real)
                raw[offset + 29] = quantize(rotation.imag.x)
                raw[offset + 30] = quantize(rotation.imag.y)
                raw[offset + 31] = quantize(rotation.imag.z)

                offset += 32
            }
        }
        return Data(bytes)
    }

    func makeSplatExport() -> LiDARSplatExport {
        let data = makeSplatData()
        return LiDARSplatExport(data: data, count: data.count / 32)
    }

    func reset() {
        voxels.removeAll(keepingCapacity: true)
        previewPositions.removeAll(keepingCapacity: true)
        previewColors.removeAll(keepingCapacity: true)
    }

    // MARK: - 内部

    @inline(__always)
    private func quantize(_ value: Float) -> UInt8 {
        UInt8(min(max(value * 128 + 128, 0), 255))
    }

    /// 26 近傍に 2 個以上の点がないボクセルをノイズ(フローター)として除去
    private func pruneFloaters() -> [VoxelSample] {
        guard voxels.count > 1_000 else { return Array(voxels.values) }
        var kept: [VoxelSample] = []
        kept.reserveCapacity(voxels.count)

        let mask: Int64 = 0x1F_FFFF
        for (key, sample) in voxels {
            let qx = (key >> 42) & mask
            let qy = (key >> 21) & mask
            let qz = key & mask
            var neighbors = 0
            outer: for dx in Int64(-1)...1 {
                for dy in Int64(-1)...1 {
                    for dz in Int64(-1)...1 {
                        if dx == 0 && dy == 0 && dz == 0 { continue }
                        let neighborKey = (((qx + dx) & mask) << 42)
                            | (((qy + dy) & mask) << 21)
                            | ((qz + dz) & mask)
                        if voxels[neighborKey] != nil {
                            neighbors += 1
                            if neighbors >= 2 { break outer }
                        }
                    }
                }
            }
            if neighbors >= 2 {
                kept.append(sample)
            }
        }
        return kept
    }

    @inline(__always)
    private func voxelKey(_ p: SIMD3<Float>) -> Int64 {
        // 21bit × 3 軸(1cm ボクセルで ±10km までカバー)
        let qx = (Int64((p.x / voxelSize).rounded()) + 1_048_576) & 0x1F_FFFF
        let qy = (Int64((p.y / voxelSize).rounded()) + 1_048_576) & 0x1F_FFFF
        let qz = (Int64((p.z / voxelSize).rounded()) + 1_048_576) & 0x1F_FFFF
        return (qx << 42) | (qy << 21) | qz
    }

    /// capturedImage(YCbCr フルレンジ)から RGB(0...1)をサンプリング
    @inline(__always)
    private func sampleColor(
        px: Int, py: Int,
        luma: UnsafePointer<UInt8>, lumaStride: Int,
        chroma: UnsafePointer<UInt8>, chromaStride: Int,
        width: Int, height: Int
    ) -> SIMD3<Float> {
        let sx = min(max(px, 0), width - 1)
        let sy = min(max(py, 0), height - 1)
        let yValue = Float(luma[sy * lumaStride + sx]) / 255
        let chromaIndex = (sy / 2) * chromaStride + (sx / 2) * 2
        let cb = Float(chroma[chromaIndex]) / 255 - 0.5
        let cr = Float(chroma[chromaIndex + 1]) / 255 - 0.5
        return SIMD3<Float>(
            yValue + 1.402 * cr,
            yValue - 0.344136 * cb - 0.714136 * cr,
            yValue + 1.772 * cb
        )
    }
}
