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
                    startsInside: startsInside,
                    pinPlacementActive: pinPlacementActive,
                    onSelectPart: { selectedPart = $0 },
                    onPlacePin: { position in
                        pendingPin = PendingPinPlacement(position: position)
                        pinPlacementActive = false
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
                            CloseButton { dismiss() }
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
                    .padding()

                    if pinPlacementActive {
                        Text("部屋のどこかをタップしてメモピンを置く")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassCard(cornerRadius: 12)
                    } else {
                        Text(startsInside ? "ドラッグで見回す・ピンチで前後に移動" : "ドラッグで回転・ピンチで拡大縮小・パーツをタップ")
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

                    ModeChipsBar(selection: $mode)
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
        }
        .sheet(item: $pendingPin) { pending in
            MemoPinEditorView(
                capsuleID: capsuleID,
                versionID: version?.id,
                initialPosition: pending.position
            )
        }
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
    var startsInside: Bool
    var pinPlacementActive: Bool
    var onSelectPart: (RoomPartInfo?) -> Void
    var onPlacePin: (SIMD3<Float>) -> Void

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

        init(_ parent: RoomPreviewARContainer) {
            self.parent = parent
        }

        func attach(to arView: ARView) {
            self.arView = arView

            let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
            arView.scene.addAnchor(anchor)
            worldAnchor = anchor

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 60
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

            setupCameraDefaults()
            refreshContentIfNeeded(force: true)
            updateCamera()
        }

        private func setupCameraDefaults() {
            let size = parent.geometry.approximateSize
            // ドールハウスを少し上から見下ろす引きのカメラ
            baseRadius = max(simd_length(size) * 1.5, 3.5)
            if parent.startsInside {
                insideEye = [0, min(1.5, size.y * 0.6), 0]
                yaw = 0
                pitch = 0
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
            let signature = hasher.finalize()
            guard force || signature != contentSignature else { return }
            contentSignature = signature

            selection.clearSelection()
            roomEntity?.removeFromParent()
            let entity = RoomEntityFactory.makeRoomEntity(
                geometry: parent.geometry,
                pins: parent.pins,
                ghosts: parent.ghosts,
                mode: parent.mode
            )
            worldAnchor?.addChild(entity)
            roomEntity = entity
        }

        // MARK: ジェスチャ

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
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
