import Foundation

// MARK: - Gaussian Splatting アセット

enum SplatFileType: String, Codable, Hashable, CaseIterable {
    case ply
    case splat
    case spz

    var displayName: String {
        switch self {
        case .ply: return ".ply(PLY / 3D Gaussian Splatting)"
        case .splat: return ".splat"
        case .spz: return ".spz(圧縮形式)"
        }
    }

    /// このビルドの点群プレビューで読めるか
    var supportsPointCloudPreview: Bool {
        switch self {
        case .ply, .splat: return true
        case .spz: return false // gzip 展開が必要なため現状はメタデータ表示のみ
        }
    }
}

struct SplatAsset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// 取り込み元のファイル名(表示用)
    var fileName: String
    /// Documents からの相対パス
    var relativePath: String
    var fileType: SplatFileType
    var importedAt: Date = Date()
    var fileSizeBytes: Int64 = 0

    var fileURL: URL { AppFiles.url(forRelativePath: relativePath) }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}
