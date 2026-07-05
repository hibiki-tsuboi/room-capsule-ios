import SwiftUI
import UniformTypeIdentifiers
import UIKit
import simd

// MARK: - Splat インポート画面

/// .ply / .splat / .spz ファイルを取り込んで部屋バージョンに紐づける
struct SplatImportView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID

    @State private var selectedVersionID: UUID?
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var viewingAsset: SplatAsset?
    @State private var showCapture = false

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var selectedVersion: RoomScanVersion? {
        capsule?.version(id: selectedVersionID) ?? capsule?.latestVersion
    }

    private var allowedTypes: [UTType] {
        let types = SplatImportService.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CapsuleBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        infoCard

                        if let capsule {
                            versionPicker(capsule)
                        }

                        if let version = selectedVersion {
                            if let asset = version.splatAsset {
                                assetCard(asset, version: version)
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "sparkles.rectangle.stack")
                                        .font(.system(size: 36))
                                        .foregroundStyle(Color.white.opacity(0.4))
                                    Text("このバージョンには Splat がまだありません")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                                .glassCard(cornerRadius: 18)
                            }
                        }

                        Button {
                            showCapture = true
                        } label: {
                            Label("この部屋をスプラット化(LiDAR)", systemImage: "camera.metering.multispot")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(selectedVersion == nil)

                        Button {
                            showImporter = true
                        } label: {
                            Label("ファイルを取り込む", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(selectedVersion == nil)

                        Button {
                            generateSample()
                        } label: {
                            Label("サンプル Splat を生成", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(selectedVersion == nil)

                        Spacer(minLength: 40)
                    }
                    .padding()
                }
            }
            .navigationTitle("Splat 管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let version = selectedVersion else { return }
                do {
                    let asset = try SplatImportService.importFile(from: url, capsuleID: capsuleID)
                    store.attachSplat(asset, to: capsuleID, versionID: version.id)
                    Haptics.success()
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("取り込みに失敗しました", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(item: $viewingAsset) { asset in
            SplatViewerView(asset: asset)
        }
        .fullScreenCover(isPresented: $showCapture) {
            if let version = selectedVersion {
                SplatCaptureView(capsuleID: capsuleID, versionID: version.id)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func generateSample() {
        guard let version = selectedVersion else { return }
        do {
            _ = try SampleSplatFactory.generateAndAttach(capsuleID: capsuleID, versionID: version.id, store: store)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("写真っぽい 3D(Gaussian Splatting)", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.white)
            Text("「スプラット化」は LiDAR で面の向きまで推定しながら、この場で自分の部屋を Splat 化します。学習ベースの最高品質が欲しい場合は Scaniverse などで作った .ply / .splat を取り込んでください。")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.7))
            Label("このビルドは Metal による Gaussian Splatting 実レンダリングに対応しています(3DGS 属性のない .ply は点群表示、.spz は未対応)。", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(Theme.accentCyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 18)
    }

    private func versionPicker(_ capsule: RoomCapsule) -> some View {
        Menu {
            ForEach(capsule.versions.sorted(by: { $0.capturedAt < $1.capturedAt })) { version in
                Button {
                    selectedVersionID = version.id
                } label: {
                    Label(
                        version.splatAsset == nil ? version.name : "\(version.name)(Splat あり)",
                        systemImage: version.id == selectedVersion?.id ? "checkmark" : "clock"
                    )
                }
            }
        } label: {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.accentCyan)
                Text("紐づけ先: \(selectedVersion?.name ?? "バージョンなし")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(14)
            .glassCard(cornerRadius: 14)
        }
    }

    private func assetCard(_ asset: SplatAsset, version: RoomScanVersion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(Theme.accentPurple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(asset.fileType.displayName)・\(asset.fileSizeText)")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer()
            }
            Text("取り込み日時: \(asset.importedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.45))
            HStack(spacing: 10) {
                Button {
                    viewingAsset = asset
                } label: {
                    Label("表示する", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button(role: .destructive) {
                    store.detachSplat(from: capsuleID, versionID: version.id)
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 18)
    }
}

// MARK: - Splat ビューア

struct SplatViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let asset: SplatAsset
    /// PhotoModeView に埋め込むときは閉じるボタンを出さない
    var embedded = false

    private enum LoadState {
        case loading
        /// Metal による実レンダリング
        case gaussian(GaussianSplatCloud)
        /// 点群フォールバック(note = フォールバック理由)
        case points(SplatPointCloud, note: String?)
        case metadataOnly(String)
        case failed(String)
    }

    @State private var loadState: LoadState = .loading
    @State private var flipUpsideDown = true
    @State private var showAR = false

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.09).ignoresSafeArea()

            switch loadState {
            case .loading:
                ProgressView("点群を読み込み中…")
                    .tint(Theme.accentCyan)
                    .foregroundStyle(.white)

            case .gaussian(let cloud):
                MetalSplatView(cloud: cloud, flipUpsideDown: flipUpsideDown)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text("\(cloud.count.formatted()) スプラットを実レンダリング中\(cloud.shDegree > 0 ? "・SH \(cloud.shDegree) 次(視線依存色)" : "")\(cloud.isSubsampled ? "(間引きあり・全 \(cloud.totalPointCount.formatted()))" : "")")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                        Text("ドラッグで回転・ピンチで拡大縮小")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .padding(.bottom, 20)
                }

            case .points(let cloud, let note):
                SplatPointCloudView(cloud: cloud, flipUpsideDown: flipUpsideDown)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        if let note {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(Color.orange.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        Text("\(cloud.positions.count.formatted()) 点を表示中\(cloud.isSubsampled ? "(間引きあり・全 \(cloud.totalPointCount.formatted()) 点)" : "")")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                        Text("ドラッグで回転・ピンチで拡大縮小")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .padding(.bottom, 20)
                }

            case .metadataOnly(let reason), .failed(let reason):
                VStack(spacing: 14) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.accentGradient)
                    Text(asset.fileName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("\(asset.fileType.displayName)・\(asset.fileSizeText)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .glassCard(cornerRadius: 22)
                .padding()
            }

            VStack {
                HStack(alignment: .top) {
                    Label(badgeText, systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accentCyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassCard(cornerRadius: 12)

                    Spacer()

                    VStack(spacing: 10) {
                        if !embedded {
                            CloseButton { dismiss() }
                        }
                        if showsFlipButton {
                            Button {
                                flipUpsideDown.toggle()
                                Haptics.light()
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .padding(12)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                        }
                        if showsARButton {
                            Button {
                                showAR = true
                                Haptics.medium()
                            } label: {
                                Image(systemName: "arkit")
                                    .font(.headline)
                                    .foregroundStyle(.black)
                                    .padding(12)
                                    .background(Theme.accentGradient, in: Circle())
                            }
                        }
                    }
                }
                .padding()
                Spacer()
            }
        }
        .task(id: asset.id) {
            await load()
        }
        .fullScreenCover(isPresented: $showAR) {
            SplatARView(asset: asset)
        }
    }

    /// 実レンダリング中かつ AR 対応端末なら「AR で置く」を出す
    private var showsARButton: Bool {
        guard !embedded, ARCapabilities.isARSupported else { return false }
        if case .gaussian = loadState { return true }
        return false
    }

    private var badgeText: String {
        switch loadState {
        case .loading: return "読み込み中…"
        case .gaussian: return "実レンダリング(Metal Gaussian Splatting)"
        case .points: return "簡易プレビュー(点群)"
        case .metadataOnly, .failed: return "プレビュー未対応"
        }
    }

    private var showsFlipButton: Bool {
        switch loadState {
        case .gaussian, .points: return true
        case .loading, .metadataOnly, .failed: return false
        }
    }

    private func load() async {
        if case .metadataOnly(let reason) = SplatRendererAvailability.availability(for: asset) {
            loadState = .metadataOnly(reason)
            return
        }
        let url = asset.fileURL
        let fileType = asset.fileType

        // まず Metal 実レンダリング用の Gaussian データとして読む。
        // 3DGS 属性がない PLY などは点群プレビューへフォールバック。
        if MetalSplatSupport.isAvailable {
            do {
                let cloud = try await Task.detached(priority: .userInitiated) {
                    try GaussianSplatLoader.load(url: url, fileType: fileType)
                }.value
                if cloud.count > 0 {
                    loadState = .gaussian(cloud)
                } else {
                    await loadPointCloud(url: url, fileType: fileType, note: "スプラットが空だったため点群表示にフォールバックしました")
                }
            } catch {
                await loadPointCloud(url: url, fileType: fileType, note: error.localizedDescription)
            }
        } else {
            await loadPointCloud(url: url, fileType: fileType, note: nil)
        }
    }

    private func loadPointCloud(url: URL, fileType: SplatFileType, note: String?) async {
        do {
            let cloud = try await Task.detached(priority: .userInitiated) {
                try SplatPointCloudLoader.load(url: url, fileType: fileType)
            }.value
            if cloud.positions.isEmpty {
                loadState = .failed("点が見つかりませんでした")
            } else {
                loadState = .points(cloud, note: note)
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 写真っぽく見るモード

/// 模型がフェードアウトして、写真っぽい空間(Splat)がフェードインする演出
struct PhotoModeView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    let versionID: UUID?

    @State private var showSplat = false
    @State private var showImport = false

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var version: RoomScanVersion? {
        capsule?.version(id: versionID) ?? capsule?.latestVersion
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let capsule, let version {
                RoomPreviewARContainer(
                    geometry: version.simplifiedGeometry,
                    pins: [],
                    ghosts: capsule.ghosts(forVersion: version.id),
                    mode: .photo,
                    startsInside: false,
                    pinPlacementActive: false,
                    onSelectPart: { _ in },
                    onPlacePin: { _ in }
                )
                .ignoresSafeArea()
                .opacity(showSplat ? 0 : 1)

                if let splat = version.splatAsset, showSplat {
                    SplatViewerView(asset: splat, embedded: true)
                        .transition(.opacity)
                }

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("写真っぽく見る")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("\(capsule.name)・\(version.name)")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 14)
                        Spacer()
                        CloseButton { dismiss() }
                    }
                    .padding()

                    Spacer()

                    if version.splatAsset != nil {
                        Button {
                            withAnimation(.easeInOut(duration: 1.0)) {
                                showSplat.toggle()
                            }
                            Haptics.medium()
                        } label: {
                            Label(showSplat ? "模型に戻す" : "写真っぽく見る", systemImage: showSplat ? "cube" : "sparkles")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.bottom, 20)
                    } else {
                        VStack(spacing: 10) {
                            Text("まだ Splat データがありません")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Gaussian Splatting データ(.ply / .splat / .spz)を追加すると、この模型が写真のような空間に変わります。今は擬似カラー表示です。")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.65))
                                .multilineTextAlignment(.center)
                            Button {
                                showImport = true
                            } label: {
                                Label("Splat を追加", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        .padding(16)
                        .glassCard(cornerRadius: 18)
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView("表示できるバージョンがありません", systemImage: "sparkles")
                VStack {
                    HStack {
                        Spacer()
                        CloseButton { dismiss() }
                    }
                    .padding()
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showImport) {
            SplatImportView(capsuleID: capsuleID)
        }
        .onAppear {
            if version?.splatAsset != nil {
                withAnimation(.easeInOut(duration: 1.4).delay(0.7)) {
                    showSplat = true
                }
            }
        }
    }
}
