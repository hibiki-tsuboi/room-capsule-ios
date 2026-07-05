import SwiftUI
import ARKit
import RealityKit
import Metal
import MetalKit
import UIKit
import simd

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
            } else {
                SplatCaptureContainer(
                    finishToken: finishToken,
                    previewVisible: previewVisible,
                    onCountChange: { pointCount = $0 },
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
        .alert("保存に失敗しました", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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
    var onFinished: (Data, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let root = UIView()

        // 下層: カメラ映像 + LiDAR 深度
        let arView = ARView(frame: .zero)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = .smoothedSceneDepth
        } else {
            config.frameSemantics = .sceneDepth
        }
        arView.session.run(config)
        root.addSubview(arView)

        // 上層: 収集済みスプラットのライブプレビュー(タッチは透過)
        let mtkView = MTKView()
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.isUserInteractionEnabled = false
        root.addSubview(mtkView)

        context.coordinator.start(arView: arView, mtkView: mtkView)
        return root
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncPreviewVisibility()
        context.coordinator.handleFinishTokenIfNeeded()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SplatCaptureContainer
        private weak var arView: ARView?
        private weak var mtkView: MTKView?
        private var previewRenderer: LiveSplatPreviewRenderer?
        private let accumulator = LiDARSplatAccumulator()
        private var captureTimer: Timer?
        private var lastFinishToken = 0

        init(_ parent: SplatCaptureContainer) {
            self.parent = parent
            self.lastFinishToken = parent.finishToken
        }

        func start(arView: ARView, mtkView: MTKView) {
            self.arView = arView
            self.mtkView = mtkView

            if let renderer = try? LiveSplatPreviewRenderer(
                capacity: accumulator.maxPoints,
                voxelSize: accumulator.voxelSize
            ) {
                renderer.arSession = arView.session
                mtkView.device = renderer.device
                mtkView.delegate = renderer
                previewRenderer = renderer // MTKView.delegate は weak なのでここで保持
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

        func syncPreviewVisibility() {
            mtkView?.isHidden = !parent.previewVisible
            previewRenderer?.isVisible = parent.previewVisible
        }

        private func captureTick() {
            guard let frame = arView?.session.currentFrame else { return }
            accumulator.ingest(frame: frame)
            previewRenderer?.sync(with: accumulator)
            parent.onCountChange(accumulator.pointCount)
        }

        func handleFinishTokenIfNeeded() {
            guard parent.finishToken != lastFinishToken else { return }
            lastFinishToken = parent.finishToken
            stop()
            let count = accumulator.pointCount
            let data = accumulator.makeSplatData()
            parent.onFinished(data, count)
        }
    }
}
