import Foundation

/// Documents ディレクトリ以下のファイル配置を一元管理するヘルパー。
/// モデルには「Documents からの相対パス」だけを保存する
/// (再インストールやコンテナ移動で絶対パスが変わるため)。
enum AppFiles {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// すべての部屋カプセル関連ファイルのルート
    static var capsulesRootURL: URL {
        documentsURL.appendingPathComponent("RoomCapsules", isDirectory: true)
    }

    static var indexFileURL: URL {
        capsulesRootURL.appendingPathComponent("capsules.json")
    }

    static func capsuleDirectoryURL(capsuleID: UUID) -> URL {
        capsulesRootURL.appendingPathComponent(capsuleID.uuidString, isDirectory: true)
    }

    static func url(forRelativePath path: String) -> URL {
        documentsURL.appendingPathComponent(path)
    }

    /// 相対パス文字列を組み立てる("RoomCapsules/<capsuleID>/..." 形式)
    static func relativePath(capsuleID: UUID, _ components: String...) -> String {
        (["RoomCapsules", capsuleID.uuidString] + components).joined(separator: "/")
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func removeIfExists(relativePath: String?) {
        guard let relativePath else { return }
        removeIfExists(url(forRelativePath: relativePath))
    }
}
