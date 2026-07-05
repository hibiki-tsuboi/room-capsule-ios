import SwiftUI
import RealityKit
import ARKit
import UIKit
import simd

// MARK: - 実寸 AR 画面

/// 保存した部屋を、今いる空間に 1:1 サイズで呼び出す
struct FullScaleARView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    let versionID: UUID?

    @State private var mode: RoomDisplayMode = .model
    @State private var selectedPart: RoomPartInfo?
    @State private var placed = false
    @State private var opacity: Float = 1.0
    @State private var miniature = false
    @State private var resetToken = 0
    @State private var showPreviewFallback = false
    @State private var pinPlacementActive = false
    @State private var pendingPin: PendingPinPlacement?

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
                    message: "実寸 AR には対応端末が必要です。代わりに 3D プレビューで部屋の中を確認できます。",
                    actionTitle: "3Dプレビューで見る"
                ) {
                    showPreviewFallback = true
                }
                closeOverlay
            } else if let capsule, let version {
                FullScaleARContainer(
                    geometry: version.simplifiedGeometry,
                    pins: capsule.pins(forVersion: version.id),
                    ghosts: capsule.ghosts(forVersion: version.id),
                    mode: mode,
                    usdzURL: version.usdzURL,
                    opacity: opacity,
                    miniature: miniature,
                    resetToken: resetToken,
                    pinPlacementActive: pinPlacementActive,
                    onPlacePin: { position in
                        pendingPin = PendingPinPlacement(position: position)
                        pinPlacementActive = false
                    },
                    onSelectPart: { selectedPart = $0 },
                    onPlacementChange: { placed = $0 },
                    onGhostMoved: { ghostID, position in
                        moveGhost(ghostID: ghostID, to: position)
                    },
                    onGhostRotated: { ghostID, yaw in
                        rotateGhost(ghostID: ghostID, to: yaw)
                    }
                )
                .ignoresSafeArea()

                VStack {
                    HStack(alignment: .top) {
                        Text(hintText)
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
                                    pinPlacementActive.toggle()
                                    Haptics.light()
                                } label: {
                                    Image(systemName: pinPlacementActive ? "mappin.circle.fill" : "mappin.circle")
                                        .font(.headline)
                                        .foregroundStyle(pinPlacementActive ? Color.black : Color.white)
                                        .padding(12)
                                        .background(
                                            pinPlacementActive
                                                ? AnyShapeStyle(Theme.accentGradient)
                                                : AnyShapeStyle(.ultraThinMaterial),
                                            in: Circle()
                                        )
                                }
                                Button {
                                    resetToken += 1
                                    placed = false
                                    Haptics.light()
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                Button {
                                    miniature.toggle()
                                    Haptics.medium()
                                } label: {
                                    Image(systemName: miniature ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
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

                    if placed {
                        HStack(spacing: 10) {
                            Image(systemName: "circle.dotted")
                                .foregroundStyle(Color.white.opacity(0.6))
                            Slider(value: $opacity, in: 0.1...1.0)
                                .tint(Theme.accentCyan)
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color.white.opacity(0.9))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCard(cornerRadius: 14)
                        .padding(.horizontal)
                    }

                    ModeChipsBar(modes: fullScaleModes, selection: $mode)
                        .padding(.bottom, 12)
                }
            } else {
                CapsuleBackground()
                ContentUnavailableView("表示できるバージョンがありません", systemImage: "cube.transparent")
                closeOverlay
            }
        }
        .fullScreenCover(isPresented: $showPreviewFallback) {
            RoomImmersivePreviewView(
                capsuleID: capsuleID,
                versionID: versionID,
                startsInside: true,
                title: "実寸(3Dプレビュー)"
            )
        }
        .sheet(item: $pendingPin) { pending in
            MemoPinEditorView(
                capsuleID: capsuleID,
                versionID: version?.id,
                initialPosition: pending.position
            )
        }
    }

    private var hintText: String {
        if !placed {
            return "床をタップして部屋の原点を設置"
        }
        if pinPlacementActive {
            return "壁や家具をタップしてメモピンを置く"
        }
        return "スライダーで透明度調整・ゴーストは掴んで移動"
    }

    private func moveGhost(ghostID: UUID, to position: SIMD3<Float>) {
        guard let capsule,
              var ghost = capsule.furnitureGhosts.first(where: { $0.id == ghostID }) else { return }
        ghost.position = position
        store.upsertGhost(ghost, in: capsuleID)
    }

    private func rotateGhost(ghostID: UUID, to yaw: Float) {
        guard let capsule,
              var ghost = capsule.furnitureGhosts.first(where: { $0.id == ghostID }) else { return }
        ghost.rotationY = yaw
        store.upsertGhost(ghost, in: capsuleID)
    }

    /// 実寸 AR で選べるモード(USDZ があれば高品質を先頭寄りに追加)
    private var fullScaleModes: [RoomDisplayMode] {
        var modes: [RoomDisplayMode] = [.model, .xray, .structureOnly, .furnitureOnly, .memo]
        if version?.usdzURL != nil {
            modes.insert(.scanModel, at: 1)
        }
        return modes
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

struct FullScaleARContainer: UIViewRepresentable {
    var geometry: SimplifiedRoomGeometry
    var pins: [RoomMemoPin]
    var ghosts: [FurnitureGhost]
    var mode: RoomDisplayMode
    var usdzURL: URL? = nil
    var opacity: Float
    var miniature: Bool
    var resetToken: Int
    var pinPlacementActive: Bool = false
    var onPlacePin: (SIMD3<Float>) -> Void = { _ in }
    var onSelectPart: (RoomPartInfo?) -> Void
    var onPlacementChange: (Bool) -> Void
    var onGhostMoved: (UUID, SIMD3<Float>) -> Void = { _, _ in }
    var onGhostRotated: (UUID, Float) -> Void = { _, _ in }

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
        context.coordinator.applyOpacityIfNeeded()
        context.coordinator.applyScaleIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: FullScaleARContainer
        private weak var arView: ARView?
        private var placementAnchor: AnchorEntity?
        private var container: Entity?
        private var roomEntity: Entity?
        private let selection = RoomSelectionManager()
        private var contentSignature: Int?
        private var lastOpacity: Float = 1.0
        private var lastMiniature = false
        private var lastResetToken = 0
        private var draggingGhost: (entity: ModelEntity, ghostID: UUID)?
        private var rotatingGhost: (entity: ModelEntity, ghostID: UUID)?

        init(_ parent: FullScaleARContainer) {
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
            arView.addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:))))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            arView.addGestureRecognizer(pan)
        }

        /// 実寸 AR ではゴーストのドラッグ移動だけにパンを使う(部屋の原点は固定)
        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let arView else { return }
            let point = recognizer.location(in: arView)
            switch recognizer.state {
            case .began:
                if let hit = GhostDragHelper.ghostEntity(at: point, in: arView) {
                    draggingGhost = hit
                    hit.entity.scale *= 1.06
                    Haptics.light()
                }
            case .changed:
                if let dragging = draggingGhost {
                    GhostDragHelper.updateDragPosition(
                        point: point, arView: arView, dragging: dragging,
                        roomEntity: roomEntity, geometry: parent.geometry
                    )
                }
            case .ended, .cancelled, .failed:
                if let dragging = draggingGhost {
                    dragging.entity.scale /= 1.06
                    parent.onGhostMoved(dragging.ghostID, dragging.entity.position)
                    Haptics.success()
                }
                draggingGhost = nil
            default:
                break
            }
        }

        func handleResetTokenIfNeeded() {
            guard parent.resetToken != lastResetToken else { return }
            lastResetToken = parent.resetToken
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

        func applyOpacityIfNeeded() {
            guard let roomEntity, parent.opacity != lastOpacity else { return }
            lastOpacity = parent.opacity
            RoomEntityFactory.applyGlobalOpacity(parent.opacity, to: roomEntity)
        }

        func applyScaleIfNeeded() {
            guard let container, parent.miniature != lastMiniature else { return }
            lastMiniature = parent.miniature
            let targetScale: Float = parent.miniature ? 0.12 : 1.0
            var transform = container.transform
            transform.scale = SIMD3<Float>(repeating: targetScale)
            container.move(to: transform, relativeTo: container.parent, duration: 0.4)
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
            lastOpacity = 1.0
            if parent.opacity != 1.0 {
                RoomEntityFactory.applyGlobalOpacity(parent.opacity, to: entity)
                lastOpacity = parent.opacity
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView else { return }
            let point = recognizer.location(in: arView)

            if container == nil {
                place(at: point)
                return
            }
            if parent.pinPlacementActive {
                if let hit = arView.hitTest(point).first,
                   let content = roomEntity?.findEntity(named: "RoomContent") {
                    let localPosition = content.convert(position: hit.position, from: nil)
                    parent.onPlacePin(localPosition)
                    Haptics.success()
                }
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
            anchor.addChild(newContainer)
            container = newContainer
            lastMiniature = false

            contentSignature = nil
            refreshContentIfNeeded()
            parent.onPlacementChange(true)
            Haptics.success()
        }

        /// ゴーストの上から始めた回転はゴーストを、それ以外は部屋全体を回す
        @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            guard let arView, let container else { return }
            switch recognizer.state {
            case .began:
                if let hit = GhostDragHelper.ghostEntity(at: recognizer.location(in: arView), in: arView) {
                    rotatingGhost = hit
                    Haptics.light()
                }
            case .changed:
                let rotation = Float(recognizer.rotation)
                recognizer.rotation = 0
                if let rotating = rotatingGhost {
                    rotating.entity.orientation = simd_quatf(angle: -rotation, axis: [0, 1, 0]) * rotating.entity.orientation
                } else {
                    container.orientation = simd_quatf(angle: -rotation, axis: [0, 1, 0]) * container.orientation
                }
            case .ended, .cancelled, .failed:
                if let rotating = rotatingGhost {
                    parent.onGhostRotated(rotating.ghostID, GhostDragHelper.yaw(of: rotating.entity))
                    Haptics.success()
                }
                rotatingGhost = nil
            default:
                break
            }
        }
    }
}
