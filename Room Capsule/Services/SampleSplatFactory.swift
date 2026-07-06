import Foundation
import simd

/// 手続き生成の「サンプルルーム」.splat を作るファクトリ。
/// Gaussian Splatting データを持っていなくても実レンダリングを体験できるようにする
/// (シミュレータでの動作確認にも使う)。
@MainActor
enum SampleSplatFactory {

    /// サンプル .splat を生成して Documents に保存し、指定バージョンに紐づける
    @discardableResult
    static func generateAndAttach(capsuleID: UUID, versionID: UUID, store: RoomCapsuleStore) throws -> SplatAsset {
        let data = makeSampleRoomSplatData()
        let dir = AppFiles.ensureDirectory(
            AppFiles.capsuleDirectoryURL(capsuleID: capsuleID).appendingPathComponent("splats", isDirectory: true)
        )
        let id = UUID()
        let fileName = "\(id.uuidString).splat"
        let url = dir.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)

        let asset = SplatAsset(
            id: id,
            fileName: "サンプルルーム.splat",
            relativePath: AppFiles.relativePath(capsuleID: capsuleID, "splats", fileName),
            fileType: .splat,
            importedAt: Date(),
            fileSizeBytes: Int64(data.count)
        )
        do {
            try store.attachSplat(asset, to: capsuleID, versionID: versionID)
        } catch {
            AppFiles.removeIfExists(url)
            throw error
        }
        return asset
    }

    // MARK: - 生成本体

    private struct Record {
        var position: SIMD3<Float> // y-up の作業座標系
        var scale: SIMD3<Float>
        var color: SIMD3<Float>    // 0...1
        var alpha: Float
    }

    /// 決定的な擬似乱数(毎回同じ見た目のサンプルになる)
    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }
        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(state % 1_000_000) / 1_000_000
        }
        mutating func range(_ r: ClosedRange<Float>) -> Float {
            r.lowerBound + next() * (r.upperBound - r.lowerBound)
        }
    }

    /// デモ部屋と同じ 4m × 3m・高さ 2.4m のワンルームをスプラットで描く
    static func makeSampleRoomSplatData() -> Data {
        var records: [Record] = []
        records.reserveCapacity(40_000)
        var rng = SeededRandom(seed: 42)

        func noise(_ amount: Float) -> Float {
            rng.range(-amount...amount)
        }

        // --- 床(フローリング) ---
        let wood = SIMD3<Float>(0.55, 0.40, 0.27)
        for x in stride(from: Float(-2.0), through: 2.0, by: 0.055) {
            for z in stride(from: Float(-1.5), through: 1.5, by: 0.055) {
                records.append(Record(
                    position: [x + noise(0.01), 0.012, z + noise(0.01)],
                    scale: [0.034, 0.006, 0.034],
                    color: wood + SIMD3(repeating: noise(0.05)),
                    alpha: 0.98
                ))
            }
        }

        // --- ラグ(床の上の円形マット) ---
        let rugCenter = SIMD3<Float>(0.45, 0.03, 0.5)
        for x in stride(from: rugCenter.x - 0.75, through: rugCenter.x + 0.75, by: 0.05) {
            for z in stride(from: rugCenter.z - 0.75, through: rugCenter.z + 0.75, by: 0.05) {
                let d = simd_length(SIMD2<Float>(x - rugCenter.x, z - rugCenter.z))
                guard d <= 0.72 else { continue }
                records.append(Record(
                    position: [x, rugCenter.y, z],
                    scale: [0.032, 0.005, 0.032],
                    color: SIMD3(0.22, 0.46, 0.50) + SIMD3(repeating: noise(0.04)),
                    alpha: 0.98
                ))
            }
        }

        // --- 壁(クリーム色)+ 窓(北)+ ドア(南) ---
        let cream = SIMD3<Float>(0.92, 0.88, 0.79)
        let sky = SIMD3<Float>(0.55, 0.82, 0.95)
        let doorWood = SIMD3<Float>(0.36, 0.25, 0.16)
        let wallStep: Float = 0.055

        for x in stride(from: Float(-2.0), through: 2.0, by: wallStep) {
            for y in stride(from: Float(0.03), through: 2.4, by: wallStep) {
                // 北壁(z = -1.5)。窓は空色に置き換える
                let inWindow = (x > 0.2 && x < 1.4 && y > 0.9 && y < 1.9)
                records.append(Record(
                    position: [x + noise(0.008), y + noise(0.008), -1.5],
                    scale: [0.034, 0.034, 0.006],
                    color: inWindow
                        ? sky + SIMD3(repeating: noise(0.06))
                        : cream + SIMD3(repeating: noise(0.03)),
                    alpha: 0.98
                ))
                // 南壁(z = 1.5)。ドアは濃い木の色
                let inDoor = (x > -1.6 && x < -0.75 && y < 2.0)
                records.append(Record(
                    position: [x + noise(0.008), y + noise(0.008), 1.5],
                    scale: [0.034, 0.034, 0.006],
                    color: inDoor
                        ? doorWood + SIMD3(repeating: noise(0.03))
                        : cream + SIMD3(repeating: noise(0.03)),
                    alpha: 0.98
                ))
            }
        }
        for z in stride(from: Float(-1.5), through: 1.5, by: wallStep) {
            for y in stride(from: Float(0.03), through: 2.4, by: wallStep) {
                for wallX in [Float(-2.0), 2.0] {
                    records.append(Record(
                        position: [wallX, y + noise(0.008), z + noise(0.008)],
                        scale: [0.006, 0.034, 0.034],
                        color: cream + SIMD3(repeating: noise(0.03)),
                        alpha: 0.98
                    ))
                }
            }
        }

        // --- ベッド(西側)---
        let bedMin = SIMD3<Float>(-1.95, 0, -1.45)
        let bedMax = SIMD3<Float>(-0.55, 0.5, 0.55)
        let blanket = SIMD3<Float>(0.38, 0.42, 0.72)
        let bedSide = SIMD3<Float>(0.30, 0.32, 0.55)
        // 天面(ブランケット)
        for x in stride(from: bedMin.x, through: bedMax.x, by: 0.06) {
            for z in stride(from: bedMin.z, through: bedMax.z, by: 0.06) {
                records.append(Record(
                    position: [x, bedMax.y + noise(0.012), z],
                    scale: [0.038, 0.016, 0.038],
                    color: blanket + SIMD3(repeating: noise(0.04)),
                    alpha: 0.98
                ))
            }
        }
        // 側面
        for y in stride(from: Float(0.05), through: bedMax.y - 0.03, by: 0.07) {
            for x in stride(from: bedMin.x, through: bedMax.x, by: 0.07) {
                for z in [bedMin.z, bedMax.z] {
                    records.append(Record(
                        position: [x, y, z], scale: [0.034, 0.034, 0.01],
                        color: bedSide + SIMD3(repeating: noise(0.03)), alpha: 0.98
                    ))
                }
            }
            for z in stride(from: bedMin.z, through: bedMax.z, by: 0.07) {
                records.append(Record(
                    position: [bedMax.x, y, z], scale: [0.012, 0.045, 0.045],
                    color: bedSide + SIMD3(repeating: noise(0.03)), alpha: 0.98
                ))
            }
        }
        // 枕
        for x in stride(from: Float(-1.8), through: -0.75, by: 0.05) {
            for z in stride(from: Float(-1.38), through: -1.05, by: 0.05) {
                records.append(Record(
                    position: [x, bedMax.y + 0.07 + noise(0.015), z],
                    scale: [0.036, 0.024, 0.036],
                    color: SIMD3(0.95, 0.95, 0.92) + SIMD3(repeating: noise(0.02)),
                    alpha: 0.98
                ))
            }
        }

        // --- 机(北東の窓ぎわ)---
        let deskTop = SIMD3<Float>(0.48, 0.34, 0.22)
        for x in stride(from: Float(0.8), through: 2.0, by: 0.05) {
            for z in stride(from: Float(-1.45), through: -0.85, by: 0.05) {
                records.append(Record(
                    position: [x, 0.72, z],
                    scale: [0.032, 0.01, 0.032],
                    color: deskTop + SIMD3(repeating: noise(0.03)),
                    alpha: 0.98
                ))
            }
        }
        for legX in [Float(0.86), 1.94] {
            for legZ in [Float(-1.39), -0.91] {
                for y in stride(from: Float(0.04), through: 0.7, by: 0.06) {
                    records.append(Record(
                        position: [legX, y, legZ],
                        scale: [0.02, 0.05, 0.02],
                        color: deskTop * 0.8,
                        alpha: 0.98
                    ))
                }
            }
        }

        // --- 椅子 ---
        let chairColor = SIMD3<Float>(0.30, 0.30, 0.36)
        for x in stride(from: Float(1.22), through: 1.58, by: 0.05) {
            for z in stride(from: Float(-0.62), through: -0.28, by: 0.05) {
                records.append(Record(
                    position: [x, 0.45, z], scale: [0.032, 0.012, 0.032],
                    color: chairColor + SIMD3(repeating: noise(0.02)), alpha: 0.98
                ))
            }
        }
        for x in stride(from: Float(1.22), through: 1.58, by: 0.05) {
            for y in stride(from: Float(0.5), through: 0.95, by: 0.05) {
                records.append(Record(
                    position: [x, y, -0.26], scale: [0.034, 0.034, 0.01],
                    color: chairColor + SIMD3(repeating: noise(0.02)), alpha: 0.98
                ))
            }
        }

        // --- 本棚(東の壁ぎわ)+ カラフルな本 ---
        let shelfFrame = SIMD3<Float>(0.55, 0.38, 0.20)
        let bookPalette: [SIMD3<Float>] = [
            [0.75, 0.30, 0.28], [0.28, 0.50, 0.68], [0.85, 0.68, 0.30],
            [0.38, 0.60, 0.38], [0.55, 0.40, 0.65], [0.90, 0.88, 0.85],
        ]
        // 枠(天板・側板・棚板)
        for z in stride(from: Float(0.15), through: 1.05, by: 0.05) {
            for y in [Float(0.02), 0.6, 1.2, 1.8] {
                records.append(Record(
                    position: [1.78, y, z], scale: [0.16, 0.012, 0.045],
                    color: shelfFrame + SIMD3(repeating: noise(0.03)), alpha: 0.98
                ))
            }
        }
        for y in stride(from: Float(0.02), through: 1.8, by: 0.05) {
            for z in [Float(0.15), 1.05] {
                records.append(Record(
                    position: [1.78, y, z], scale: [0.16, 0.045, 0.012],
                    color: shelfFrame + SIMD3(repeating: noise(0.03)), alpha: 0.98
                ))
            }
        }
        // 本(各段にランダム色の背表紙)
        for shelfY in [Float(0.0), 0.6, 1.2] {
            var z: Float = 0.2
            while z < 1.0 {
                let bookColor = bookPalette[Int(rng.range(0...Float(bookPalette.count - 1)).rounded())]
                let height = rng.range(0.32...0.5)
                records.append(Record(
                    position: [1.66, shelfY + height / 2 + 0.03, z],
                    scale: [0.015, height / 2, 0.018],
                    color: bookColor + SIMD3(repeating: noise(0.04)),
                    alpha: 0.98
                ))
                z += rng.range(0.045...0.07)
            }
        }

        // --- 観葉植物 ---
        let potCenter = SIMD3<Float>(1.7, 0, 1.1)
        for angle in stride(from: Float(0), to: 2 * .pi, by: 0.35) {
            for y in stride(from: Float(0.03), through: 0.28, by: 0.05) {
                let r: Float = 0.11 + y * 0.15
                records.append(Record(
                    position: [potCenter.x + r * cos(angle), y, potCenter.z + r * sin(angle)],
                    scale: [0.035, 0.035, 0.035],
                    color: SIMD3(0.62, 0.36, 0.24) + SIMD3(repeating: noise(0.03)),
                    alpha: 0.98
                ))
            }
        }
        var foliageCount = 0
        while foliageCount < 550 {
            let p = SIMD3<Float>(rng.range(-1...1), rng.range(-1...1), rng.range(-1...1))
            guard simd_length(p) <= 1 else { continue }
            foliageCount += 1
            records.append(Record(
                position: potCenter + SIMD3(0, 0.78, 0) + p * SIMD3(0.3, 0.42, 0.3),
                scale: SIMD3(repeating: rng.range(0.03...0.055)),
                color: SIMD3(0.20 + noise(0.06), 0.55 + noise(0.1), 0.25 + noise(0.06)),
                alpha: 0.85
            ))
        }

        // --- 天井付近の暖色の光(ふんわりしたグロー) ---
        for offset in [SIMD3<Float>(0, 0, 0), [-0.6, -0.1, 0.4], [0.6, -0.1, -0.3]] {
            records.append(Record(
                position: SIMD3(0, 2.15, 0) + offset,
                scale: [0.5, 0.28, 0.5],
                color: [1.0, 0.85, 0.55],
                alpha: 0.10
            ))
        }

        return encode(records)
    }

    /// .splat 形式(32 バイト固定レコード)へエンコード。
    /// 3DGS の慣例(y 下向き)に合わせて y / z を反転して書き出す
    /// (ビューア側のデフォルト「上下反転補正」で正立する)。
    private static func encode(_ records: [Record]) -> Data {
        var data = Data(capacity: records.count * 32)

        func appendFloat(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        for record in records {
            appendFloat(record.position.x)
            appendFloat(-record.position.y)
            appendFloat(-record.position.z)
            appendFloat(record.scale.x)
            appendFloat(record.scale.y)
            appendFloat(record.scale.z)
            let c = simd_clamp(record.color, SIMD3(repeating: 0), SIMD3(repeating: 1))
            data.append(UInt8(c.x * 255))
            data.append(UInt8(c.y * 255))
            data.append(UInt8(c.z * 255))
            data.append(UInt8(simd_clamp(record.alpha, 0, 1) * 255))
            // 単位クォータニオン (w, x, y, z) = (1, 0, 0, 0) → (v*128+128) エンコード
            data.append(255)
            data.append(128)
            data.append(128)
            data.append(128)
        }
        return data
    }
}
