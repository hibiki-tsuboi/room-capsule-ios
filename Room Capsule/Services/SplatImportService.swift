import Foundation

enum SplatImportError: LocalizedError {
    case unsupportedExtension(String)
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext):
            return "拡張子 .\(ext) は対応していません(.ply / .splat / .spz のみ)"
        case .copyFailed:
            return "ファイルをアプリ内にコピーできませんでした"
        }
    }
}

/// ファイルピッカーで選ばれた Splat ファイルをアプリ内(Documents)へ
/// コピーして SplatAsset を作るサービス
@MainActor
enum SplatImportService {

    static let supportedExtensions = ["ply", "splat", "spz"]

    static func importFile(from pickedURL: URL, capsuleID: UUID) throws -> SplatAsset {
        let ext = pickedURL.pathExtension.lowercased()
        guard let fileType = SplatFileType(rawValue: ext) else {
            throw SplatImportError.unsupportedExtension(ext)
        }

        // ファイル App 由来の URL はセキュリティスコープ付きアクセスが必要
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                pickedURL.stopAccessingSecurityScopedResource()
            }
        }

        let dir = AppFiles.ensureDirectory(
            AppFiles.capsuleDirectoryURL(capsuleID: capsuleID).appendingPathComponent("splats", isDirectory: true)
        )
        let id = UUID()
        let fileName = "\(id.uuidString).\(ext)"
        let destination = dir.appendingPathComponent(fileName)
        AppFiles.removeIfExists(destination)
        do {
            try FileManager.default.copyItem(at: pickedURL, to: destination)
        } catch {
            throw SplatImportError.copyFailed
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        return SplatAsset(
            id: id,
            fileName: pickedURL.lastPathComponent,
            relativePath: AppFiles.relativePath(capsuleID: capsuleID, "splats", fileName),
            fileType: fileType,
            importedAt: Date(),
            fileSizeBytes: size
        )
    }
}
