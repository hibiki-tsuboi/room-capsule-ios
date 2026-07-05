import SwiftUI
import ARKit
import RealityKit
import Metal
import MetalKit
import UIKit
import simd

// MARK: - スプラット AR 画面

/// Gaussian Splatting を現実空間に置く。
/// ARView(カメラ映像・平面検出)の上に透明な MTKView を重ね、
/// 毎フレーム ARFrame のカメラ行列でスプラットを描画する。
struct SplatARView: View {
    @Environment(\.dismiss) private var dismiss
    let asset: SplatAsset

    private enum LoadState {
        case loading
        case ready(GaussianSplatCloud)
        case failed(String)
    }

    @State private var loadState: LoadState = .loading
    @State private var placed = false
    @State private var miniature = true
    @State private var flipUpsideDown = true
    @State private var resetToken = 0
    @State private var showViewerFallback = false

    var body: some View {
        ZStack {
            if !ARCapabilities.isARSupported {
                CapsuleBackground()
                ARUnavailableCard(
                    title: "この環境では AR が使えません",
                    message: "AR 対応端末では、写真のようなスプラットの部屋を机の上に置いたり、実寸で中に入ったりできます。代わりにビューアで表示できます。",
                    actionTitle: "ビューアで見る"
                ) {
                    showViewerFallback = true
                }
                closeOverlay
            } else {
                switch loadState {
                case .loading:
                    CapsuleBackground()
                    ProgressView("スプラットを読み込み中…")
                        .tint(Theme.accentCyan)
                        .foregroundStyle(.white)
                    closeOverlay

                case .failed(let message):
                    CapsuleBackground()
                    VStack(spacing: 14) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 48))
                            .foregroundStyle(Theme.accentGradient)
                        Text("AR 表示できませんでした")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                        Button("ビューアで見る") { showViewerFallback = true }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(26)
                    .glassCard(cornerRadius: 24)
                    .padding(24)
                    closeOverlay

                case .ready(let cloud):
                    SplatARContainer(
                        cloud: cloud,
                        flipUpsideDown: flipUpsideDown,
                        miniature: miniature,
                        resetToken: resetToken,
                        onPlacementChange: { placed = $0 }
                    )
                    .ignoresSafeArea()

                    VStack {
                        HStack(alignment: .top) {
                            Text(placed
                                 ? "ピンチで拡大縮小・2本指で回転・ドラッグで移動"
                                 : "床や机をタップしてスプラットを設置")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassCard(cornerRadius: 12)

                            Spacer()

                            VStack(spacing: 10) {
                                CloseButton { dismiss() }
                                if placed {
                                    Button {
                                        resetToken += 1
                                        placed = false
                                        Haptics.light()
                                    } label: {
                                        arIconLabel("arrow.counterclockwise")
                                    }
                                    Button {
                                        miniature.toggle()
                                        Haptics.medium()
                                    } label: {
                                        arIconLabel(miniature
                                                    ? "arrow.up.left.and.arrow.down.right"
                                                    : "arrow.down.right.and.arrow.up.left")
                                    }
                                }
                                Button {
                                    flipUpsideDown.toggle()
                                    Haptics.light()
                                } label: {
                                    arIconLabel("arrow.up.arrow.down")
                                }
                            }
                        }
                        .padding()

                        Spacer()

                        VStack(spacing: 4) {
                            Label("実レンダリング(Metal Gaussian Splatting)", systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accentCyan)
                            Text("\(cloud.count.formatted()) スプラット・\(miniature ? "ミニチュア" : "実寸")表示")
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassCard(cornerRadius: 12)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .task(id: asset.id) {
            await load()
        }
        .fullScreenCover(isPresented: $showViewerFallback) {
            SplatViewerView(asset: asset)
        }
    }

    private func arIconLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(12)
            .background(.ultraThinMaterial, in: Circle())
    }

    private var closeOverlay: some View {
        VStack {
            HStack {
                Spacer()
                CloseButton { dismiss() }
            }
            .padding()
            Spacer()
        }
    }

    private func load() async {
        guard asset.fileType != .spz else {
            loadState = .failed(".spz はこのビルドでは未対応です")
            return
        }
        let url = asset.fileURL
        let fileType = asset.fileType
        do {
            let cloud = try await Task.detached(priority: .userInitiated) {
                try GaussianSplatLoader.load(url: url, fileType: fileType)
            }.value
            if cloud.count > 0 {
                loadState = .ready(cloud)
            } else {
                loadState = .failed("スプラットが見つかりませんでした")
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - AR コンテナ(ARView + 透明 MTKView の重ね合わせ)

struct SplatARContainer: UIViewRepresentable {
    let cloud: GaussianSplatCloud
    var flipUpsideDown: Bool
    var miniature: Bool
    var resetToken: Int
    var onPlacementChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let root = UIView()

        // 下層: カメラ映像・平面検出・コーチング(RealityKit のコンテンツは置かない)
        let arView = ARView(frame: .zero)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        arView.session.run(config)
        root.addSubview(arView)

        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.frame = arView.bounds
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)

        // 上層: 透明な MTKView にスプラットを描画(タッチは下の ARView へ通す)
        let mtkView = MTKView()
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.isUserInteractionEnabled = false
        root.addSubview(mtkView)

        context.coordinator.setup(arView: arView, mtkView: mtkView)

        arView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:))))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:))))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        arView.addGestureRecognizer(pan)

        return root
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SplatARContainer
        private weak var arView: ARView?
        private var renderer: SplatARRenderer?
        private var lastResetToken = 0
        private var lastMiniature: Bool

        init(_ parent: SplatARContainer) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
            self.lastMiniature = parent.miniature
        }

        /// 部屋の最大辺が 60cm 程度になるミニチュア倍率
        private var miniatureScale: Float {
            let extent = parent.cloud.boundsMax - parent.cloud.boundsMin
            let maxDimension = max(max(extent.x, extent.z), 0.5)
            return min(0.6 / maxDimension, 0.25)
        }

        func setup(arView: ARView, mtkView: MTKView) {
            self.arView = arView
            guard let renderer = try? SplatARRenderer(cloud: parent.cloud) else { return }
            renderer.arSession = arView.session
            renderer.flipUpsideDown = parent.flipUpsideDown
            mtkView.device = renderer.device
            mtkView.delegate = renderer
            self.renderer = renderer // MTKView.delegate は weak なのでここで保持
        }

        func sync() {
            guard let renderer else { return }
            renderer.flipUpsideDown = parent.flipUpsideDown
            if parent.resetToken != lastResetToken {
                lastResetToken = parent.resetToken
                renderer.isPlaced = false
            }
            if parent.miniature != lastMiniature {
                lastMiniature = parent.miniature
                renderer.targetScale = parent.miniature ? miniatureScale : 1.0
            }
        }

        // MARK: ジェスチャ

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView, let renderer, !renderer.isPlaced else { return }
            let point = recognizer.location(in: arView)
            guard let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
            else { return }
            let t = result.worldTransform.columns.3
            let scale = parent.miniature ? miniatureScale : 1.0
            renderer.place(at: [t.x, t.y, t.z], scale: scale)
            parent.onPlacementChange(true)
            Haptics.success()
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let renderer, renderer.isPlaced else { return }
            let scale = Float(recognizer.scale)
            recognizer.scale = 1
            let next = min(max(renderer.targetScale * scale, 0.02), 1.6)
            renderer.targetScale = next
            renderer.scale = next
        }

        @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            guard let renderer, renderer.isPlaced else { return }
            let rotation = Float(recognizer.rotation)
            recognizer.rotation = 0
            renderer.yaw -= rotation
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let arView, let renderer, renderer.isPlaced, recognizer.state == .changed else { return }
            let point = recognizer.location(in: arView)
            guard let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
            else { return }
            let t = result.worldTransform.columns.3
            renderer.position = [t.x, t.y, t.z]
        }
    }
}

// MARK: - AR 用レンダラー

/// ARFrame のカメラ行列でスプラットを描く MTKView デリゲート。
/// モデル行列(位置・回転・スケール)はビュー行列に合成される —
/// シェーダは上位 3x3 をそのまま共分散投影に使うため、一様スケールも
/// s²·Σ として正しく伝播する(シェーダ変更は不要)。
@MainActor
final class SplatARRenderer: NSObject, MTKViewDelegate {
    private let core: SplatRenderCore
    weak var arSession: ARSession?
    var device: MTLDevice { core.device }

    // 配置状態
    var isPlaced = false
    var position: SIMD3<Float> = .zero
    var yaw: Float = 0
    var scale: Float = 1
    /// ミニチュア⇄実寸の切り替えを滑らかにするための目標倍率
    var targetScale: Float = 1
    var flipUpsideDown = true

    init(cloud: GaussianSplatCloud) throws {
        self.core = try SplatRenderCore(cloud: cloud)
        super.init()
    }

    func place(at worldPosition: SIMD3<Float>, scale initialScale: Float) {
        position = worldPosition
        scale = initialScale
        targetScale = initialScale
        isPlaced = true
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            render(in: view)
        }
    }

    private func render(in view: MTKView) {
        let size = view.drawableSize
        guard size.width > 1, size.height > 1 else { return }

        guard isPlaced, let frame = arSession?.currentFrame else {
            // 未配置・フレーム未取得の間は透明クリアだけ流す
            core.render(in: view, uniforms: .placeholder(viewport: size), visible: false)
            return
        }

        // ミニチュア⇄実寸のスムーズなスケール補間
        if abs(scale - targetScale) > 0.0005 {
            scale += (targetScale - scale) * 0.18
        }

        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewportSize = CGSize(width: size.width, height: size.height)
        let projection = frame.camera.projectionMatrix(
            for: orientation, viewportSize: viewportSize, zNear: 0.02, zFar: 80
        )
        let cameraView = frame.camera.viewMatrix(for: orientation)
        let combined = cameraView * modelMatrix()
        let inverse = combined.inverse

        let uniforms = SplatUniforms(
            view: combined,
            projection: projection,
            viewport: [Float(size.width), Float(size.height)],
            focal: [
                projection.columns.0.x * Float(size.width) / 2,
                projection.columns.1.y * Float(size.height) / 2,
            ],
            cameraPosition: SIMD3<Float>(inverse.columns.3.x, inverse.columns.3.y, inverse.columns.3.z),
            shDegree: Int32(core.shDegree)
        )
        core.resortIfNeeded(combinedView: combined)
        core.render(in: view, uniforms: uniforms)
    }

    /// 配置位置・向き・倍率(+ 上下反転補正)のモデル行列。
    /// 反転後の最下端が設置面に着くよう持ち上げる。
    private func modelMatrix() -> simd_float4x4 {
        let cloud = core.cloud
        let minYAfterFlip = flipUpsideDown ? -cloud.boundsMax.y : cloud.boundsMin.y
        let lift = -minYAfterFlip * scale
        var matrix = SplatMetalRenderer.translation(position + SIMD3<Float>(0, lift, 0))
            * SplatMetalRenderer.rotationY(yaw)
        if flipUpsideDown {
            matrix = matrix * SplatMetalRenderer.rotationX(.pi)
        }
        return matrix * SplatMetalRenderer.uniformScale(scale)
    }
}
