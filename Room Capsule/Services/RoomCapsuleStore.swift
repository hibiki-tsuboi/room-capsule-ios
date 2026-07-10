import Foundation
import Combine
import SwiftUI
import UIKit

enum RoomCapsuleStoreError: LocalizedError {
    case encodeFailed
    case capsuleNotFound
    case versionNotFound

    var errorDescription: String? {
        switch self {
        case .encodeFailed: return "保存データをエンコードできませんでした"
        case .capsuleNotFound: return "保存先の部屋が見つかりませんでした"
        case .versionNotFound: return "保存先のバージョンが見つかりませんでした"
        }
    }
}

/// アプリ全体の永続化ストア。
/// JSON(capsules.json)+ Documents ディレクトリ保存のシンプル構成。
/// スキャンデータ・写真・Splat ファイルはすべてローカルにのみ保存する。
@MainActor
final class RoomCapsuleStore: ObservableObject {
    @Published private(set) var capsules: [RoomCapsule] = []
    /// capsules.json が読めなかったときの通知文(退避先の案内)。表示後に clearLoadFailureNotice() で消す
    @Published private(set) var loadFailureNotice: String?

    init() {
        AppFiles.ensureDirectory(AppFiles.capsulesRootURL)
        load()
        #if DEBUG
        // UI テスト・シミュレータ確認用: 起動引数でデモ部屋を自動投入
        if ProcessInfo.processInfo.arguments.contains("-seedDemo"), capsules.isEmpty {
            addDemoCapsule()
        }
        #endif
    }

    // MARK: - 永続化(JSON + Documents)

    private func load() {
        let url = AppFiles.indexFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: url)
            capsules = try decoder.decode([RoomCapsule].self, from: data)
        } catch {
            // 破損した index を次回の persist() で黙って上書きしないよう退避してから、
            // 空の一覧で再開する(スキャン・写真・Splat の実ファイルは各カプセルのフォルダに残る)
            if let backupName = backupCorruptIndexFile(url) {
                loadFailureNotice = "部屋一覧の保存データが破損していたため読み込めませんでした。元のファイルは同じフォルダに「\(backupName)」として退避してあります。スキャンや写真などのファイル自体は削除されていません。"
            } else {
                loadFailureNotice = "部屋一覧の保存データが破損していたため読み込めませんでした。"
            }
        }
    }

    func clearLoadFailureNotice() {
        loadFailureNotice = nil
    }

    /// 破損した capsules.json をタイムスタンプ付きの別名へ退避する(成功時は退避ファイル名を返す)
    private func backupCorruptIndexFile(_ url: URL) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = AppFiles.capsulesRootURL
            .appendingPathComponent("capsules-corrupted-\(formatter.string(from: Date())).json")
        do {
            try FileManager.default.moveItem(at: url, to: backupURL)
            return backupURL.lastPathComponent
        } catch {
            return nil
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(capsules)
        } catch {
            throw RoomCapsuleStoreError.encodeFailed
        }
        try AppFiles.ensureDirectoryOrThrow(AppFiles.capsulesRootURL)
        try data.write(to: AppFiles.indexFileURL, options: .atomic)
    }

    private func persistBestEffort() {
        try? persist()
    }

    private func touchAndPersist(_ index: Int) throws {
        capsules[index].updatedAt = Date()
        try persist()
    }

    private func touchAndPersistBestEffort(_ index: Int) {
        capsules[index].updatedAt = Date()
        persistBestEffort()
    }

    func capsule(id: UUID) -> RoomCapsule? {
        capsules.first { $0.id == id }
    }

    // MARK: - デフォルト名(スキャン保存パネルの事前入力用)

    /// 「部屋 1」「部屋 2」…既存の名前と被らない次の番号を使う
    func defaultCapsuleName() -> String {
        let existingNames = Set(capsules.map(\.name))
        var number = capsules.count + 1
        while existingNames.contains("部屋 \(number)") {
            number += 1
        }
        return "部屋 \(number)"
    }

    /// 「スキャン 1」「スキャン 2」…対象カプセルのバージョン名と被らない次の番号を使う
    func defaultVersionName(for capsuleID: UUID?) -> String {
        guard let capsuleID, let capsule = capsule(id: capsuleID) else { return "スキャン 1" }
        let existingNames = Set(capsule.versions.map(\.name))
        var number = capsule.versions.count + 1
        while existingNames.contains("スキャン \(number)") {
            number += 1
        }
        return "スキャン \(number)"
    }

    // MARK: - カプセル CRUD

    @discardableResult
    func createCapsule(named name: String) throws -> RoomCapsule {
        let capsule = RoomCapsule(name: name.isEmpty ? "名前のない部屋" : name)
        capsules.append(capsule)
        do {
            try persist()
        } catch {
            capsules.removeAll { $0.id == capsule.id }
            throw error
        }
        return capsule
    }

    func rename(capsuleID: UUID, to name: String) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }), !name.isEmpty else { return }
        capsules[index].name = name
        touchAndPersistBestEffort(index)
    }

    /// カプセルと、それに紐づく全ファイル(スキャン・写真・Splat)を完全削除する
    func delete(capsuleID: UUID) {
        AppFiles.removeIfExists(AppFiles.capsuleDirectoryURL(capsuleID: capsuleID))
        capsules.removeAll { $0.id == capsuleID }
        persistBestEffort()
    }

    /// すべてのデータを完全削除する(設定画面用)
    func deleteAllData() {
        for capsule in capsules {
            AppFiles.removeIfExists(AppFiles.capsuleDirectoryURL(capsuleID: capsule.id))
        }
        capsules = []
        persistBestEffort()
    }

    // MARK: - デモ部屋

    @discardableResult
    func addDemoCapsule() -> RoomCapsule {
        let demoCount = capsules.filter { $0.name.hasPrefix("デモルーム") }.count
        let name = demoCount == 0 ? "デモルーム" : "デモルーム \(demoCount + 1)"
        var capsule = DemoRoomFactory.makeDemoCapsule(name: name)
        for i in capsule.versions.indices {
            capsule.versions[i].thumbnailPath = writeThumbnail(for: capsule.versions[i], capsuleID: capsule.id)
        }
        capsules.append(capsule)
        persistBestEffort()
        return capsule
    }

    // MARK: - スキャンバージョン

    /// スキャン結果(または手動生成ジオメトリ)を新しいバージョンとして保存する
    @discardableResult
    func addScannedVersion(
        versionName: String,
        geometry: SimplifiedRoomGeometry,
        capturedRoomJSON: Data?,
        usdzTempURL: URL?,
        to capsuleID: UUID
    ) throws -> RoomScanVersion {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else {
            throw RoomCapsuleStoreError.capsuleNotFound
        }
        let originalCapsules = capsules
        var writtenURLs: [URL] = []
        var version = RoomScanVersion(
            name: versionName.isEmpty ? "スキャン \(capsules[index].versions.count + 1)" : versionName,
            simplifiedGeometry: geometry
        )

        let versionsDir = try AppFiles.ensureDirectoryOrThrow(
            AppFiles.capsuleDirectoryURL(capsuleID: capsuleID).appendingPathComponent("versions", isDirectory: true)
        )
        if let capturedRoomJSON {
            let fileName = "\(version.id.uuidString).room.json"
            let url = versionsDir.appendingPathComponent(fileName)
            try capturedRoomJSON.write(to: url, options: .atomic)
            writtenURLs.append(url)
            version.roomDataPath = AppFiles.relativePath(capsuleID: capsuleID, "versions", fileName)
        }
        if let usdzTempURL {
            let fileName = "\(version.id.uuidString).usdz"
            let url = versionsDir.appendingPathComponent(fileName)
            AppFiles.removeIfExists(url)
            try FileManager.default.moveItem(at: usdzTempURL, to: url)
            writtenURLs.append(url)
            version.usdzPath = AppFiles.relativePath(capsuleID: capsuleID, "versions", fileName)
        }
        version.thumbnailPath = writeThumbnail(for: version, capsuleID: capsuleID)
        if let thumbnailPath = version.thumbnailPath {
            writtenURLs.append(AppFiles.url(forRelativePath: thumbnailPath))
        }

        capsules[index].versions.append(version)
        do {
            try touchAndPersist(index)
        } catch {
            capsules = originalCapsules
            for url in writtenURLs {
                AppFiles.removeIfExists(url)
            }
            throw error
        }
        return version
    }

    func renameVersion(versionID: UUID, in capsuleID: UUID, to name: String) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }),
              let vIndex = capsules[index].versions.firstIndex(where: { $0.id == versionID }),
              !name.isEmpty else { return }
        capsules[index].versions[vIndex].name = name
        touchAndPersistBestEffort(index)
    }

    func deleteVersion(versionID: UUID, from capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }),
              let version = capsules[index].versions.first(where: { $0.id == versionID }) else { return }
        AppFiles.removeIfExists(relativePath: version.roomDataPath)
        AppFiles.removeIfExists(relativePath: version.usdzPath)
        AppFiles.removeIfExists(relativePath: version.thumbnailPath)
        if let splat = version.splatAsset {
            AppFiles.removeIfExists(splat.fileURL)
        }
        capsules[index].versions.removeAll { $0.id == versionID }
        // このバージョン限定だったピン・ゴーストは「全バージョン共通」に付け替える
        for i in capsules[index].memoPins.indices where capsules[index].memoPins[i].versionID == versionID {
            capsules[index].memoPins[i].versionID = nil
        }
        for i in capsules[index].furnitureGhosts.indices where capsules[index].furnitureGhosts[i].versionID == versionID {
            capsules[index].furnitureGhosts[i].versionID = nil
        }
        touchAndPersistBestEffort(index)
    }

    // MARK: - メモピン

    func upsertPin(_ pin: RoomMemoPin, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        if let pinIndex = capsules[index].memoPins.firstIndex(where: { $0.id == pin.id }) {
            capsules[index].memoPins[pinIndex] = pin
        } else {
            capsules[index].memoPins.append(pin)
        }
        touchAndPersistBestEffort(index)
    }

    func deletePin(pinID: UUID, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        if let pin = capsules[index].memoPins.first(where: { $0.id == pinID }) {
            for path in pin.photoPaths {
                AppFiles.removeIfExists(relativePath: path)
            }
        }
        capsules[index].memoPins.removeAll { $0.id == pinID }
        touchAndPersistBestEffort(index)
    }

    // MARK: - 家具ゴースト

    func upsertGhost(_ ghost: FurnitureGhost, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        if let ghostIndex = capsules[index].furnitureGhosts.firstIndex(where: { $0.id == ghost.id }) {
            capsules[index].furnitureGhosts[ghostIndex] = ghost
        } else {
            capsules[index].furnitureGhosts.append(ghost)
        }
        touchAndPersistBestEffort(index)
    }

    func deleteGhost(ghostID: UUID, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        capsules[index].furnitureGhosts.removeAll { $0.id == ghostID }
        touchAndPersistBestEffort(index)
    }

    // MARK: - Splat

    func attachSplat(_ asset: SplatAsset, to capsuleID: UUID, versionID: UUID) throws {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }),
              let vIndex = capsules[index].versions.firstIndex(where: { $0.id == versionID }) else {
            throw RoomCapsuleStoreError.versionNotFound
        }
        let old = capsules[index].versions[vIndex].splatAsset
        let oldUpdatedAt = capsules[index].updatedAt
        capsules[index].versions[vIndex].splatAsset = asset
        do {
            try touchAndPersist(index)
        } catch {
            capsules[index].versions[vIndex].splatAsset = old
            capsules[index].updatedAt = oldUpdatedAt
            AppFiles.removeIfExists(asset.fileURL)
            throw error
        }
        if let old {
            AppFiles.removeIfExists(old.fileURL)
        }
    }

    func detachSplat(from capsuleID: UUID, versionID: UUID) throws {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }),
              let vIndex = capsules[index].versions.firstIndex(where: { $0.id == versionID }) else {
            throw RoomCapsuleStoreError.versionNotFound
        }
        let asset = capsules[index].versions[vIndex].splatAsset
        let oldUpdatedAt = capsules[index].updatedAt
        capsules[index].versions[vIndex].splatAsset = nil
        do {
            try touchAndPersist(index)
        } catch {
            capsules[index].versions[vIndex].splatAsset = asset
            capsules[index].updatedAt = oldUpdatedAt
            throw error
        }
        if let asset {
            AppFiles.removeIfExists(asset.fileURL)
        }
    }

    // MARK: - 写真

    /// メモピン添付用の写真データを保存して相対パスを返す
    func savePinPhoto(_ data: Data, capsuleID: UUID) -> String? {
        let dir = AppFiles.ensureDirectory(
            AppFiles.capsuleDirectoryURL(capsuleID: capsuleID).appendingPathComponent("photos", isDirectory: true)
        )
        let fileName = UUID().uuidString + ".jpg"
        let url = dir.appendingPathComponent(fileName)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return AppFiles.relativePath(capsuleID: capsuleID, "photos", fileName)
    }

    func deleteFile(relativePath: String) {
        AppFiles.removeIfExists(relativePath: relativePath)
    }

    // MARK: - サムネイル

    /// 2D 間取り図をレンダリングしてサムネイル PNG を書き出す
    private func writeThumbnail(for version: RoomScanVersion, capsuleID: UUID) -> String? {
        guard !version.simplifiedGeometry.isEmpty else { return nil }
        let content = FloorPlanCanvas(
            geometry: version.simplifiedGeometry,
            pins: [],
            ghosts: [],
            showDimensions: false,
            showLabels: false
        )
        .padding(24)
        .frame(width: 480, height: 360)
        .background(
            LinearGradient(
                colors: [Theme.backgroundTop, Theme.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.uiImage, let png = image.pngData() else { return nil }

        let dir = AppFiles.ensureDirectory(
            AppFiles.capsuleDirectoryURL(capsuleID: capsuleID).appendingPathComponent("thumbnails", isDirectory: true)
        )
        let fileName = "\(version.id.uuidString).png"
        let url = dir.appendingPathComponent(fileName)
        guard (try? png.write(to: url, options: .atomic)) != nil else { return nil }
        return AppFiles.relativePath(capsuleID: capsuleID, "thumbnails", fileName)
    }
}
