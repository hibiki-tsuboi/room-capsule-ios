import SwiftUI
import UniformTypeIdentifiers
import UIKit
import simd

// MARK: - Splat ビューア

struct SplatViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let asset: SplatAsset
    /// PhotoModeView に埋め込むときは自前のオーバーレイ(バッジ・閉じる・反転・AR ボタン)を出さず、
    /// 上下反転は親が flipOverride で制御する
    var embedded = false
    var flipOverride: Bool?

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

    private var effectiveFlip: Bool { flipOverride ?? flipUpsideDown }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.09).ignoresSafeArea()

            switch loadState {
            case .loading:
                ProgressView("点群を読み込み中…")
                    .tint(Theme.accentCyan)
                    .foregroundStyle(.white)

            case .gaussian(let cloud):
                MetalSplatView(
                    cloud: cloud,
                    flipUpsideDown: effectiveFlip,
                    onFailure: { loadState = .failed($0) }
                )
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
                    // 埋め込み時は PhotoModeView の下部ボタンと重ならない高さへ
                    .padding(.bottom, embedded ? 92 : 20)
                }

            case .points(let cloud, let note):
                SplatPointCloudView(cloud: cloud, flipUpsideDown: effectiveFlip)
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
                    .padding(.bottom, embedded ? 92 : 20)
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

            if !embedded {
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
                            CloseButton { dismiss() }
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
        }
        .task(id: asset.id) {
            await load()
        }
        .fullScreenCover(isPresented: $showAR) {
            SplatARView(asset: asset)
        }
        .preferredColorScheme(.dark)
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

/// 「写真っぽく見る」のハブ画面。
/// Splat データがあれば模型→Splat のクロスフェード表示と AR 設置、
/// なければその場でのデータ取得(LiDAR スキャン / ファイル取り込み / サンプル生成)に誘導する。
struct PhotoModeView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    let versionID: UUID?

    @State private var showSplat = false
    @State private var splatFlipped = true
    @State private var showImporter = false
    @State private var showCapture = false
    @State private var showAR = false
    @State private var showDeleteConfirm = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var version: RoomScanVersion? {
        capsule?.version(id: versionID) ?? capsule?.latestVersion
    }

    private var allowedTypes: [UTType] {
        // .spz は取り込めても描画未対応(gzip 展開未実装)で行き止まりになるため、ピッカーから除外する
        let types = SplatImportService.supportedExtensions
            .filter { $0 != "spz" }
            .compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let capsule, let version {
                // AR / キャプチャのカバー表示中は模型のプレビュー(nonAR の ARView)も解体する。
                // RealityKit の ARView を 2 枚同時に生かすとカバー側のカメラ背景の描画を
                // 阻害する疑いがあるため(資源節約も兼ねる。閉じたら再マウントされる)
                if !showAR, !showCapture {
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
                }

                // AR / キャプチャのカバー表示中は解体してメモリと描画ループを解放する
                // (点群2コピー+Metal ループ2本の同時常駐を避ける。閉じたら再ロードされる)
                if let splat = version.splatAsset, showSplat, !showAR, !showCapture {
                    SplatViewerView(asset: splat, embedded: true, flipOverride: splatFlipped)
                        .transition(.opacity)
                }

                VStack {
                    header(capsule: capsule, version: version)
                    Spacer()
                    if isImporting {
                        ProgressView("ファイルをコピー中…")
                            .tint(Theme.accentCyan)
                            .foregroundStyle(.white)
                            .padding(.bottom, 12)
                    }
                    if version.splatAsset != nil {
                        bottomControls
                    } else {
                        emptyStateCard
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
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let version else { return }
                isImporting = true
                Task {
                    do {
                        let asset = try await Task.detached(priority: .userInitiated) {
                            try SplatImportService.importFile(from: url, capsuleID: capsuleID)
                        }.value
                        do {
                            try store.attachSplat(asset, to: capsuleID, versionID: version.id)
                        } catch {
                            AppFiles.removeIfExists(asset.fileURL)
                            throw error
                        }
                        Haptics.success()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isImporting = false
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("うまくいきませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("写真データを削除しますか?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                guard let version else { return }
                do {
                    try store.detachSplat(from: capsuleID, versionID: version.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この部屋のこのバージョンから Splat ファイルが削除されます。スキャンした模型やメモはそのまま残ります。")
        }
        .fullScreenCover(isPresented: $showCapture) {
            if let version {
                SplatCaptureView(capsuleID: capsuleID, versionID: version.id)
            }
        }
        .fullScreenCover(isPresented: $showAR) {
            if let splat = version?.splatAsset {
                SplatARView(asset: splat)
            } else {
                // 条件が崩れても真っ黒な空カバーにせず、閉じられる画面を出す
                ZStack {
                    CapsuleBackground()
                    ContentUnavailableView("写真データが見つかりません", systemImage: "sparkles")
                    VStack {
                        HStack {
                            Spacer()
                            CloseButton { showAR = false }
                        }
                        .padding()
                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            if version?.splatAsset != nil {
                withAnimation(.easeInOut(duration: 1.4).delay(0.7)) {
                    showSplat = true
                }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-autoPhotoAR") {
                // 実際のユーザー操作(フェード完了後に「AR で置く」をタップ)に合わせて遅延
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    showAR = true
                }
            }
            #endif
        }
        .onChange(of: version?.splatAsset?.id) { _, newID in
            // スキャン / 取り込み直後は自動でフェードイン、削除されたら模型に戻す
            withAnimation(.easeInOut(duration: 1.0)) {
                showSplat = newID != nil
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: ヘッダー

    private func header(capsule: RoomCapsule, version: RoomScanVersion) -> some View {
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

            VStack(spacing: 10) {
                CloseButton { dismiss() }
                manageMenu(version: version)
            }
        }
        .padding()
    }

    /// データの取得・差し替え・削除をまとめた管理メニュー
    private func manageMenu(version: RoomScanVersion) -> some View {
        Menu {
            if let asset = version.splatAsset {
                Section("\(asset.fileName)(\(asset.fileSizeText))") {
                    Toggle("上下を反転", isOn: $splatFlipped)
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("写真データを削除", systemImage: "trash")
                    }
                }
            }
            Section("データを作り直す") {
                acquisitionMenuItems
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    private var acquisitionMenuItems: some View {
        Button {
            showCapture = true
        } label: {
            Label("この部屋をスキャンして作る(LiDAR)", systemImage: "camera.metering.multispot")
        }
        Button {
            showImporter = true
        } label: {
            Label("ファイルを取り込む(.ply / .splat)", systemImage: "square.and.arrow.down")
        }
        Button {
            generateSample()
        } label: {
            Label("サンプルデータで試す", systemImage: "wand.and.stars")
        }
    }

    // MARK: 下部コントロール

    /// Splat あり: 模型⇄写真のクロスフェードと AR 設置
    private var bottomControls: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 1.0)) {
                    showSplat.toggle()
                }
                Haptics.medium()
            } label: {
                Label(showSplat ? "模型に戻す" : "写真っぽく見る", systemImage: showSplat ? "cube" : "sparkles")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                showAR = true
                Haptics.medium()
            } label: {
                Label("AR で置く", systemImage: "arkit")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.bottom, 20)
    }

    /// Splat なし: その場でデータを用意するための案内カード
    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Text("まだ写真データがありません")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("データ(Gaussian Splatting)を用意すると、この模型が写真のような空間に変わります。LiDAR でこの部屋をスキャンするのがいちばん簡単です。")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)

            Button {
                showCapture = true
            } label: {
                Label("この部屋をスキャンして作る(LiDAR)", systemImage: "camera.metering.multispot")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                showImporter = true
            } label: {
                Label("ファイルを取り込む(.ply / .splat)", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isImporting)

            Button {
                generateSample()
            } label: {
                Label("サンプルデータで試す", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())

            Text("Scaniverse などで作った学習ベースの高品質データもそのまま取り込めます。")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .glassCard(cornerRadius: 18)
        .padding()
    }

    private func generateSample() {
        guard let version else { return }
        do {
            _ = try SampleSplatFactory.generateAndAttach(capsuleID: capsuleID, versionID: version.id, store: store)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
