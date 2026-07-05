import Foundation
import Combine
import SwiftUI
import UIKit

/// アプリ全体の永続化ストア。
/// JSON(capsules.json)+ Documents ディレクトリ保存のシンプル構成。
/// スキャンデータ・写真・Splat ファイルはすべてローカルにのみ保存する。
@MainActor
final class RoomCapsuleStore: ObservableObject {
    @Published private(set) var capsules: [RoomCapsule] = []

    init() {
        AppFiles.ensureDirectory(AppFiles.capsulesRootURL)
        load()
        // UI テスト・シミュレータ確認用: 起動引数でデモ部屋を自動投入
        if ProcessInfo.processInfo.arguments.contains("-seedDemo"), capsules.isEmpty {
            addDemoCapsule()
        }
    }

    // MARK: - 永続化(JSON + Documents)

    private func load() {
        guard let data = try? Data(contentsOf: AppFiles.indexFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([RoomCapsule].self, from: data) {
            capsules = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(capsules) else { return }
        AppFiles.ensureDirectory(AppFiles.capsulesRootURL)
        try? data.write(to: AppFiles.indexFileURL, options: .atomic)
    }

    private func touchAndPersist(_ index: Int) {
        capsules[index].updatedAt = Date()
        persist()
    }

    func capsule(id: UUID) -> RoomCapsule? {
        capsules.first { $0.id == id }
    }

    // MARK: - カプセル CRUD

    @discardableResult
    func createCapsule(named name: String) -> RoomCapsule {
        let capsule = RoomCapsule(name: name.isEmpty ? "名前のない部屋" : name)
        capsules.append(capsule)
        persist()
        return capsule
    }

    func rename(capsuleID: UUID, to name: String) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }), !name.isEmpty else { return }
        capsules[index].name = name
        touchAndPersist(index)
    }

    /// カプセルと、それに紐づく全ファイル(スキャン・写真・Splat)を完全削除する
    func delete(capsuleID: UUID) {
        AppFiles.removeIfExists(AppFiles.capsuleDirectoryURL(capsuleID: capsuleID))
        capsules.removeAll { $0.id == capsuleID }
        persist()
    }

    /// すべてのデータを完全削除する(設定画面用)
    func deleteAllData() {
        for capsule in capsules {
            AppFiles.removeIfExists(AppFiles.capsuleDirectoryURL(capsuleID: capsule.id))
        }
        capsules = []
        persist()
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
        persist()
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
    ) -> RoomScanVersion? {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return nil }
        var version = RoomScanVersion(
            name: versionName.isEmpty ? "スキャン \(capsules[index].versions.count + 1)" : versionName,
            simplifiedGeometry: geometry
        )

        let versionsDir = AppFiles.ensureDirectory(
            AppFiles.capsuleDirectoryURL(capsuleID: capsuleID).appendingPathComponent("versions", isDirectory: true)
        )
        if let capturedRoomJSON {
            let fileName = "\(version.id.uuidString).room.json"
            let url = versionsDir.appendingPathComponent(fileName)
            if (try? capturedRoomJSON.write(to: url, options: .atomic)) != nil {
                version.roomDataPath = AppFiles.relativePath(capsuleID: capsuleID, "versions", fileName)
            }
        }
        if let usdzTempURL {
            let fileName = "\(version.id.uuidString).usdz"
            let url = versionsDir.appendingPathComponent(fileName)
            AppFiles.removeIfExists(url)
            if (try? FileManager.default.moveItem(at: usdzTempURL, to: url)) != nil {
                version.usdzPath = AppFiles.relativePath(capsuleID: capsuleID, "versions", fileName)
            }
        }
        version.thumbnailPath = writeThumbnail(for: version, capsuleID: capsuleID)

        capsules[index].versions.append(version)
        touchAndPersist(index)
        return version
    }

    func renameVersion(versionID: UUID, in capsuleID: UUID, to name: String) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }),
              let vIndex = capsules[index].versions.firstIndex(where: { $0.id == versionID }),
              !name.isEmpty else { return }
        capsules[index].versions[vIndex].name = name
        touchAndPersist(index)
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
        touchAndPersist(index)
    }

    // MARK: - メモピン

    func upsertPin(_ pin: RoomMemoPin, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        if let pinIndex = capsules[index].memoPins.firstIndex(where: { $0.id == pin.id }) {
            capsules[index].memoPins[pinIndex] = pin
        } else {
            capsules[index].memoPins.append(pin)
        }
        touchAndPersist(index)
    }

    func deletePin(pinID: UUID, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        if let pin = capsules[index].memoPins.first(where: { $0.id == pinID }) {
            for path in pin.photoPaths {
                AppFiles.removeIfExists(relativePath: path)
            }
        }
        capsules[index].memoPins.removeAll { $0.id == pinID }
        touchAndPersist(index)
    }

    // MARK: - 家具ゴースト

    func upsertGhost(_ ghost: FurnitureGhost, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        if let ghostIndex = capsules[index].furnitureGhosts.firstIndex(where: { $0.id == ghost.id }) {
            capsules[index].furnitureGhosts[ghostIndex] = ghost
        } else {
            capsules[index].furnitureGhosts.append(ghost)
        }
        touchAndPersist(index)
    }

    func deleteGhost(ghostID: UUID, in capsuleID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }) else { return }
        capsules[index].furnitureGhosts.removeAll { $0.id == ghostID }
        touchAndPersist(index)
    }

    // MARK: - Splat

    func attachSplat(_ asset: SplatAsset, to capsuleID: UUID, versionID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }),
              let vIndex = capsules[index].versions.firstIndex(where: { $0.id == versionID }) else { return }
        if let old = capsules[index].versions[vIndex].splatAsset {
            AppFiles.removeIfExists(old.fileURL)
        }
        capsules[index].versions[vIndex].splatAsset = asset
        touchAndPersist(index)
    }

    func detachSplat(from capsuleID: UUID, versionID: UUID) {
        guard let index = capsules.firstIndex(where: { $0.id == capsuleID }),
              let vIndex = capsules[index].versions.firstIndex(where: { $0.id == versionID }) else { return }
        if let asset = capsules[index].versions[vIndex].splatAsset {
            AppFiles.removeIfExists(asset.fileURL)
        }
        capsules[index].versions[vIndex].splatAsset = nil
        touchAndPersist(index)
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
