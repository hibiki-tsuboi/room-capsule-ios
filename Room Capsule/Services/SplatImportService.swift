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

    /// 生成済みの .splat データを保存してバージョンに紐づける
    /// (サンプル生成・LiDAR 簡易スキャンの共通処理)
    @discardableResult
    static func attachSplatData(
        _ data: Data,
        fileName displayName: String,
        capsuleID: UUID,
        versionID: UUID,
        store: RoomCapsuleStore
    ) throws -> SplatAsset {
        let dir = AppFiles.ensureDirectory(
            AppFiles.capsuleDirectoryURL(capsuleID: capsuleID).appendingPathComponent("splats", isDirectory: true)
        )
        let id = UUID()
        let fileName = "\(id.uuidString).splat"
        let url = dir.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)

        let asset = SplatAsset(
            id: id,
            fileName: displayName,
            relativePath: AppFiles.relativePath(capsuleID: capsuleID, "splats", fileName),
            fileType: .splat,
            importedAt: Date(),
            fileSizeBytes: Int64(data.count)
        )
        store.attachSplat(asset, to: capsuleID, versionID: versionID)
        return asset
    }

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
