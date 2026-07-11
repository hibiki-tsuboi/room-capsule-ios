import SwiftUI
@preconcurrency import ARKit
import RealityKit
import Metal
import MetalKit
import UIKit
import simd
import AVFoundation

// MARK: - LiDAR 簡易スプラットスキャン画面

/// LiDAR で部屋を「面に沿った色付きスプラット」としてスキャンし、.splat として保存する。
/// 法線推定つきの扁平ガウスで書き出すため、面が連続して見える(学習は行わない)。
struct SplatCaptureView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss

    let capsuleID: UUID
    let versionID: UUID

    @State private var pointCount = 0
    @State private var finishToken = 0
    @State private var isSaving = false
    @State private var previewVisible = true
    @State private var errorMessage: String?

    /// カメラ権限が拒否されていると ARView は黒画面のまま何も起きないので、先に検知して案内する
    private var isCameraBlocked: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    var body: some View {
        ZStack {
            if !LiDARSplatAccumulator.isSupported {
                CapsuleBackground()
                ARUnavailableCard(
                    title: "この端末ではスキャンできません",
                    message: "LiDAR スプラットスキャンには LiDAR 搭載の iPhone / iPad(Pro 系)が必要です。Scaniverse などで作った .ply / .splat の取り込みは引き続き使えます。",
                    actionTitle: "閉じる"
                ) {
                    dismiss()
                }
            } else if isCameraBlocked {
                CapsuleBackground()
                ARUnavailableCard(
                    title: "カメラを使えません",
                    message: "スキャンにはカメラが必要です。設定 > プライバシーとセキュリティ > カメラ で Room Capsule を有効にしてください。",
                    actionTitle: "閉じる"
                ) {
                    dismiss()
                }
            } else {
                SplatCaptureContainer(
                    finishToken: finishToken,
                    previewVisible: previewVisible,
                    onCountChange: { pointCount = $0 },
                    onFailure: { errorMessage = $0 },
                    onFinished: { data, count in
                        save(data: data, count: count)
                    }
                )
                .ignoresSafeArea()

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("部屋をゆっくり見回して、面を塗りつぶしてください")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                            HStack(spacing: 10) {
                                Label("\(pointCount.formatted()) スプラット", systemImage: "circle.dotted.circle")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accentCyan)
                                    .monospacedDigit()
                                Text("塗れた場所はその場で色付きます")
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.5))
                            }
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 14)

                        Spacer()

                        VStack(spacing: 10) {
                            CloseButton { dismiss() }
                            Button {
                                previewVisible.toggle()
                                Haptics.light()
                            } label: {
                                Image(systemName: previewVisible ? "eye.fill" : "eye.slash")
                                    .font(.headline)
                                    .foregroundStyle(previewVisible ? Color.black : Color.white)
                                    .padding(12)
                                    .background(
                                        previewVisible
                                            ? AnyShapeStyle(Theme.accentGradient)
                                            : AnyShapeStyle(.ultraThinMaterial),
                                        in: Circle()
                                    )
                            }
                        }
                    }
                    .padding()

                    Spacer()

                    if isSaving {
                        ProgressView("スプラットを書き出し中…")
                            .tint(Theme.accentCyan)
                            .foregroundStyle(.white)
                            .padding(16)
                            .glassCard(cornerRadius: 16)
                            .padding(.bottom, 24)
                    } else {
                        Button {
                            isSaving = true
                            finishToken += 1
                            Haptics.medium()
                        } label: {
                            Label("スキャン完了", systemImage: "checkmark")
                                .frame(maxWidth: 240)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(pointCount < 8_000)
                        .opacity(pointCount < 8_000 ? 0.5 : 1)
                        .padding(.bottom, 24)
                    }
                }
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
        .preferredColorScheme(.dark)
    }

    private func save(data: Data, count: Int) {
        do {
            _ = try SplatImportService.attachSplatData(
                data,
                fileName: "LiDARスキャン.splat",
                capsuleID: capsuleID,
                versionID: versionID,
                store: store
            )
            Haptics.success()
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - キャプチャ用 AR コンテナ

struct SplatCaptureContainer: UIViewRepresentable {
    var finishToken: Int
    var previewVisible: Bool = true
    var onCountChange: (Int) -> Void
    var onFailure: (String) -> Void = { _ in }
    var onFinished: (Data, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ARView {
        // 実機でカメラ表示の実績がある MiniatureARView と同じく ARView 自体を返し、
        // ライブプレビューの MTKView はその subview にする
        let arView = ARView(frame: .zero)
        // カメラ背景を明示(既定値のはずだが、黒背景フォールバックを防ぐ保険)
        arView.environment.background = .cameraFeed()
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = .smoothedSceneDepth
        } else {
            config.frameSemantics = .sceneDepth
        }
        // セッション失敗(カメラ使用不可など)を黒画面のまま放置せずエラー表示に出す
        arView.session.delegate = context.coordinator
        arView.session.run(config)
        // シーンが完全に空だと描画がアイドル化しカメラ背景まで止まる環境があるため、
        // 空アンカーを置いて RealityKit の描画ループを維持する
        arView.scene.addAnchor(AnchorEntity(world: SIMD3<Float>.zero))

        // 上層: 収集済みスプラットのライブプレビュー(タッチは透過)
        let mtkView = MTKView()
        mtkView.frame = arView.bounds
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.isOpaque = false
        // CAMetalLayer 側にも明示(不透明だと透明クリアでも黒く合成され、下のカメラ映像が隠れる)
        mtkView.layer.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.isUserInteractionEnabled = false
        arView.addSubview(mtkView)

        context.coordinator.start(arView: arView, mtkView: mtkView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncPreviewVisibility()
        context.coordinator.handleFinishTokenIfNeeded()
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        var parent: SplatCaptureContainer
        private weak var arView: ARView?
        private weak var mtkView: MTKView?
        private var previewRenderer: LiveSplatPreviewRenderer?
        private let accumulator = LiDARSplatAccumulator()
        private let captureQueue = DispatchQueue(label: "roomcapsule.lidar-splat-capture", qos: .userInitiated)
        private var captureTimer: Timer?
        private var lastFinishToken = 0
        private var lastPreviewCount = 0
        private var ingestInFlight = false
        private var exportInFlight = false

        init(_ parent: SplatCaptureContainer) {
            self.parent = parent
            self.lastFinishToken = parent.finishToken
        }

        func start(arView: ARView, mtkView: MTKView) {
            self.arView = arView
            self.mtkView = mtkView

            do {
                let renderer = try LiveSplatPreviewRenderer(
                    capacity: accumulator.maxPoints,
                    voxelSize: accumulator.voxelSize
                )
                renderer.arSession = arView.session
                mtkView.device = renderer.device
                mtkView.delegate = renderer
                // device 割り当てで MTKView がレイヤ設定を作り直す場合に備え、透明を再指定
                mtkView.layer.isOpaque = false
                previewRenderer = renderer // MTKView.delegate は weak なのでここで保持
            } catch {
                parent.onFailure("ライブプレビューを初期化できませんでした: \(error.localizedDescription)")
            }

            // 0.12 秒間隔で currentFrame を取り込む(フレームを保持しないので ARKit に優しい)
            captureTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.captureTick()
                }
            }
        }

        func stop() {
            captureTimer?.invalidate()
            captureTimer = nil
            arView?.session.pause()
        }

        // MARK: ARSessionDelegate

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.parent.onFailure("スキャンを続けられません: \(message)")
            }
        }

        func syncPreviewVisibility() {
            mtkView?.isHidden = !parent.previewVisible
            previewRenderer?.isVisible = parent.previewVisible
        }

        private func captureTick() {
            guard !ingestInFlight, !exportInFlight else { return }
            guard let frame = arView?.session.currentFrame else { return }
            ingestInFlight = true
            let accumulator = accumulator
            let startIndex = lastPreviewCount
            captureQueue.async { [frame, accumulator, startIndex] in
                let chunk = accumulator.ingestAndMakePreviewChunk(frame: frame, from: startIndex)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.previewRenderer?.sync(chunk: chunk)
                    self.lastPreviewCount = chunk.previewCount
                    self.parent.onCountChange(chunk.totalPointCount)
                    self.ingestInFlight = false
                }
            }
        }

        func handleFinishTokenIfNeeded() {
            guard parent.finishToken != lastFinishToken else { return }
            lastFinishToken = parent.finishToken
            guard !exportInFlight else { return }
            exportInFlight = true
            stop()
            let accumulator = accumulator
            captureQueue.async { [accumulator] in
                let export = accumulator.makeSplatExport()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.exportInFlight = false
                    self.parent.onFinished(export.data, export.count)
                }
            }
        }
    }
}
