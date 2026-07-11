import SwiftUI
import RealityKit
import UIKit
import simd

// MARK: - 3D プレビュー画面

/// AR ではない 3D プレビュー。シミュレータや AR 非対応端末でも動く。
/// ポータルから「中に入った」ときの部屋内ビューとしても使う。
struct RoomImmersivePreviewView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss

    let capsuleID: UUID
    let versionID: UUID?
    let startsInside: Bool
    let title: String

    @State private var mode: RoomDisplayMode
    @State private var selectedPart: RoomPartInfo?
    @State private var pinPlacementActive = false
    @State private var pendingPin: PendingPinPlacement?
    /// ポータル出入りのトランジション(白フェード)
    @State private var introFlash: Bool
    @State private var exitFlash = false

    init(
        capsuleID: UUID,
        versionID: UUID?,
        initialMode: RoomDisplayMode = .model,
        startsInside: Bool = false,
        title: String = "3Dプレビュー"
    ) {
        self.capsuleID = capsuleID
        self.versionID = versionID
        self.startsInside = startsInside
        self.title = title
        _mode = State(initialValue: initialMode)
        _introFlash = State(initialValue: startsInside)
    }

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
                    pins: capsule.pins(forVersion: version.id),
                    ghosts: capsule.ghosts(forVersion: version.id),
                    mode: mode,
                    usdzURL: version.usdzURL,
                    startsInside: startsInside,
                    pinPlacementActive: pinPlacementActive,
                    onSelectPart: { selectedPart = $0 },
                    onPlacePin: { position in
                        pendingPin = PendingPinPlacement(position: position)
                        pinPlacementActive = false
                    },
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
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
                            CloseButton { closeTapped() }
                            if FeatureFlags.memoPins {
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
                        }
                    }
                    .padding()

                    if pinPlacementActive {
                        Text("部屋のどこかをタップしてメモピンを置く")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassCard(cornerRadius: 12)
                    } else {
                        Text(orbitHintText)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.55))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.35), in: Capsule())
                    }

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
                ContentUnavailableView("表示できるバージョンがありません", systemImage: "cube.transparent")
                VStack {
                    HStack {
                        Spacer()
                        CloseButton { dismiss() }
                    }
                    .padding()
                    Spacer()
                }
            }

            // ポータル出入り用の白フェード
            Color.white
                .ignoresSafeArea()
                .opacity(introFlash || exitFlash ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onAppear {
            if startsInside {
                withAnimation(.easeOut(duration: 0.9).delay(0.1)) {
                    introFlash = false
                }
            }
        }
        .sheet(item: $pendingPin) { pending in
            MemoPinEditorView(
                capsuleID: capsuleID,
                versionID: version?.id,
                initialPosition: pending.position
            )
        }
    }

    /// ポータルから入った場合は白フェードしてから閉じる
    private func closeTapped() {
        guard startsInside else {
            dismiss()
            return
        }
        withAnimation(.easeIn(duration: 0.22)) {
            exitFlash = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 240_000_000)
            dismiss()
        }
    }

    private var orbitHintText: String {
        if startsInside { return "ドラッグで見回す・ピンチで前後に移動" }
        return FeatureFlags.furnitureGhosts
            ? "ドラッグで回転・タップで選択・仮置き家具は掴んで移動"
            : "ドラッグで回転・タップで選択"
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
}

/// SIMD3 は Identifiable ではないのでシート表示用に包む
struct PendingPinPlacement: Identifiable {
    let id = UUID()
    let position: SIMD3<Float>
}

// MARK: - 非 AR の RealityKit コンテナ(オービットカメラ)

struct RoomPreviewARContainer: UIViewRepresentable {
    var geometry: SimplifiedRoomGeometry
    var pins: [RoomMemoPin]
    var ghosts: [FurnitureGhost]
    var mode: RoomDisplayMode
    var usdzURL: URL? = nil
    var startsInside: Bool
    var pinPlacementActive: Bool
    var onSelectPart: (RoomPartInfo?) -> Void
    var onPlacePin: (SIMD3<Float>) -> Void
    var onGhostMoved: (UUID, SIMD3<Float>) -> Void = { _, _ in }
    var onGhostRotated: (UUID, Float) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1))
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refreshContentIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: RoomPreviewARContainer
        private weak var arView: ARView?
        private var worldAnchor: AnchorEntity?
        private var roomEntity: Entity?
        private var cameraEntity: PerspectiveCamera?
        private let selection = RoomSelectionManager()
        private var contentSignature: Int?

        // オービットカメラの状態
        private var yaw: Float = -0.7
        private var pitch: Float = 0.35
        private var radius: Float = 5
        private var baseRadius: Float = 5
        private var insideEye: SIMD3<Float> = [0, 1.4, 0]
        private var draggingGhost: (entity: ModelEntity, ghostID: UUID)?
        private var rotatingGhost: (entity: ModelEntity, ghostID: UUID)?
        private var dollyTimer: Timer?

        init(_ parent: RoomPreviewARContainer) {
            self.parent = parent
        }

        func attach(to arView: ARView) {
            self.arView = arView

            let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
            arView.scene.addAnchor(anchor)
            worldAnchor = anchor

            let camera = PerspectiveCamera()
            // 部屋の中では縦持ちの水平視野が狭くなりすぎるため広角にする
            camera.camera.fieldOfViewInDegrees = parent.startsInside ? 85 : 60
            anchor.addChild(camera)
            cameraEntity = camera

            // 非 AR では環境光が乏しいのでライトを足す
            let keyLight = DirectionalLight()
            keyLight.light.intensity = 3200
            keyLight.look(at: [0, 0, 0], from: [2.5, 4.5, 3], relativeTo: nil)
            anchor.addChild(keyLight)

            let fillLight = DirectionalLight()
            fillLight.light.intensity = 1400
            fillLight.look(at: [0, 0, 0], from: [-3, 2.5, -2], relativeTo: nil)
            anchor.addChild(fillLight)

            let roomLight = PointLight()
            roomLight.light.intensity = 12_000
            roomLight.position = [0, 2.0, 0]
            anchor.addChild(roomLight)

            arView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
            arView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
            arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
            arView.addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:))))

            setupCameraDefaults()
            refreshContentIfNeeded(force: true)
            updateCamera()
            if parent.startsInside {
                startDollyIn()
            }
        }

        private func setupCameraDefaults() {
            let size = parent.geometry.approximateSize
            // ドールハウスを少し上から見下ろす引きのカメラ
            baseRadius = max(simd_length(size) * 1.5, 3.5)
            if parent.startsInside {
                insideEye = [0, min(1.5, size.y * 0.6), 0]
                aimAtFurniture()
            } else {
                radius = baseRadius
                yaw = -0.7
                pitch = 0.62
            }
        }

        func refreshContentIfNeeded(force: Bool = false) {
            var hasher = Hasher()
            hasher.combine(parent.geometry)
            hasher.combine(parent.pins)
            hasher.combine(parent.ghosts)
            hasher.combine(parent.mode)
            hasher.combine(parent.usdzURL)
            let signature = hasher.finalize()
            guard force || signature != contentSignature else { return }
            contentSignature = signature

            selection.clearSelection()
            roomEntity?.removeFromParent()
            let entity = RoomEntityFactory.makeRoomEntity(
                geometry: parent.geometry,
                pins: parent.pins,
                ghosts: parent.ghosts,
                mode: parent.mode,
                usdzURL: parent.usdzURL
            )
            worldAnchor?.addChild(entity)
            roomEntity = entity
        }

        // MARK: ジェスチャ

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, let arView else { return }
            let point = recognizer.location(in: view)

            // ゴーストの上からドラッグを始めたら、カメラではなくゴーストを動かす
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
                    recognizer.setTranslation(.zero, in: view)
                    return
                }
            case .ended, .cancelled, .failed:
                if let dragging = draggingGhost {
                    dragging.entity.scale /= 1.06
                    parent.onGhostMoved(dragging.ghostID, dragging.entity.position)
                    Haptics.success()
                    draggingGhost = nil
                    return
                }
            default:
                break
            }
            if draggingGhost != nil { return }

            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            yaw -= Float(translation.x) * 0.008
            let pitchDelta = Float(translation.y) * 0.006
            if parent.startsInside {
                pitch = min(max(pitch + pitchDelta, -0.9), 0.9)
            } else {
                pitch = min(max(pitch + pitchDelta, -0.15), 1.45)
            }
            updateCamera()
        }

        /// 入室直後に一番大きな家具が視界に収まるよう、家具の反対側に立って視線を向ける。家具がなければ正面
        private func aimAtFurniture() {
            guard let target = largestFurnitureCenter() else {
                yaw = 0
                pitch = 0
                return
            }
            let size = parent.geometry.approximateSize
            let toFurniture = SIMD2(target.x, target.z)
            let planarDistance = simd_length(toFurniture)
            if planarDistance > 0.001 {
                let backoff = min(min(size.x, size.z) * 0.45, 2.2)
                var eyeXZ = -(toFurniture / planarDistance) * backoff
                eyeXZ.x = min(max(eyeXZ.x, -size.x / 2 + 0.2), size.x / 2 - 0.2)
                eyeXZ.y = min(max(eyeXZ.y, -size.z / 2 + 0.2), size.z / 2 - 0.2)
                insideEye.x = eyeXZ.x
                insideEye.z = eyeXZ.y
            }
            let dx = target.x - insideEye.x
            let dz = target.z - insideEye.z
            yaw = atan2(dx, -dz)
            let horizontalDistance = max(simd_length(SIMD2(dx, dz)), 0.001)
            pitch = min(max(atan2(target.y - insideEye.y, horizontalDistance), -0.7), 0.2)
        }

        /// 表示座標系(水平中心が原点・床が y=0)での体積最大の家具の中心
        private func largestFurnitureCenter() -> SIMD3<Float>? {
            guard let largest = parent.geometry.furniture.max(by: {
                $0.size.x * $0.size.y * $0.size.z < $1.size.x * $1.size.y * $1.size.z
            }) else { return nil }
            let center = parent.geometry.horizontalCenter
            return [
                largest.position.x - center.x,
                largest.position.y - parent.geometry.floorY,
                largest.position.z - center.y
            ]
        }

        /// 入室時、視線方向に沿って立ち位置へ歩き入るカメラ演出
        private func startDollyIn() {
            let size = parent.geometry.approximateSize
            let startDistance = min(min(size.x, size.z) * 0.32, 1.2)
            let direction = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
            let finalEye = insideEye
            var startEye = finalEye - direction * startDistance
            startEye.x = min(max(startEye.x, -size.x / 2 + 0.1), size.x / 2 - 0.1)
            startEye.z = min(max(startEye.z, -size.z / 2 + 0.1), size.z / 2 - 0.1)
            let start = Date()
            let duration: Double = 1.4
            insideEye.x = startEye.x
            insideEye.z = startEye.z
            updateCamera()
            dollyTimer?.invalidate()
            dollyTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else {
                        timer.invalidate()
                        return
                    }
                    let t = min(Date().timeIntervalSince(start) / duration, 1)
                    let eased = Float(1 - pow(1 - t, 3))
                    self.insideEye.x = startEye.x + (finalEye.x - startEye.x) * eased
                    self.insideEye.z = startEye.z + (finalEye.z - startEye.z) * eased
                    self.updateCamera()
                    if t >= 1 {
                        timer.invalidate()
                    }
                }
            }
        }

        /// プレビューではゴーストの上から始めた回転だけを扱う(部屋はドラッグで回すため)
        @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
            guard let arView else { return }
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

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            let scale = Float(recognizer.scale)
            recognizer.scale = 1
            if parent.startsInside {
                // ピンチで前進 / 後退(部屋の中を歩く感じ)
                let direction = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
                insideEye += direction * (scale - 1) * 2.0
                let size = parent.geometry.approximateSize
                insideEye.x = min(max(insideEye.x, -size.x / 2 + 0.2), size.x / 2 - 0.2)
                insideEye.z = min(max(insideEye.z, -size.z / 2 + 0.2), size.z / 2 - 0.2)
            } else {
                radius = min(max(radius / scale, baseRadius * 0.25), baseRadius * 3)
            }
            updateCamera()
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView else { return }
            let point = recognizer.location(in: arView)

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

        private func updateCamera() {
            guard let camera = cameraEntity else { return }
            if parent.startsInside {
                let direction = SIMD3<Float>(
                    cos(pitch) * sin(yaw),
                    sin(pitch),
                    -cos(pitch) * cos(yaw)
                )
                camera.look(at: insideEye + direction, from: insideEye, relativeTo: nil)
            } else {
                let size = parent.geometry.approximateSize
                let target = SIMD3<Float>(0, size.y * 0.25, 0)
                let position = SIMD3<Float>(
                    target.x + radius * cos(pitch) * sin(yaw),
                    target.y + radius * sin(pitch),
                    target.z + radius * cos(pitch) * cos(yaw)
                )
                camera.look(at: target, from: position, relativeTo: nil)
            }
        }
    }
}
