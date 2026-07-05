import Foundation
import simd

// MARK: - Gaussian Splatting 実レンダリング用データ

/// Metal レンダラーが描画する Gaussian の集合。
/// 位置は重心原点へ再センタリング済み。3D 共分散は CPU 側で事前計算する
/// (Σ = R・diag(s²)・Rᵀ。GPU では毎フレーム 2D へ投影するだけにする)。
nonisolated struct GaussianSplatCloud: Sendable {
    var count: Int
    /// x, y, z × count
    var positions: [Float]
    /// xx, xy, xz, yy, yz, zz × count(対称行列の上三角)
    var covariances: [Float]
    /// r, g, b, a × count(a = 不透明度)
    var colors: [UInt8]
    var boundingRadius: Float
    var totalPointCount: Int

    var isSubsampled: Bool { count < totalPointCount }
}

// MARK: - ローダー

/// .splat / 3DGS .ply から位置・スケール・回転・不透明度まで読み込み、
/// 実レンダリングに必要な 3D 共分散を構築する。
/// scale / rot 属性を持たない普通の PLY 点群は扱えない(点群プレビューへフォールバック)。
nonisolated enum GaussianSplatLoader {

    /// 実レンダリングの最大スプラット数(超えたら等間隔に間引く)
    static let maxSplats = 1_000_000

    static func load(url: URL, fileType: SplatFileType) throws -> GaussianSplatCloud {
        switch fileType {
        case .splat:
            return try loadDotSplat(url: url)
        case .ply:
            return try loadGaussianPLY(url: url)
        case .spz:
            throw SplatLoadError.unsupportedFormat(".spz(gzip 圧縮)の展開はこのビルドでは未対応です")
        }
    }

    // MARK: 共分散の事前計算

    /// Σ = (R diag(s)) (R diag(s))ᵀ を上三角 6 成分で返す
    private static func covariance(scale: SIMD3<Float>, rotation: simd_quatf) -> (SIMD3<Float>, SIMD3<Float>) {
        let R = simd_float3x3(simd_normalize(rotation))
        let M = simd_matrix(R.columns.0 * scale.x, R.columns.1 * scale.y, R.columns.2 * scale.z)
        let S = M * M.transpose
        // (xx, xy, xz), (yy, yz, zz)
        return (
            SIMD3<Float>(S.columns.0.x, S.columns.1.x, S.columns.2.x),
            SIMD3<Float>(S.columns.1.y, S.columns.2.y, S.columns.2.z)
        )
    }

    // MARK: .splat(pos float3 / scale float3 / color rgba u8 / rot quat u8)

    private static func loadDotSplat(url: URL) throws -> GaussianSplatCloud {
        let data = try Data(contentsOf: url)
        let recordSize = 32
        let total = data.count / recordSize
        guard total > 0 else {
            throw SplatLoadError.corruptFile(".splat のレコードが見つかりません")
        }
        let step = max(1, (total + maxSplats - 1) / maxSplats)

        var builder = Builder(capacity: total / step + 1)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i < total {
                let base = i * recordSize
                let position = SIMD3<Float>(
                    raw.loadUnaligned(fromByteOffset: base + 0, as: Float32.self),
                    raw.loadUnaligned(fromByteOffset: base + 4, as: Float32.self),
                    raw.loadUnaligned(fromByteOffset: base + 8, as: Float32.self)
                )
                let scale = SIMD3<Float>(
                    raw.loadUnaligned(fromByteOffset: base + 12, as: Float32.self),
                    raw.loadUnaligned(fromByteOffset: base + 16, as: Float32.self),
                    raw.loadUnaligned(fromByteOffset: base + 20, as: Float32.self)
                )
                // 回転は (w, x, y, z) の順で (v*128+128) エンコード
                let rotation = simd_quatf(
                    ix: (Float(raw[base + 29]) - 128) / 128,
                    iy: (Float(raw[base + 30]) - 128) / 128,
                    iz: (Float(raw[base + 31]) - 128) / 128,
                    r: (Float(raw[base + 28]) - 128) / 128
                )
                if position.x.isFinite && position.y.isFinite && position.z.isFinite,
                   scale.x.isFinite && scale.y.isFinite && scale.z.isFinite {
                    let (covA, covB) = covariance(scale: scale, rotation: rotation)
                    builder.append(
                        position: position,
                        covA: covA,
                        covB: covB,
                        r: raw[base + 24], g: raw[base + 25], b: raw[base + 26], a: raw[base + 27]
                    )
                }
                i += step
            }
        }
        return builder.finalize(totalPointCount: total)
    }

    // MARK: 3DGS .ply(scale_0..2 / rot_0..3 / opacity / f_dc_0..2)

    private static func loadGaussianPLY(url: URL) throws -> GaussianSplatCloud {
        let data = try Data(contentsOf: url)
        let header = try PLYHeader.parse(data)

        guard let xIndex = header.index(of: "x"),
              let yIndex = header.index(of: "y"),
              let zIndex = header.index(of: "z") else {
            throw SplatLoadError.corruptFile("PLY に x/y/z プロパティがありません")
        }
        guard let s0 = header.index(of: "scale_0"),
              let s1 = header.index(of: "scale_1"),
              let s2 = header.index(of: "scale_2"),
              let r0 = header.index(of: "rot_0"),
              let r1 = header.index(of: "rot_1"),
              let r2 = header.index(of: "rot_2"),
              let r3 = header.index(of: "rot_3") else {
            throw SplatLoadError.unsupportedFormat("3DGS の scale / rot 属性がない PLY です(点群プレビューで表示します)")
        }
        let opacityIndex = header.index(of: "opacity")
        let colorReader = PLYColorReader(header: header)
        let step = max(1, (header.vertexCount + maxSplats - 1) / maxSplats)

        var builder = Builder(capacity: header.vertexCount / step + 1)

        try header.forEachRecord(in: data, step: step) { values in
            let position = SIMD3<Float>(values[xIndex], values[yIndex], values[zIndex])
            guard position.x.isFinite && position.y.isFinite && position.z.isFinite else { return }
            // 3DGS はスケールを log 空間、不透明度をロジットで持つ
            let scale = SIMD3<Float>(exp(values[s0]), exp(values[s1]), exp(values[s2]))
            let rotation = simd_quatf(ix: values[r1], iy: values[r2], iz: values[r3], r: values[r0])
            let alpha: Float = opacityIndex.map { 1 / (1 + exp(-values[$0])) } ?? 1
            let rgb = colorReader.color(from: values)
            let (covA, covB) = covariance(scale: scale, rotation: rotation)
            builder.append(
                position: position,
                covA: covA,
                covB: covB,
                r: UInt8(rgb.x * 255), g: UInt8(rgb.y * 255), b: UInt8(rgb.z * 255),
                a: UInt8(simd_clamp(alpha, 0, 1) * 255)
            )
        }
        return builder.finalize(totalPointCount: header.vertexCount)
    }

    // MARK: 共通ビルダー(再センタリング + 配列パック)

    private struct Builder {
        var rawPositions: [SIMD3<Float>] = []
        var covariances: [Float] = []
        var colors: [UInt8] = []

        init(capacity: Int) {
            rawPositions.reserveCapacity(capacity)
            covariances.reserveCapacity(capacity * 6)
            colors.reserveCapacity(capacity * 4)
        }

        mutating func append(
            position: SIMD3<Float>,
            covA: SIMD3<Float>,
            covB: SIMD3<Float>,
            r: UInt8, g: UInt8, b: UInt8, a: UInt8
        ) {
            rawPositions.append(position)
            covariances.append(covA.x)
            covariances.append(covA.y)
            covariances.append(covA.z)
            covariances.append(covB.x)
            covariances.append(covB.y)
            covariances.append(covB.z)
            colors.append(r)
            colors.append(g)
            colors.append(b)
            colors.append(a)
        }

        func finalize(totalPointCount: Int) -> GaussianSplatCloud {
            let count = rawPositions.count
            guard count > 0 else {
                return GaussianSplatCloud(
                    count: 0, positions: [], covariances: [], colors: [],
                    boundingRadius: 1, totalPointCount: totalPointCount
                )
            }
            var centroid = SIMD3<Float>(repeating: 0)
            for p in rawPositions {
                centroid += p
            }
            centroid /= Float(count)

            var positions = [Float](repeating: 0, count: count * 3)
            var maxDistanceSquared: Float = 0
            for (i, p) in rawPositions.enumerated() {
                let c = p - centroid
                positions[3 * i + 0] = c.x
                positions[3 * i + 1] = c.y
                positions[3 * i + 2] = c.z
                maxDistanceSquared = max(maxDistanceSquared, simd_length_squared(c))
            }
            return GaussianSplatCloud(
                count: count,
                positions: positions,
                covariances: covariances,
                colors: colors,
                boundingRadius: max(sqrt(maxDistanceSquared), 0.5),
                totalPointCount: totalPointCount
            )
        }
    }
}
