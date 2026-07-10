import SwiftUI
import Combine
import RealityKit
import UIKit
import simd

// MARK: - Before / After タイムライン比較

/// 同じ部屋の 2 つのバージョンをスライダーでクロスフェード比較する
struct TimelineComparisonView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID

    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var progress: Float = 0
    @State private var isPlaying = false
    @State private var playDirection: Float = 1
    private let playTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var sortedVersions: [RoomScanVersion] {
        capsule?.versions.sorted { $0.capturedAt < $1.capturedAt } ?? []
    }
    private var beforeVersion: RoomScanVersion? {
        capsule?.version(id: beforeID) ?? sortedVersions.first
    }
    private var afterVersion: RoomScanVersion? {
        capsule?.version(id: afterID) ?? sortedVersions.last
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let capsule, sortedVersions.count >= 2,
               let before = beforeVersion, let after = afterVersion {
                TimelineARContainer(
                    beforeGeometry: before.simplifiedGeometry,
                    beforePins: capsule.pins(forVersion: before.id),
                    beforeGhosts: capsule.ghosts(forVersion: before.id),
                    afterGeometry: after.simplifiedGeometry,
                    afterPins: capsule.pins(forVersion: after.id),
                    afterGhosts: capsule.ghosts(forVersion: after.id),
                    progress: progress
                )
                .ignoresSafeArea()

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("時間を比べる")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(capsule.name)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 14)
                        Spacer()
                        CloseButton { dismiss() }
                    }
                    .padding()

                    HStack(spacing: 10) {
                        versionPicker(title: "Before", selection: $beforeID, current: before)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(Color.white.opacity(0.5))
                        versionPicker(title: "After", selection: $afterID, current: after)
                    }
                    .padding(.horizontal)

                    Spacer()

                    VStack(spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(before.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(progress < 0.5 ? Theme.accentCyan : Color.white.opacity(0.6))
                                Text(before.capturedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.45))
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(after.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(progress >= 0.5 ? Theme.accentCyan : Color.white.opacity(0.6))
                                Text(after.capturedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.45))
                            }
                        }
                        HStack(spacing: 12) {
                            Button {
                                isPlaying.toggle()
                                Haptics.light()
                            } label: {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.headline)
                                    .foregroundStyle(.black)
                                    .padding(10)
                                    .background(Theme.accentGradient, in: Circle())
                            }
                            Slider(
                                value: $progress,
                                in: 0...1,
                                onEditingChanged: { editing in
                                    if editing {
                                        isPlaying = false
                                    }
                                }
                            )
                            .tint(Theme.accentCyan)
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 18)
                    .padding()
                }
            } else {
                CapsuleBackground()
                VStack(spacing: 14) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.accentGradient)
                    Text("比較には 2 つ以上のバージョンが必要です")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("部屋詳細の「バージョンを追加」から、同じ部屋をもう一度スキャンしてみてください。")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }
                .padding(26)
                .glassCard(cornerRadius: 24)
                .padding()
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
        .onReceive(playTimer) { _ in
            guard isPlaying else { return }
            // 約 3 秒で片道、端で折り返すピンポン再生
            var next = progress + playDirection / 90
            if next >= 1 {
                next = 1
                playDirection = -1
            } else if next <= 0 {
                next = 0
                playDirection = 1
            }
            progress = next
        }
    }

    private func versionPicker(title: String, selection: Binding<UUID?>, current: RoomScanVersion) -> some View {
        Menu {
            ForEach(sortedVersions) { version in
                Button {
                    selection.wrappedValue = version.id
                } label: {
                    Label(
                        "\(version.name)(\(version.capturedAt.formatted(date: .abbreviated, time: .omitted)))",
                        systemImage: version.id == current.id ? "checkmark" : "clock"
                    )
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
                HStack(spacing: 4) {
                    Text(current.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 12)
        }
    }
}

// MARK: - クロスフェード表示コンテナ(非 AR)

struct TimelineARContainer: UIViewRepresentable {
    var beforeGeometry: SimplifiedRoomGeometry
    var beforePins: [RoomMemoPin]
    var beforeGhosts: [FurnitureGhost]
    var afterGeometry: SimplifiedRoomGeometry
    var afterPins: [RoomMemoPin]
    var afterGhosts: [FurnitureGhost]
    var progress: Float

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
        context.coordinator.applyProgressIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimelineARContainer
        private weak var arView: ARView?
        private var worldAnchor: AnchorEntity?
        private var beforeEntity: Entity?
        private var afterEntity: Entity?
        private var cameraEntity: PerspectiveCamera?
        private var contentSignature: Int?
        private var lastProgress: Float = -1

        private var yaw: Float = -0.7
        private var pitch: Float = 0.35
        private var radius: Float = 5
        private var baseRadius: Float = 5

        init(_ parent: TimelineARContainer) {
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

            let keyLight = DirectionalLight()
            keyLight.light.intensity = 3200
            keyLight.look(at: [0, 0, 0], from: [2.5, 4.5, 3], relativeTo: nil)
            anchor.addChild(keyLight)

            let fillLight = DirectionalLight()
            fillLight.light.intensity = 1400
            fillLight.look(at: [0, 0, 0], from: [-3, 2.5, -2], relativeTo: nil)
            anchor.addChild(fillLight)

            arView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
            arView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))

            baseRadius = max(simd_length(parent.beforeGeometry.approximateSize) * 1.5, 3.5)
            radius = baseRadius
            pitch = 0.62
            refreshContentIfNeeded(force: true)
            updateCamera()
        }

        func refreshContentIfNeeded(force: Bool = false) {
            var hasher = Hasher()
            hasher.combine(parent.beforeGeometry)
            hasher.combine(parent.beforePins)
            hasher.combine(parent.beforeGhosts)
            hasher.combine(parent.afterGeometry)
            hasher.combine(parent.afterPins)
            hasher.combine(parent.afterGhosts)
            let signature = hasher.finalize()
            guard force || signature != contentSignature else { return }
            contentSignature = signature

            beforeEntity?.removeFromParent()
            afterEntity?.removeFromParent()

            let before = RoomEntityFactory.makeRoomEntity(
                geometry: parent.beforeGeometry,
                pins: parent.beforePins,
                ghosts: parent.beforeGhosts,
                mode: .memo
            )
            let after = RoomEntityFactory.makeRoomEntity(
                geometry: parent.afterGeometry,
                pins: parent.afterPins,
                ghosts: parent.afterGhosts,
                mode: .memo
            )
            // 別スキャン(=別の AR セッション座標)由来の向きの違いを吸収して before に重ねる。
            // 平行移動は各エンティティが外接矩形中心でセンタリング済みなので回転だけでよい
            after.orientation = simd_quatf(
                angle: RoomGeometryAlignment.alignmentYaw(of: parent.afterGeometry, to: parent.beforeGeometry),
                axis: [0, 1, 0]
            )
            worldAnchor?.addChild(before)
            worldAnchor?.addChild(after)
            beforeEntity = before
            afterEntity = after
            lastProgress = -1
            applyProgressIfNeeded()
        }

        func applyProgressIfNeeded() {
            guard parent.progress != lastProgress,
                  let beforeEntity, let afterEntity else { return }
            lastProgress = parent.progress
            RoomEntityFactory.applyGlobalOpacity(1 - parent.progress, to: beforeEntity)
            RoomEntityFactory.applyGlobalOpacity(parent.progress, to: afterEntity)
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            yaw -= Float(translation.x) * 0.008
            pitch = min(max(pitch + Float(translation.y) * 0.006, -0.15), 1.45)
            updateCamera()
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            let scale = Float(recognizer.scale)
            recognizer.scale = 1
            radius = min(max(radius / scale, baseRadius * 0.25), baseRadius * 3)
            updateCamera()
        }

        private func updateCamera() {
            guard let camera = cameraEntity else { return }
            let size = parent.beforeGeometry.approximateSize
            let target = SIMD3<Float>(0, size.y * 0.35, 0)
            let position = SIMD3<Float>(
                target.x + radius * cos(pitch) * sin(yaw),
                target.y + radius * sin(pitch),
                target.z + radius * cos(pitch) * cos(yaw)
            )
            camera.look(at: target, from: position, relativeTo: nil)
        }
    }
}
