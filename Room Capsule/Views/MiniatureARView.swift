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
    @State private var fullScale = false
    @State private var opacity: Float = 1.0
    @State private var resetToken = 0
    @State private var showPreviewFallback = false
    @State private var snapshotToken = 0
    @State private var capturedPhoto: CapturedPhoto?
    @State private var shutterFlash = false
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
                    fullScale: fullScale,
                    opacity: opacity,
                    resetToken: resetToken,
                    snapshotToken: snapshotToken,
                    pinPlacementActive: pinPlacementActive,
                    onPlacePin: { position in
                        pendingPin = PendingPinPlacement(position: position)
                        pinPlacementActive = false
                    },
                    onSelectPart: { selectedPart = $0 },
                    onPlacementChange: { isPlaced in
                        placed = isPlaced
                        // 設置もリセットも常にミニチュア表示から始める(実寸状態を持ち越さない)
                        fullScale = false
                        opacity = 1.0
                        pinPlacementActive = false
                    },
                    onGhostMoved: { ghostID, position in
                        moveGhost(ghostID: ghostID, to: position)
                    },
                    onGhostRotated: { ghostID, yaw in
                        rotateGhost(ghostID: ghostID, to: yaw)
                    },
                    onSnapshot: { image in
                        capturedPhoto = CapturedPhoto(image: image)
                    }
                )
                .ignoresSafeArea()

                // シャッターのフラッシュ演出
                Color.white
                    .ignoresSafeArea()
                    .opacity(shutterFlash ? 0.7 : 0)
                    .allowsHitTesting(false)

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
                                    resetToken += 1
                                    Haptics.light()
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                Button {
                                    fullScale.toggle()
                                    if !fullScale {
                                        opacity = 1.0
                                        pinPlacementActive = false
                                    }
                                    Haptics.medium()
                                } label: {
                                    Image(systemName: fullScale ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                        .font(.headline)
                                        .foregroundStyle(fullScale ? Color.black : Color.white)
                                        .padding(12)
                                        .background(
                                            fullScale
                                                ? AnyShapeStyle(Theme.accentGradient)
                                                : AnyShapeStyle(.ultraThinMaterial),
                                            in: Circle()
                                        )
                                }
                                if fullScale && FeatureFlags.memoPins {
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
                                }
                                Button {
                                    takeSnapshot()
                                } label: {
                                    Image(systemName: "camera.fill")
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

                    if let selectedPart {
                        PartInspectorCard(info: selectedPart) {
                            self.selectedPart = nil
                        }
                        .padding(.horizontal)
                    }

                    if placed && fullScale {
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
        .sheet(item: $capturedPhoto) { photo in
            MiniatureSnapshotSheet(image: photo.image)
        }
        .sheet(item: $pendingPin) { pending in
            MemoPinEditorView(
                capsuleID: capsuleID,
                versionID: version?.id,
                initialPosition: pending.position
            )
        }
    }

    /// フラッシュ演出 → ARView のスナップショットを撮る
    private func takeSnapshot() {
        Haptics.medium()
        shutterFlash = true
        snapshotToken += 1
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                shutterFlash = false
            }
        }
    }

    private var hintText: String {
        guard placed else { return "机や床にカメラを向けて、タップでミニチュアを設置" }
        if pinPlacementActive {
            return "壁や家具をタップしてメモピンを置く"
        }
        if fullScale {
            return "歩いて部屋の中へ・ズレたらリセットして床をタップ"
        }
        return FeatureFlags.furnitureGhosts
            ? "ピンチで拡大・2本指で回転・仮置き家具は掴んで移動"
            : "ピンチで拡大・2本指で回転"
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
    var fullScale: Bool = false
    var opacity: Float = 1.0
    var resetToken: Int
    var snapshotToken: Int = 0
    var pinPlacementActive: Bool = false
    var onPlacePin: (SIMD3<Float>) -> Void = { _ in }
    var onSelectPart: (RoomPartInfo?) -> Void
    var onPlacementChange: (Bool) -> Void
    var onGhostMoved: (UUID, SIMD3<Float>) -> Void = { _, _ in }
    var onGhostRotated: (UUID, Float) -> Void = { _, _ in }
    var onSnapshot: (UIImage) -> Void = { _ in }

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
        context.coordinator.handleSnapshotTokenIfNeeded()
        context.coordinator.refreshContentIfNeeded()
        context.coordinator.applyScaleIfNeeded()
        context.coordinator.applyOpacityIfNeeded()
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
        private var lastFullScale = false
        private var lastOpacity: Float = 1.0
        private var lastResetToken = 0
        private var lastSnapshotToken = 0
        private var draggingGhost: (entity: ModelEntity, ghostID: UUID)?
        private var rotatingGhost: (entity: ModelEntity, ghostID: UUID)?

        init(_ parent: MiniatureARContainer) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
            self.lastSnapshotToken = parent.snapshotToken
        }

        /// ARView の現在のフレームを画像として書き出す
        func handleSnapshotTokenIfNeeded() {
            guard parent.snapshotToken != lastSnapshotToken else { return }
            lastSnapshotToken = parent.snapshotToken
            guard let arView else { return }
            arView.snapshot(saveToHDR: false) { [weak self] image in
                guard let image else { return }
                Task { @MainActor [weak self] in
                    self?.parent.onSnapshot(image)
                }
            }
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

        /// 初期表示は手のひらサイズ(部屋の最長辺が約 20cm)。ピンチで自由に拡大できる
        private var defaultScale: Float {
            let size = parent.geometry.approximateSize
            let maxDimension = max(size.x, size.z)
            return min(0.2 / max(maxDimension, 0.5), 0.25)
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
            lastFullScale = false
            lastOpacity = 1.0
            // updateUIView(ビュー更新中)から呼ばれるため、state の書き換えは
            // 更新サイクルの外へ逃がす(更新中の直接変更は反映が落ちることがある)
            let onPlacementChange = parent.onPlacementChange
            Task { @MainActor in
                onPlacementChange(false)
            }
        }

        /// 実寸⇄ミニチュアの切替(設置点を基準にアニメーションで拡縮)
        func applyScaleIfNeeded() {
            guard let container, parent.fullScale != lastFullScale else { return }
            lastFullScale = parent.fullScale
            currentScale = parent.fullScale ? 1.0 : defaultScale
            var transform = container.transform
            transform.scale = SIMD3<Float>(repeating: currentScale)
            container.move(to: transform, relativeTo: container.parent, duration: 0.4)
        }

        func applyOpacityIfNeeded() {
            guard let roomEntity, parent.opacity != lastOpacity else { return }
            lastOpacity = parent.opacity
            RoomEntityFactory.applyGlobalOpacity(parent.opacity, to: roomEntity)
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
            lastOpacity = 1.0
            if parent.opacity != 1.0 {
                RoomEntityFactory.applyGlobalOpacity(parent.opacity, to: entity)
                lastOpacity = parent.opacity
            }
        }

        // MARK: ジェスチャ

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
            // 設置は常にミニチュアから。コーディネータ側のフラグもここで揃えて、
            // 直後の applyScaleIfNeeded が古い実寸状態で発火しないようにする
            currentScale = defaultScale
            lastFullScale = false
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

        /// 実寸表示中は 1:1 を保つためピンチ無効(トグルでミニチュアに戻せば再び拡縮できる)
        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let container, !parent.fullScale else { return }
            let scale = Float(recognizer.scale)
            recognizer.scale = 1
            currentScale = min(max(currentScale * scale, 0.02), 1.2)
            container.scale = SIMD3<Float>(repeating: currentScale)
        }

        /// ゴーストの上から始めた回転はゴーストを、それ以外はミニチュア全体を回す
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

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let arView, let container else { return }
            let point = recognizer.location(in: arView)
            switch recognizer.state {
            case .began:
                // ゴーストの上からドラッグを始めたら、部屋ではなくゴーストを動かす
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
                } else if let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first {
                    let t = result.worldTransform.columns.3
                    container.setPosition([t.x, t.y, t.z], relativeTo: nil)
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
    }
}

// MARK: - 撮影結果

/// UIImage はそのままでは Identifiable ではないためシート表示用に包む
struct CapturedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 撮影したミニチュアのプレビュー + 共有シート
struct MiniatureSnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        VStack(spacing: 16) {
            Text("ミニチュアを撮影しました")
                .font(.headline)
                .foregroundStyle(.white)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .frame(maxHeight: 420)

            ShareLink(
                item: Image(uiImage: image),
                preview: SharePreview("Room Capsule のミニチュア", image: Image(uiImage: image))
            ) {
                Label("共有・保存", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button("閉じる") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundTop.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
