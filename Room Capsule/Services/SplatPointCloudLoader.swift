import Foundation
import simd

// MARK: - 点群データ

/// 点群プレビュー用にパースした Splat データ。
/// 位置は重心が原点に来るよう再センタリング済み。
nonisolated struct SplatPointCloud: Sendable {
    var positions: [SIMD3<Float>]
    /// 0...1 の RGB
    var colors: [SIMD3<Float>]
    var boundingRadius: Float
    /// 間引き前の総点数
    var totalPointCount: Int

    var isSubsampled: Bool { positions.count < totalPointCount }
}

nonisolated enum SplatLoadError: LocalizedError {
    case unsupportedFormat(String)
    case corruptFile(String)
    case fileTooLarge(fileSize: Int64, limit: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let reason): return "この形式は読み込めません:\(reason)"
        case .corruptFile(let reason): return "ファイルを解析できませんでした:\(reason)"
        case .fileTooLarge(let fileSize, let limit):
            let sizeText = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return "ファイルが大きすぎます(\(sizeText))。このビルドでは \(limitText) 以下のファイルを選んでください。"
        }
    }
}

nonisolated enum SplatFileLimits {
    /// Import and preview are in-memory pipelines; keep this conservative for iPhone release builds.
    static let maxFileSizeBytes: Int64 = 256 * 1024 * 1024

    static func validateSize(of url: URL) throws {
        let size = try fileSize(of: url)
        guard size <= maxFileSizeBytes else {
            throw SplatLoadError.fileTooLarge(fileSize: size, limit: maxFileSizeBytes)
        }
    }

    static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - PLY 共通パーサ(点群プレビューと Gaussian ローダーで共用)

nonisolated enum PLYFormat: Sendable {
    case ascii
    case binaryLittleEndian
}

nonisolated struct PLYProperty: Sendable {
    var name: String
    var byteSize: Int
    var isFloat: Bool
    var isDouble: Bool
    var isUChar: Bool
}

nonisolated struct PLYHeader: Sendable {
    var format: PLYFormat
    var vertexCount: Int
    var properties: [PLYProperty]
    /// データ部の先頭バイトオフセット
    var dataStart: Int
    /// binary 時の 1 レコードのバイト数
    var stride: Int
    /// binary 時の各プロパティのレコード内オフセット
    var offsets: [Int]

    func index(of name: String) -> Int? {
        properties.firstIndex { $0.name == name }
    }

    private static func propertySize(_ type: String) -> (size: Int, isFloat: Bool, isDouble: Bool, isUChar: Bool)? {
        switch type {
        case "char", "int8", "uchar", "uint8":
            return (1, false, false, type == "uchar" || type == "uint8")
        case "short", "int16", "ushort", "uint16":
            return (2, false, false, false)
        case "int", "int32", "uint", "uint32":
            return (4, false, false, false)
        case "float", "float32":
            return (4, true, false, false)
        case "double", "float64":
            return (8, false, true, false)
        default:
            return nil
        }
    }

    static func parse(_ data: Data) throws -> PLYHeader {
        let headerEndRange = data.range(of: Data("end_header\r\n".utf8))
            ?? data.range(of: Data("end_header\n".utf8))
        guard let headerEndRange else {
            throw SplatLoadError.corruptFile("PLY ヘッダの終端(end_header)が見つかりません")
        }
        guard let headerText = String(data: data[data.startIndex..<headerEndRange.upperBound], encoding: .ascii) else {
            throw SplatLoadError.corruptFile("PLY ヘッダを文字列として読めません")
        }

        var format: PLYFormat?
        var vertexCount = 0
        var properties: [PLYProperty] = []
        var inVertexElement = false
        var sawVertexElementFirst = false
        var elementIndex = 0

        for rawLine in headerText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            switch parts[0] {
            case "format":
                guard parts.count >= 2 else { break }
                switch parts[1] {
                case "ascii": format = .ascii
                case "binary_little_endian": format = .binaryLittleEndian
                default:
                    throw SplatLoadError.unsupportedFormat("PLY フォーマット \(parts[1]) は未対応です")
                }
            case "element":
                guard parts.count >= 3 else { break }
                if parts[1] == "vertex" {
                    vertexCount = Int(parts[2]) ?? 0
                    inVertexElement = true
                    sawVertexElementFirst = (elementIndex == 0)
                } else {
                    inVertexElement = false
                }
                elementIndex += 1
            case "property":
                guard inVertexElement, parts.count >= 3 else { break }
                if parts[1] == "list" {
                    throw SplatLoadError.unsupportedFormat("vertex 要素の list プロパティは未対応です")
                }
                guard let meta = propertySize(parts[1]) else {
                    throw SplatLoadError.unsupportedFormat("PLY プロパティ型 \(parts[1]) は未対応です")
                }
                properties.append(
                    PLYProperty(name: parts[2], byteSize: meta.size, isFloat: meta.isFloat, isDouble: meta.isDouble, isUChar: meta.isUChar)
                )
            default:
                break
            }
        }

        guard let format else {
            throw SplatLoadError.corruptFile("PLY の format 行がありません")
        }
        guard vertexCount > 0, !properties.isEmpty else {
            throw SplatLoadError.corruptFile("PLY に vertex 要素がありません")
        }
        guard sawVertexElementFirst else {
            throw SplatLoadError.unsupportedFormat("vertex が最初の要素でない PLY は未対応です")
        }

        var offsets: [Int] = []
        var stride = 0
        for property in properties {
            offsets.append(stride)
            stride += property.byteSize
        }

        return PLYHeader(
            format: format,
            vertexCount: vertexCount,
            properties: properties,
            dataStart: headerEndRange.upperBound - data.startIndex,
            stride: stride,
            offsets: offsets
        )
    }

    /// vertex レコードを step 間隔で列挙し、全プロパティ値を Float 配列として渡す
    func forEachRecord(in data: Data, step: Int, _ body: ([Float]) -> Void) throws {
        switch format {
        case .binaryLittleEndian:
            let available = (data.count - dataStart) / stride
            let count = min(vertexCount, available)
            guard count > 0 else {
                throw SplatLoadError.corruptFile("PLY のデータ部が不足しています")
            }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var values = [Float](repeating: 0, count: properties.count)
                var i = 0
                while i < count {
                    let recordBase = dataStart + i * stride
                    for (pIndex, property) in properties.enumerated() {
                        let offset = recordBase + offsets[pIndex]
                        if property.isFloat {
                            values[pIndex] = raw.loadUnaligned(fromByteOffset: offset, as: Float32.self)
                        } else if property.isDouble {
                            values[pIndex] = Float(raw.loadUnaligned(fromByteOffset: offset, as: Float64.self))
                        } else if property.byteSize == 1 {
                            values[pIndex] = Float(raw[offset])
                        } else if property.byteSize == 2 {
                            values[pIndex] = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        } else {
                            values[pIndex] = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        }
                    }
                    body(values)
                    i += step
                }
            }

        case .ascii:
            guard let bodyText = String(data: data[(data.startIndex + dataStart)...], encoding: .ascii) else {
                throw SplatLoadError.corruptFile("PLY の ASCII データ部を読めません")
            }
            var values = [Float](repeating: 0, count: properties.count)
            var parsed = 0
            for line in bodyText.split(separator: "\n") {
                if parsed >= vertexCount { break }
                defer { parsed += 1 }
                if parsed % step != 0 { continue }
                let comps = line.split(separator: " ", omittingEmptySubsequences: true)
                guard comps.count >= properties.count else { continue }
                for pIndex in 0..<properties.count {
                    values[pIndex] = Float(comps[pIndex]) ?? 0
                }
                body(values)
            }
        }
    }
}

/// 3DGS PLY の色抽出(red/green/blue または f_dc_0..2)を共通化
nonisolated struct PLYColorReader: Sendable {
    private let rgbIndices: (Int, Int, Int)?
    private let rgbIsUChar: Bool
    private let dcIndices: (Int, Int, Int)?
    private static let sh0: Float = 0.28209479177 // 球面調和 l=0 の係数

    init(header: PLYHeader) {
        if let r = header.index(of: "red"), let g = header.index(of: "green"), let b = header.index(of: "blue") {
            rgbIndices = (r, g, b)
            rgbIsUChar = header.properties[r].isUChar
        } else {
            rgbIndices = nil
            rgbIsUChar = false
        }
        if let r = header.index(of: "f_dc_0"), let g = header.index(of: "f_dc_1"), let b = header.index(of: "f_dc_2") {
            dcIndices = (r, g, b)
        } else {
            dcIndices = nil
        }
    }

    func color(from values: [Float]) -> SIMD3<Float> {
        if let (r, g, b) = rgbIndices {
            let scale: Float = rgbIsUChar ? 255 : 1
            return simd_clamp(
                SIMD3<Float>(values[r] / scale, values[g] / scale, values[b] / scale),
                SIMD3<Float>(repeating: 0),
                SIMD3<Float>(repeating: 1)
            )
        }
        if let (r, g, b) = dcIndices {
            return simd_clamp(
                SIMD3<Float>(
                    0.5 + Self.sh0 * values[r],
                    0.5 + Self.sh0 * values[g],
                    0.5 + Self.sh0 * values[b]
                ),
                SIMD3<Float>(repeating: 0),
                SIMD3<Float>(repeating: 1)
            )
        }
        return SIMD3<Float>(0.78, 0.8, 0.9)
    }
}

// MARK: - 点群ローダー(簡易プレビュー用)

/// .splat / .ply(3D Gaussian Splatting 含む)を点群としてパースする。
/// Metal 実レンダリングが使えない場合のフォールバック用途。
nonisolated enum SplatPointCloudLoader {

    /// 描画負荷対策の最大点数(超えたら等間隔に間引く)
    static let maxPoints = 350_000

    static func load(url: URL, fileType: SplatFileType) throws -> SplatPointCloud {
        switch fileType {
        case .splat:
            return try loadDotSplat(url: url)
        case .ply:
            return try loadPLY(url: url)
        case .spz:
            throw SplatLoadError.unsupportedFormat(".spz(gzip 圧縮)の展開はこのビルドでは未対応です")
        }
    }

    // MARK: .splat(antimatter15 形式: 32 バイト固定レコード)

    private static func loadDotSplat(url: URL) throws -> SplatPointCloud {
        try SplatFileLimits.validateSize(of: url)
        let data = try Data(contentsOf: url)
        let recordSize = 32
        let total = data.count / recordSize
        guard total > 0 else {
            throw SplatLoadError.corruptFile(".splat のレコードが見つかりません")
        }
        let step = max(1, (total + maxPoints - 1) / maxPoints)

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        positions.reserveCapacity(total / step + 1)
        colors.reserveCapacity(total / step + 1)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i < total {
                let base = i * recordSize
                let x = raw.loadUnaligned(fromByteOffset: base + 0, as: Float32.self)
                let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float32.self)
                let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float32.self)
                let r = Float(raw[base + 24]) / 255
                let g = Float(raw[base + 25]) / 255
                let b = Float(raw[base + 26]) / 255
                if x.isFinite && y.isFinite && z.isFinite {
                    positions.append([x, y, z])
                    colors.append([r, g, b])
                }
                i += step
            }
        }
        return finalize(positions: positions, colors: colors, totalPointCount: total)
    }

    // MARK: .ply

    private static func loadPLY(url: URL) throws -> SplatPointCloud {
        try SplatFileLimits.validateSize(of: url)
        let data = try Data(contentsOf: url)
        let header = try PLYHeader.parse(data)

        guard let xIndex = header.index(of: "x"),
              let yIndex = header.index(of: "y"),
              let zIndex = header.index(of: "z") else {
            throw SplatLoadError.corruptFile("PLY に x/y/z プロパティがありません")
        }
        let colorReader = PLYColorReader(header: header)
        let step = max(1, (header.vertexCount + maxPoints - 1) / maxPoints)

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        positions.reserveCapacity(header.vertexCount / step + 1)
        colors.reserveCapacity(header.vertexCount / step + 1)

        try header.forEachRecord(in: data, step: step) { values in
            let p = SIMD3<Float>(values[xIndex], values[yIndex], values[zIndex])
            if p.x.isFinite && p.y.isFinite && p.z.isFinite {
                positions.append(p)
                colors.append(colorReader.color(from: values))
            }
        }

        return finalize(positions: positions, colors: colors, totalPointCount: header.vertexCount)
    }

    // MARK: 共通後処理

    /// 重心を原点へ移動し、外接半径を計算する
    private static func finalize(
        positions: [SIMD3<Float>],
        colors: [SIMD3<Float>],
        totalPointCount: Int
    ) -> SplatPointCloud {
        guard !positions.isEmpty else {
            return SplatPointCloud(positions: [], colors: [], boundingRadius: 1, totalPointCount: totalPointCount)
        }
        var centroid = SIMD3<Float>(repeating: 0)
        for p in positions {
            centroid += p
        }
        centroid /= Float(positions.count)

        var centered: [SIMD3<Float>] = []
        centered.reserveCapacity(positions.count)
        var maxDistanceSquared: Float = 0
        for p in positions {
            let c = p - centroid
            centered.append(c)
            maxDistanceSquared = max(maxDistanceSquared, simd_length_squared(c))
        }
        return SplatPointCloud(
            positions: centered,
            colors: colors,
            boundingRadius: max(sqrt(maxDistanceSquared), 0.5),
            totalPointCount: totalPointCount
        )
    }
}
