import SwiftUI
import ARKit
import RealityKit
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
                                Text("近づいて撮るほど色が鮮明になります")
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.5))
                            }
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 14)

                        Spacer()

                        CloseButton { dismiss() }
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
    var onCountChange: (Int) -> Void
    var onFinished: (Data, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = .smoothedSceneDepth
        } else {
            config.frameSemantics = .sceneDepth
        }
        arView.session.run(config)
        context.coordinator.start(arView: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.handleFinishTokenIfNeeded()
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SplatCaptureContainer
        private weak var arView: ARView?
        private let accumulator = LiDARSplatAccumulator()
        private var captureTimer: Timer?
        private var lastFinishToken = 0

        init(_ parent: SplatCaptureContainer) {
            self.parent = parent
            self.lastFinishToken = parent.finishToken
        }

        func start(arView: ARView) {
            self.arView = arView
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
        }

        private func captureTick() {
            guard let frame = arView?.session.currentFrame else { return }
            accumulator.ingest(frame: frame)
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
