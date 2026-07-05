import Foundation
import ARKit
import simd

/// LiDAR 深度 + カメラ映像から色付きの点を集めて .splat を作る簡易スキャナ。
/// 本物の 3DGS 学習(最適化)は行わず、点を小さな等方ガウスとして書き出す。
/// 品質は学習済み 3DGS に及ばないが、外部アプリなしで「色付きの自分の部屋」が作れる。
@MainActor
final class LiDARSplatAccumulator {

    /// LiDAR 深度(sceneDepth)が使える端末か
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// 重複排除のボクセルサイズ(m)。この間隔で 1 点だけ残す
    let voxelSize: Float = 0.02
    /// メモリと描画負荷の上限
    let maxPoints = 600_000

    private struct VoxelSample {
        var position: SIMD3<Float>
        var redSum: Float
        var greenSum: Float
        var blueSum: Float
        var sampleCount: UInt16
    }

    private var voxels: [Int64: VoxelSample] = [:]

    var pointCount: Int { voxels.count }
    var isFull: Bool { voxels.count >= maxPoints }

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

        let scaleX = Float(imageWidth) / Float(depthWidth)
        let scaleY = Float(imageHeight) / Float(depthHeight)

        // 深度マップを 2 ピクセルおきにサンプリング(1 tick あたり約 1.2 万点)
        var y = 0
        while y < depthHeight {
            var x = 0
            while x < depthWidth {
                defer { x += 2 }

                // 信頼度 high のみ採用
                guard confidence[y * confidenceStride + x] >= UInt8(ARConfidenceLevel.high.rawValue) else { continue }
                let d = depth[y * depthStride + x]
                guard d.isFinite, d > 0.2, d < 5.0 else { continue }

                // 深度ピクセル → capturedImage ピクセル → カメラ空間 → ワールド
                let px = (Float(x) + 0.5) * scaleX
                let py = (Float(y) + 0.5) * scaleY
                let local = SIMD3<Float>((px - cx) / fx * d, (py - cy) / fy * d, d)
                // 画像座標系(y 下・z 前)→ ARKit カメラ座標系(y 上・z 手前)
                let cameraPoint = SIMD4<Float>(local.x, -local.y, -local.z, 1)
                let world4 = cameraToWorld * cameraPoint
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)

                let key = voxelKey(world)
                if var sample = voxels[key] {
                    // 同じボクセルは色だけなじませる(最大 4 サンプル平均)
                    if sample.sampleCount < 4 {
                        let rgb = sampleColor(
                            px: Int(px), py: Int(py),
                            luma: luma, lumaStride: lumaStride,
                            chroma: chroma, chromaStride: chromaStride,
                            width: imageWidth, height: imageHeight
                        )
                        sample.redSum += rgb.x
                        sample.greenSum += rgb.y
                        sample.blueSum += rgb.z
                        sample.sampleCount += 1
                        voxels[key] = sample
                    }
                } else if voxels.count < maxPoints {
                    let rgb = sampleColor(
                        px: Int(px), py: Int(py),
                        luma: luma, lumaStride: lumaStride,
                        chroma: chroma, chromaStride: chromaStride,
                        width: imageWidth, height: imageHeight
                    )
                    voxels[key] = VoxelSample(
                        position: world,
                        redSum: rgb.x, greenSum: rgb.y, blueSum: rgb.z,
                        sampleCount: 1
                    )
                }
            }
            y += 2
        }
    }

    // MARK: - .splat 書き出し

    /// 集めた点を等方ガウスの .splat としてエンコードする。
    /// 3DGS の慣例(y 下向き)に合わせて y / z を反転(ビューア側の反転補正で正立)。
    func makeSplatData() -> Data {
        var data = Data(capacity: voxels.count * 32)

        func appendFloat(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        // ボクセル間の隙間が埋まる程度の等方ガウス
        let sigma = voxelSize * 0.8

        for sample in voxels.values {
            appendFloat(sample.position.x)
            appendFloat(-sample.position.y)
            appendFloat(-sample.position.z)
            appendFloat(sigma)
            appendFloat(sigma)
            appendFloat(sigma)
            let n = Float(sample.sampleCount)
            data.append(UInt8(min(max(sample.redSum / n, 0), 1) * 255))
            data.append(UInt8(min(max(sample.greenSum / n, 0), 1) * 255))
            data.append(UInt8(min(max(sample.blueSum / n, 0), 1) * 255))
            data.append(242) // alpha ≈ 0.95
            // 単位クォータニオン (w, x, y, z) = (1, 0, 0, 0)
            data.append(255)
            data.append(128)
            data.append(128)
            data.append(128)
        }
        return data
    }

    func reset() {
        voxels.removeAll(keepingCapacity: true)
    }

    // MARK: - 内部

    @inline(__always)
    private func voxelKey(_ p: SIMD3<Float>) -> Int64 {
        // 21bit × 3 軸(2cm ボクセルで ±20km までカバー)
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
