import SwiftUI
import UIKit

/// ホーム画面: 保存した部屋カプセルの一覧
struct HomeView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @State private var showScan = false
    @State private var showSettings = false
    @State private var deletionTarget: RoomCapsule?
    /// 起動引数 -autoPreview / -autoSplat での動作確認用(シミュレータ検証向け)
    @State private var showDebugPreview = false
    @State private var debugSplatAsset: SplatAsset?

    var body: some View {
        NavigationStack {
            ZStack {
                CapsuleBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        if store.capsules.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.capsules) { capsule in
                                NavigationLink(value: capsule.id) {
                                    RoomCapsuleCard(capsule: capsule)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deletionTarget = capsule
                                    } label: {
                                        Label("この部屋を削除", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.white)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                RoomDetailView(capsuleID: id)
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        .fullScreenCover(isPresented: $showScan) {
            RoomCaptureScanView(targetCapsuleID: nil)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showDebugPreview) {
            if let first = store.capsules.first {
                RoomImmersivePreviewView(capsuleID: first.id, versionID: nil)
            }
        }
        .fullScreenCover(item: $debugSplatAsset) { asset in
            SplatViewerView(asset: asset)
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-autoPreview") {
                showDebugPreview = true
            }
            if ProcessInfo.processInfo.arguments.contains("-autoSplat") {
                let capsule = store.capsules.first ?? store.addDemoCapsule()
                if let version = capsule.latestVersion {
                    debugSplatAsset = version.splatAsset
                        ?? (try? SampleSplatFactory.generateAndAttach(capsuleID: capsule.id, versionID: version.id, store: store))
                }
            }
        }
        .confirmationDialog(
            "「\(deletionTarget?.name ?? "")」を削除しますか?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("スキャンデータごと完全に削除", role: .destructive) {
                if let target = deletionTarget {
                    withAnimation {
                        store.delete(capsuleID: target.id)
                    }
                }
                deletionTarget = nil
            }
            Button("キャンセル", role: .cancel) {
                deletionTarget = nil
            }
        } message: {
            Text("この部屋のスキャン・メモ・写真・Splat データはすべてこの iPhone から完全に削除されます。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Room Capsule")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("部屋をスキャンして、カプセルに閉じ込めよう")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accentGradient)
            Text("まだ部屋がありません")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("「部屋を保存する」で部屋をスキャンするか、\nデモ部屋でまず体験してみましょう。")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
            Button {
                addDemo()
            } label: {
                Label("デモ部屋を追加", systemImage: "wand.and.stars")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard(cornerRadius: 26)
        .padding(.top, 24)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                showScan = true
            } label: {
                Label("部屋を保存する", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                addDemo()
            } label: {
                Label("デモ部屋", systemImage: "wand.and.stars")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private func addDemo() {
        withAnimation {
            _ = store.addDemoCapsule()
        }
        Haptics.success()
    }
}

// MARK: - カプセルカード

struct RoomCapsuleCard: View {
    let capsule: RoomCapsule

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(capsule.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(capsule.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                HStack(spacing: 12) {
                    StatBadge(systemImage: "clock.arrow.circlepath", text: "\(capsule.versions.count)")
                    StatBadge(systemImage: "mappin.and.ellipse", text: "\(capsule.memoPins.count)")
                    StatBadge(systemImage: "sofa", text: "\(capsule.furnitureGhosts.count)")
                    if capsule.hasSplat {
                        StatBadge(systemImage: "sparkles", text: "Splat")
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(12)
        .glassCard()
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = capsule.latestVersion?.thumbnailPath,
           let image = UIImage(contentsOfFile: AppFiles.url(forRelativePath: path).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Theme.accentGradient.opacity(0.35)
                Image(systemName: "cube.transparent")
                    .font(.title)
                    .foregroundStyle(.white)
            }
        }
    }
}
