import SwiftUI
import UIKit

// MARK: - 詳細画面から遷移するモード

enum DetailScreen: Identifiable, Hashable {
    case preview(RoomDisplayMode)
    case miniature
    case fullScale
    case portal
    case photoMode
    case splatAR
    case timeline
    case floorPlan
    case memoList
    case ghostList
    case splatImport
    case scanNewVersion

    var id: String {
        switch self {
        case .preview(let mode): return "preview-\(mode.rawValue)"
        case .miniature: return "miniature"
        case .fullScale: return "fullScale"
        case .portal: return "portal"
        case .photoMode: return "photoMode"
        case .splatAR: return "splatAR"
        case .timeline: return "timeline"
        case .floorPlan: return "floorPlan"
        case .memoList: return "memoList"
        case .ghostList: return "ghostList"
        case .splatImport: return "splatImport"
        case .scanNewVersion: return "scanNewVersion"
        }
    }
}

// MARK: - 部屋詳細画面

struct RoomDetailView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID

    @State private var selectedVersionID: UUID?
    @State private var activeScreen: DetailScreen?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var versionDeletionTarget: RoomScanVersion?
    @State private var showTimelineAlert = false

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var selectedVersion: RoomScanVersion? {
        guard let capsule else { return nil }
        return capsule.version(id: selectedVersionID) ?? capsule.latestVersion
    }

    var body: some View {
        ZStack {
            CapsuleBackground()

            if let capsule {
                ScrollView {
                    VStack(spacing: 16) {
                        previewCard(capsule)
                        versionRow(capsule)
                        statsRow(capsule)
                        if let version = selectedVersion {
                            measurementCard(version)
                        }
                        modeGrid(capsule)
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal)
                }
            } else {
                ContentUnavailableView("部屋が見つかりません", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(capsule?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let usdzURL = selectedVersion?.usdzURL {
                        Section {
                            // 受け取った人は AR Quick Look(iOS 標準)でそのまま AR 表示できる
                            ShareLink(item: usdzURL) {
                                Label("USDZ を共有(AR Quick Look)", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    Button {
                        renameText = capsule?.name ?? ""
                        showRename = true
                    } label: {
                        Label("名前を変更", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("この部屋を削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.white)
                }
            }
        }
        .fullScreenCover(item: $activeScreen) { screen in
            screenView(screen)
        }
        .alert("部屋の名前を変更", isPresented: $showRename) {
            TextField("部屋の名前", text: $renameText)
            Button("保存") {
                store.rename(capsuleID: capsuleID, to: renameText)
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("この部屋を削除しますか?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("スキャンデータごと完全に削除", role: .destructive) {
                store.delete(capsuleID: capsuleID)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この部屋のスキャンデータや関連ファイルはすべてこの iPhone から完全に削除されます。")
        }
        .confirmationDialog(
            "バージョン「\(versionDeletionTarget?.name ?? "")」を削除しますか?",
            isPresented: Binding(
                get: { versionDeletionTarget != nil },
                set: { if !$0 { versionDeletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("スキャンデータごと完全に削除", role: .destructive) {
                if let target = versionDeletionTarget {
                    store.deleteVersion(versionID: target.id, from: capsuleID)
                    selectedVersionID = nil
                }
                versionDeletionTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                versionDeletionTarget = nil
            }
        } message: {
            Text("このバージョンのスキャンデータや関連ファイルは完全に削除されます。")
        }
        .alert("バージョンが足りません", isPresented: $showTimelineAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("時間を比べるには 2 つ以上のバージョンが必要です。「バージョンを追加」でもう一度スキャンしてみてください。")
        }
    }

    // MARK: プレビューカード

    @ViewBuilder
    private func previewCard(_ capsule: RoomCapsule) -> some View {
        if let version = selectedVersion {
            ZStack(alignment: .bottomTrailing) {
                thumbnailView(version)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                Button {
                    activeScreen = .preview(.model)
                } label: {
                    Label("3Dプレビュー", systemImage: "rotate.3d")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(12)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accentGradient)
                Text("まだスキャンがありません")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("この部屋をスキャンして、最初のバージョンを保存しましょう。")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                Button("スキャンする") {
                    activeScreen = .scanNewVersion
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .glassCard(cornerRadius: 22)
        }
    }

    @ViewBuilder
    private func thumbnailView(_ version: RoomScanVersion) -> some View {
        if let path = version.thumbnailPath,
           let image = UIImage(contentsOfFile: AppFiles.url(forRelativePath: path).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Theme.accentGradient.opacity(0.3)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: バージョン選択

    private func versionRow(_ capsule: RoomCapsule) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(capsule.versions.sorted(by: { $0.capturedAt < $1.capturedAt })) { version in
                    Button {
                        selectedVersionID = version.id
                    } label: {
                        Label(
                            "\(version.name)(\(version.capturedAt.formatted(date: .abbreviated, time: .omitted)))",
                            systemImage: version.id == selectedVersion?.id ? "checkmark" : "clock"
                        )
                    }
                }
                if capsule.versions.count > 1, let version = selectedVersion {
                    Divider()
                    Button(role: .destructive) {
                        versionDeletionTarget = version
                    } label: {
                        Label("「\(version.name)」を削除", systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Theme.accentCyan)
                    Text(selectedVersion?.name ?? "バージョンなし")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 14)
            }

            Spacer()

            Button {
                activeScreen = .scanNewVersion
            } label: {
                Label("バージョンを追加", systemImage: "plus.viewfinder")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: 14)
                    .foregroundStyle(.white)
            }
        }
    }

    private func statsRow(_ capsule: RoomCapsule) -> some View {
        HStack(spacing: 16) {
            StatBadge(systemImage: "clock.arrow.circlepath", text: "バージョン \(capsule.versions.count)")
            if FeatureFlags.memoPins {
                StatBadge(systemImage: "mappin.and.ellipse", text: "メモ \(capsule.memoPins.count)")
            }
            if FeatureFlags.furnitureGhosts {
                StatBadge(systemImage: "sofa", text: "ゴースト \(capsule.furnitureGhosts.count)")
            }
            if FeatureFlags.splat {
                StatBadge(
                    systemImage: "sparkles",
                    text: capsule.hasSplat ? "Splat あり" : "Splat なし"
                )
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: 採寸サマリー

    /// 床面積・天井高・壁の総延長のカード(簡易ジオメトリからの概算)
    @ViewBuilder
    private func measurementCard(_ version: RoomScanVersion) -> some View {
        let geometry = version.simplifiedGeometry
        if !geometry.isEmpty, let area = geometry.approximateFloorArea {
            HStack(spacing: 0) {
                measurementItem(
                    title: "床面積",
                    value: String(format: "%.1f ㎡", area),
                    detail: String(format: "約 %.1f 畳", area / 1.62)
                )
                measurementDivider
                measurementItem(
                    title: "天井高",
                    value: String(format: "%.2f m", geometry.wallHeight),
                    detail: "壁の最大高さ"
                )
                measurementDivider
                measurementItem(
                    title: "壁の総延長",
                    value: String(format: "%.1f m", geometry.totalWallLength),
                    detail: "\(geometry.walls.count) 面"
                )
            }
            .padding(.vertical, 12)
            .glassCard(cornerRadius: 18)
        }
    }

    private var measurementDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private func measurementItem(title: String, value: String, detail: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.5))
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: モードグリッド

    private func modeGrid(_ capsule: RoomCapsule) -> some View {
        let hasVersion = selectedVersion != nil
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            ModeGridButton(title: "ミニチュアで見る", subtitle: "机の上にドールハウス", systemImage: "cube.transparent", enabled: hasVersion) {
                activeScreen = .miniature
            }
            ModeGridButton(title: "実寸で呼び出す", subtitle: "1:1 スケールで再現", systemImage: "arkit", enabled: hasVersion) {
                activeScreen = .fullScale
            }
            if FeatureFlags.portal {
                ModeGridButton(title: "ポータルを開く", subtitle: "AR のドアからのぞく", systemImage: "door.left.hand.open", enabled: hasVersion) {
                    activeScreen = .portal
                }
            }
            if FeatureFlags.splat {
                ModeGridButton(title: "写真っぽく見る", subtitle: "Gaussian Splatting", systemImage: "sparkles", enabled: hasVersion) {
                    activeScreen = .photoMode
                }
                ModeGridButton(
                    title: "スプラット AR",
                    subtitle: "写真の部屋を現実に置く",
                    systemImage: "wand.and.rays",
                    enabled: selectedVersion?.splatAsset != nil
                ) {
                    activeScreen = .splatAR
                }
            }
            ModeGridButton(title: "時間を比べる", subtitle: "Before / After", systemImage: "clock.arrow.2.circlepath", enabled: hasVersion) {
                if capsule.versions.count >= 2 {
                    activeScreen = .timeline
                } else {
                    showTimelineAlert = true
                }
            }
            ModeGridButton(title: "図面で見る", subtitle: "2D 間取り図", systemImage: "square.grid.3x3", enabled: hasVersion) {
                activeScreen = .floorPlan
            }
            if FeatureFlags.memoPins {
                ModeGridButton(title: "メモを浮かべる", subtitle: "空間にメモピン", systemImage: "mappin.and.ellipse", enabled: hasVersion) {
                    activeScreen = .memoList
                }
            }
            if FeatureFlags.furnitureGhosts {
                ModeGridButton(title: "家具ゴースト", subtitle: "未来の家具を試す", systemImage: "sofa.fill", enabled: hasVersion) {
                    activeScreen = .ghostList
                }
            }
            ModeGridButton(title: "X線・分解", subtitle: "構造を見る", systemImage: "eye", enabled: hasVersion) {
                activeScreen = .preview(.xray)
            }
            if FeatureFlags.splat {
                ModeGridButton(title: "Splat 管理", subtitle: ".ply / .splat / .spz", systemImage: "square.and.arrow.down", enabled: hasVersion) {
                    activeScreen = .splatImport
                }
            }
        }
    }

    // MARK: 遷移先

    @ViewBuilder
    private func screenView(_ screen: DetailScreen) -> some View {
        let versionID = selectedVersion?.id
        switch screen {
        case .preview(let mode):
            RoomImmersivePreviewView(capsuleID: capsuleID, versionID: versionID, initialMode: mode)
        case .miniature:
            MiniatureARView(capsuleID: capsuleID, versionID: versionID)
        case .fullScale:
            FullScaleARView(capsuleID: capsuleID, versionID: versionID)
        case .portal:
            PortalARView(capsuleID: capsuleID, versionID: versionID)
        case .photoMode:
            PhotoModeView(capsuleID: capsuleID, versionID: versionID)
        case .splatAR:
            if let asset = selectedVersion?.splatAsset {
                SplatARView(asset: asset)
            } else {
                ZStack {
                    CapsuleBackground()
                    ContentUnavailableView("Splat がありません", systemImage: "sparkles")
                    VStack {
                        HStack {
                            Spacer()
                            CloseButton { activeScreen = nil }
                        }
                        .padding()
                        Spacer()
                    }
                }
            }
        case .timeline:
            TimelineComparisonView(capsuleID: capsuleID)
        case .floorPlan:
            FloorPlan2DView(capsuleID: capsuleID, versionID: versionID)
        case .memoList:
            MemoPinListView(capsuleID: capsuleID, preferredVersionID: versionID)
        case .ghostList:
            FurnitureGhostListView(capsuleID: capsuleID, preferredVersionID: versionID)
        case .splatImport:
            SplatImportView(capsuleID: capsuleID)
        case .scanNewVersion:
            RoomCaptureScanView(targetCapsuleID: capsuleID)
        }
    }
}

// MARK: - モードボタン

struct ModeGridButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Theme.accentGradient)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassCard(cornerRadius: 18)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
