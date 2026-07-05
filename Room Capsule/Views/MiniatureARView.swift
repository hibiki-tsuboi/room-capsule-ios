import SwiftUI
import RealityKit
import ARKit
import UIKit
import simd

// MARK: - ミニチュア AR 画面(メイン体験)

/// スキャンした部屋をドールハウスとして机や床に置く
struct MiniatureARView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    let versionID: UUID?

    @State private var mode: RoomDisplayMode = .model
    @State private var selectedPart: RoomPartInfo?
    @State private var placed = false
    @State private var resetToken = 0
    @State private var showPreviewFallback = false

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var version: RoomScanVersion? {
        capsule?.version(id: versionID) ?? capsule?.latestVersion
    }

    var body: some View {
        ZStack {
            if !ARCapabilities.isARSupported {
                CapsuleBackground()
                ARUnavailableCard(
                    title: "この環境では AR が使えません",
                    message: "シミュレータや AR 非対応端末では、代わりに 3D プレビューでミニチュアを確認できます。",
                    actionTitle: "3Dプレビューで見る"
                ) {
                    showPreviewFallback = true
                }
                closeOverlay
            } else if let capsule, let version {
                MiniatureARContainer(
                    geometry: version.simplifiedGeometry,
                    pins: capsule.pins(forVersion: version.id),
                    ghosts: capsule.ghosts(forVersion: version.id),
                    mode: mode,
                    usdzURL: version.usdzURL,
                    resetToken: resetToken,
                    onSelectPart: { selectedPart = $0 },
                    onPlacementChange: { placed = $0 }
                )
                .ignoresSafeArea()

                VStack {
                    HStack(alignment: .top) {
                        Text(placed
                             ? "ピンチで拡大縮小・2本指で回転・ドラッグで移動"
                             : "机や床にカメラを向けて、タップでミニチュアを設置")
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
                                    Haptics.light()
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                            }
                        }
                    }
                    .padding()

                    Spacer()

                    if let selectedPart {
                        PartInspectorCard(info: selectedPart) {
                            self.selectedPart = nil
                        }
                        .padding(.horizontal)
                    }

                    ModeChipsBar(
                        modes: RoomDisplayMode.availableModes(hasUSDZ: version.usdzURL != nil),
                        selection: $mode
                    )
                    .padding(.bottom, 12)
                }
            } else {
                CapsuleBackground()
                ContentUnavailableView("表示できるバージョンがありません", systemImage: "cube.transparent")
                closeOverlay
            }
        }
        .fullScreenCover(isPresented: $showPreviewFallback) {
            RoomImmersivePreviewView(capsuleID: capsuleID, versionID: versionID, title: "ミニチュア(3Dプレビュー)")
        }
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
}

// MARK: - AR コンテナ

struct MiniatureARContainer: UIViewRepresentable {
    var geometry: SimplifiedRoomGeometry
    var pins: [RoomMemoPin]
    var ghosts: [FurnitureGhost]
    var mode: RoomDisplayMode
    var usdzURL: URL? = nil
    var resetToken: Int
    var onSelectPart: (RoomPartInfo?) -> Void
    var onPlacementChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.handleResetTokenIfNeeded()
        context.coordinator.refreshContentIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MiniatureARContainer
        private weak var arView: ARView?
        private var placementAnchor: AnchorEntity?
        /// ジェスチャによる拡大縮小・回転を保持するコンテナ
        private var container: Entity?
        private var roomEntity: Entity?
        private let selection = RoomSelectionManager()
        private var contentSignature: Int?
        private var currentScale: Float = 0.12
        private var lastResetToken = 0

        init(_ parent: MiniatureARContainer) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
        }

        func attach(to arView: ARView) {
            self.arView = arView

            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            config.environmentTexturing = .automatic
            arView.session.run(config)

            let coaching = ARCoachingOverlayView()
            coaching.session = arView.session
            coaching.goal = .horizontalPlane
            coaching.frame = arView.bounds
            coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            arView.addSubview(coaching)

            arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
            arView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
            arView.addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:))))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            arView.addGestureRecognizer(pan)
        }

        private var defaultScale: Float {
            let size = parent.geometry.approximateSize
            let maxDimension = max(size.x, size.z)
            return min(0.6 / max(maxDimension, 0.5), 0.25)
        }

        func handleResetTokenIfNeeded() {
            guard parent.resetToken != lastResetToken else { return }
            lastResetToken = parent.resetToken
            reset()
        }

        private func reset() {
            selection.clearSelection()
            placementAnchor?.removeFromParent()
            placementAnchor = nil
            container = nil
            roomEntity = nil
            parent.onPlacementChange(false)
        }

        func refreshContentIfNeeded() {
            guard container != nil else { return }
            var hasher = Hasher()
            hasher.combine(parent.geometry)
            hasher.combine(parent.pins)
            hasher.combine(parent.ghosts)
            hasher.combine(parent.mode)
            hasher.combine(parent.usdzURL)
            let signature = hasher.finalize()
            guard signature != contentSignature else { return }
            contentSignature = signature
            rebuildRoom()
        }

        private func rebuildRoom() {
            guard let container else { return }
            selection.clearSelection()
            roomEntity?.removeFromParent()
            let entity = RoomEntityFactory.makeRoomEntity(
                geometry: parent.geometry,
                pins: parent.pins,
                ghosts: parent.ghosts,
                mode: parent.mode,
                usdzURL: parent.usdzURL
            )
            container.addChild(entity)
            roomEntity = entity
        }

        // MARK: ジェスチャ

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView else { return }
            let point = recognizer.location(in: arView)

            if container == nil {
                place(at: point)
                return
            }
            let info = selection.handleTap(at: point, in: arView)
            parent.onSelectPart(info)
        }

        private func place(at point: CGPoint) {
            guard let arView,
                  let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
            else { return }

            let anchor = AnchorEntity(world: result.worldTransform)
            arView.scene.addAnchor(anchor)
            placementAnchor = anchor

            let newContainer = Entity()
            currentScale = defaultScale
            newContainer.scale = SIMD3<Float>(repeating: currentScale)
            anchor.addChild(newContainer)
            container = newContainer

            contentSignature = nil
            refreshContentSignatureAndBuild()
            parent.onPlacementChange(true)
            Haptics.success()
        }

        private func refreshContentSignatureAndBuild() {
            var hasher = Hasher()
            hasher.combine(parent.geometry)
            hasher.combine(parent.pins)
            hasher.combine(parent.ghosts)
            hasher.combine(parent.mode)
            hasher.combine(parent.usdzURL)
            contentSignature = hasher.finalize()
            rebuildRoom()
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let container else { return }
            let scale = Float(recognizer.scale)
            recognizer.scale = 1
            currentScale = min(max(currentScale * scale, 0.02), 1.2)
            container.scale = SIMD3<Float>(repeating: currentScale)
        }

        @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            guard let container else { return }
            let rotation = Float(recognizer.rotation)
            recognizer.rotation = 0
            container.orientation = simd_quatf(angle: -rotation, axis: [0, 1, 0]) * container.orientation
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let arView, let container, recognizer.state == .changed else { return }
            let point = recognizer.location(in: arView)
            guard let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
            else { return }
            let t = result.worldTransform.columns.3
            container.setPosition([t.x, t.y, t.z], relativeTo: nil)
        }
    }
}
