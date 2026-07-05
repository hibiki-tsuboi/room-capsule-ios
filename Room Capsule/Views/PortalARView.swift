import SwiftUI
import RealityKit
import ARKit
import UIKit
import simd

// MARK: - ポータル AR 画面

/// 現実の床に AR のドアを置き、ドアの向こうに保存した部屋が見える
struct PortalARView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    let versionID: UUID?

    @State private var placed = false
    @State private var enterInside = false
    @State private var resetToken = 0
    /// ドアをくぐるときの光のバースト演出
    @State private var portalFlash = false

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var version: RoomScanVersion? {
        capsule?.version(id: versionID) ?? capsule?.latestVersion
    }

    var body: some View {
        ZStack {
            if !ARCapabilities.isARSupported {
                CapsuleBackground()
                ARUnavailableCard(
                    title: "この環境では AR ポータルは開けません",
                    message: "AR 対応端末では、現実の床に置いたドアの向こうに保存した部屋が見えます。代わりに部屋の中の 3D ビューを体験できます。",
                    actionTitle: "部屋の中に入る(3Dビュー)"
                ) {
                    enterInside = true
                }
                closeOverlay
            } else if let capsule, let version {
                PortalARContainer(
                    geometry: version.simplifiedGeometry,
                    pins: capsule.pins(forVersion: version.id),
                    ghosts: capsule.ghosts(forVersion: version.id),
                    usdzURL: version.usdzURL,
                    resetToken: resetToken,
                    onEnter: { enterPortal() },
                    onPlacementChange: { placed = $0 }
                )
                .ignoresSafeArea()

                VStack {
                    HStack(alignment: .top) {
                        Text(placed
                             ? "ドアをタップすると部屋の中に入れます"
                             : "床をタップしてポータルを設置")
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
                }
            } else {
                CapsuleBackground()
                ContentUnavailableView("表示できるバージョンがありません", systemImage: "door.left.hand.open")
                closeOverlay
            }

            // ドアをくぐる瞬間の光のバースト
            if portalFlash {
                RadialGradient(
                    colors: [Color.white, Theme.accentCyan.opacity(0.85), Color.clear],
                    center: .center,
                    startRadius: 20,
                    endRadius: 700
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.25).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .fullScreenCover(isPresented: $enterInside) {
            RoomImmersivePreviewView(
                capsuleID: capsuleID,
                versionID: versionID,
                initialMode: .photo,
                startsInside: true,
                title: "部屋の中"
            )
        }
    }

    /// 光のバースト → 部屋の中ビューへ(中ビュー側は白からフェードイン + ドリーイン)
    private func enterPortal() {
        withAnimation(.easeIn(duration: 0.28)) {
            portalFlash = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            enterInside = true
            // カバー表示後、戻ってきたとき用にバーストを片付けておく
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation(.easeOut(duration: 0.4)) {
                portalFlash = false
            }
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

struct PortalARContainer: UIViewRepresentable {
    var geometry: SimplifiedRoomGeometry
    var pins: [RoomMemoPin]
    var ghosts: [FurnitureGhost]
    var usdzURL: URL? = nil
    var resetToken: Int
    var onEnter: () -> Void
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
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PortalARContainer
        private weak var arView: ARView?
        private var placementAnchor: AnchorEntity?
        private let selection = RoomSelectionManager()
        private var lastResetToken = 0

        init(_ parent: PortalARContainer) {
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
        }

        func handleResetTokenIfNeeded() {
            guard parent.resetToken != lastResetToken else { return }
            lastResetToken = parent.resetToken
            placementAnchor?.removeFromParent()
            placementAnchor = nil
            parent.onPlacementChange(false)
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView else { return }
            let point = recognizer.location(in: arView)

            if placementAnchor == nil {
                place(at: point)
                return
            }

            // ドア(トリガー)のタップ判定
            if let tapped = arView.entity(at: point) {
                var target: Entity? = tapped
                while let current = target {
                    if current.name == "PortalTrigger" {
                        Haptics.medium()
                        parent.onEnter()
                        return
                    }
                    target = current.parent
                }
            }
            _ = selection.handleTap(at: point, in: arView)
        }

        private func place(at point: CGPoint) {
            guard let arView,
                  let result = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
            else { return }

            let anchor = AnchorEntity(world: result.worldTransform)
            arView.scene.addAnchor(anchor)
            placementAnchor = anchor

            // ドアがカメラの方を向くようにする
            let t = result.worldTransform.columns.3
            let cameraPosition = arView.cameraTransform.translation
            let yawToCamera = atan2(cameraPosition.x - t.x, cameraPosition.z - t.z)

            let portal = buildPortal()
            portal.orientation = simd_quatf(angle: yawToCamera, axis: [0, 1, 0])
            anchor.addChild(portal)

            parent.onPlacementChange(true)
            Haptics.success()
        }

        /// ドア枠 + 遮蔽シェル + 部屋モデルのポータル一式を組み立てる
        private func buildPortal() -> Entity {
            let portal = Entity()
            portal.name = "Portal"

            let roomSize = parent.geometry.approximateSize
            let interiorScale: Float = min(0.6, 1.8 / max(roomSize.y, 1.0))
            let width = max(roomSize.x * interiorScale + 0.8, 2.4)
            let depth = max(roomSize.z * interiorScale + 1.2, 2.4)
            let height: Float = 2.3
            let doorWidth: Float = 1.0
            let doorHeight: Float = 2.0

            // --- ドア枠(発光) ---
            let frameColor = UIColor(red: 0.42, green: 0.87, blue: 0.95, alpha: 1)
            let frameMaterial = RoomEntityFactory.material(color: frameColor, opacity: 1, emissive: frameColor)
            let postSize = SIMD3<Float>(0.08, doorHeight + 0.08, 0.08)

            for x in [-doorWidth / 2, doorWidth / 2] {
                let post = ModelEntity(mesh: .generateBox(size: postSize), materials: [frameMaterial])
                post.position = [x, (doorHeight + 0.08) / 2, 0]
                portal.addChild(post)
            }
            let lintel = ModelEntity(
                mesh: .generateBox(size: [doorWidth + 0.16, 0.08, 0.08]),
                materials: [frameMaterial]
            )
            lintel.position = [0, doorHeight + 0.04, 0]
            portal.addChild(lintel)

            let label = RoomEntityFactory.textEntity("ポータル", textHeight: 0.12, color: frameColor)
            label.position = [0, doorHeight + 0.3, 0]
            portal.addChild(label)

            // --- 遮蔽シェル(ドア以外から中が見えないようにする) ---
            let occlusion = OcclusionMaterial()

            func occlusionBox(size: SIMD3<Float>, position: SIMD3<Float>) {
                let box = ModelEntity(mesh: .generateBox(size: size), materials: [occlusion])
                box.position = position
                portal.addChild(box)
            }

            // 奥・左右・天井
            occlusionBox(size: [width, height, 0.02], position: [0, height / 2, -depth])
            occlusionBox(size: [0.02, height, depth], position: [-width / 2, height / 2, -depth / 2])
            occlusionBox(size: [0.02, height, depth], position: [width / 2, height / 2, -depth / 2])
            occlusionBox(size: [width, 0.02, depth], position: [0, height, -depth / 2])
            // 手前(ドアの周囲)
            let sideWidth = (width - doorWidth) / 2
            occlusionBox(size: [width, height - doorHeight, 0.02], position: [0, doorHeight + (height - doorHeight) / 2, 0])
            occlusionBox(size: [sideWidth, doorHeight, 0.02], position: [-(doorWidth / 2 + sideWidth / 2), doorHeight / 2, 0])
            occlusionBox(size: [sideWidth, doorHeight, 0.02], position: [doorWidth / 2 + sideWidth / 2, doorHeight / 2, 0])

            // --- ポータル内部 ---
            let interiorFloor = ModelEntity(
                mesh: .generateBox(size: [width, 0.02, depth]),
                materials: [RoomEntityFactory.material(color: UIColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1), opacity: 1)]
            )
            interiorFloor.position = [0, 0.01, -depth / 2]
            portal.addChild(interiorFloor)

            let interiorLight = PointLight()
            interiorLight.light.intensity = 20_000
            interiorLight.position = [0, height * 0.7, -depth / 2]
            portal.addChild(interiorLight)

            // USDZ があれば実スキャン形状を、なければ写真風の箱モデルを見せる
            let room = RoomEntityFactory.makeRoomEntity(
                geometry: parent.geometry,
                pins: parent.pins,
                ghosts: parent.ghosts,
                mode: parent.usdzURL != nil ? .scanModel : .photo,
                usdzURL: parent.usdzURL
            )
            room.scale = SIMD3<Float>(repeating: interiorScale)
            room.position = [0, 0.02, -depth / 2]
            portal.addChild(room)

            // --- タップトリガー(ドア面) ---
            let trigger = ModelEntity(
                mesh: .generateBox(size: [doorWidth, doorHeight, 0.04]),
                materials: [RoomEntityFactory.material(color: frameColor, opacity: 0.04)]
            )
            trigger.name = "PortalTrigger"
            trigger.position = [0, doorHeight / 2, 0.04]
            trigger.generateCollisionShapes(recursive: false)
            portal.addChild(trigger)

            return portal
        }
    }
}
