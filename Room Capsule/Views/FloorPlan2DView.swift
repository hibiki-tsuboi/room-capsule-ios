import SwiftUI
import simd

// MARK: - 間取り図の描画本体

/// SwiftUI Canvas による 2D 間取り描画。
/// 画面表示(FloorPlan2DView)とサムネイル生成(RoomCapsuleStore)で共用する。
struct FloorPlanCanvas: View {
    let geometry: SimplifiedRoomGeometry
    var pins: [RoomMemoPin] = []
    var ghosts: [FurnitureGhost] = []
    var showDimensions = true
    var showLabels = true

    var body: some View {
        Canvas { context, size in
            // スキャン開始時の端末の向きが座標系に焼き付いているため、
            // 壁が水平・垂直(かつ横長)になるよう回転してから描く
            let uprightYaw = RoomGeometryAlignment.uprightYaw(of: self.geometry)
            let geometry = self.geometry.rotatedAroundY(uprightYaw)
            // 導線を隠している機能のデータは描画にも乗せない(デモ部屋のピン・ゴースト対策)
            let pins: [RoomMemoPin] = !FeatureFlags.memoPins ? [] : self.pins.map { pin in
                var rotated = pin
                rotated.position = RoomGeometryAlignment.rotated(pin.position, by: uprightYaw)
                return rotated
            }
            let ghosts: [FurnitureGhost] = !FeatureFlags.furnitureGhosts ? [] : self.ghosts.map { ghost in
                var rotated = ghost
                rotated.position = RoomGeometryAlignment.rotated(ghost.position, by: uprightYaw)
                rotated.rotationY += uprightYaw
                return rotated
            }
            guard let bounds = geometry.horizontalBounds else { return }
            let padding: CGFloat = 32
            let extent = bounds.max - bounds.min
            let scaleX = (size.width - padding * 2) / CGFloat(max(extent.x, 0.1))
            let scaleY = (size.height - padding * 2) / CGFloat(max(extent.y, 0.1))
            let scale = min(scaleX, scaleY)
            let worldCenter = (bounds.min + bounds.max) / 2

            func point(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(
                    x: size.width / 2 + CGFloat(p.x - worldCenter.x) * scale,
                    y: size.height / 2 + CGFloat(p.y - worldCenter.y) * scale
                )
            }

            func polygonPath(_ corners: [SIMD2<Float>]) -> Path {
                var path = Path()
                guard let first = corners.first else { return path }
                path.move(to: point(first))
                for corner in corners.dropFirst() {
                    path.addLine(to: point(corner))
                }
                path.closeSubpath()
                return path
            }

            // 0.5m グリッド
            let gridSpacing = CGFloat(0.5) * scale
            if gridSpacing > 10 {
                var gridPath = Path()
                var offset: CGFloat = 0
                while size.width / 2 + offset < size.width || size.height / 2 + offset < size.height {
                    for x in [size.width / 2 + offset, size.width / 2 - offset] where x >= 0 && x <= size.width {
                        gridPath.move(to: CGPoint(x: x, y: 0))
                        gridPath.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for y in [size.height / 2 + offset, size.height / 2 - offset] where y >= 0 && y <= size.height {
                        gridPath.move(to: CGPoint(x: 0, y: y))
                        gridPath.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    offset += gridSpacing
                }
                context.stroke(gridPath, with: .color(.white.opacity(0.05)), lineWidth: 1)
            }

            // 床
            if let floor = geometry.floor {
                let corners = RoomGeometryMath.footprintCorners(
                    position: floor.position, rotationY: floor.rotationY, size: floor.size
                )
                context.fill(polygonPath(corners), with: .color(.white.opacity(0.06)))
            }

            // 壁
            for wall in geometry.walls {
                let (a, b) = RoomGeometryMath.wallEndpoints(wall)
                var path = Path()
                path.move(to: point(a))
                path.addLine(to: point(b))
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.9)),
                    style: StrokeStyle(lineWidth: max(CGFloat(wall.size.z) * scale, 3), lineCap: .square)
                )
                if showDimensions, wall.size.x > 0.6 {
                    let mid = (a + b) / 2
                    let fromCenter = mid - worldCenter
                    let outward = simd_length(fromCenter) > 0.01 ? simd_normalize(fromCenter) : SIMD2<Float>(0, -1)
                    let labelPosition = point(mid + outward * 0.32)
                    context.draw(
                        Text(String(format: "%.2f m", wall.size.x))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7)),
                        at: labelPosition
                    )
                }
            }

            // 窓・ドア・開口部(壁の上に重ねる)
            for opening in geometry.openings {
                let pseudoWall = RoomWall(
                    position: opening.position, rotationY: opening.rotationY, size: opening.size
                )
                let (a, b) = RoomGeometryMath.wallEndpoints(pseudoWall)
                var path = Path()
                path.move(to: point(a))
                path.addLine(to: point(b))
                let lineWidth = max(CGFloat(opening.size.z) * scale, 5)
                switch opening.kind {
                case .window:
                    context.stroke(path, with: .color(Theme.accentCyan), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                case .door:
                    context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    // 開き戸の軌跡(4 分の 1 円)
                    let hinge = point(a)
                    let end = point(b)
                    let doorAngle = atan2(end.y - hinge.y, end.x - hinge.x)
                    var arc = Path()
                    arc.addArc(
                        center: hinge,
                        radius: CGFloat(opening.size.x) * scale,
                        startAngle: .radians(Double(doorAngle)),
                        endAngle: .radians(Double(doorAngle) + Double.pi / 2),
                        clockwise: false
                    )
                    context.stroke(arc, with: .color(.orange.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                case .opening:
                    context.stroke(path, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: lineWidth, dash: [6, 4]))
                }
            }

            // 家具
            for furniture in geometry.furniture {
                let corners = RoomGeometryMath.footprintCorners(
                    position: furniture.position, rotationY: furniture.rotationY, size: furniture.size
                )
                let path = polygonPath(corners)
                context.fill(path, with: .color(Color(uiColor: furniture.category.uiColor).opacity(0.35)))
                context.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
                if showLabels {
                    context.draw(
                        Text(furniture.category.displayName)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9)),
                        at: point(SIMD2<Float>(furniture.position.x, furniture.position.z))
                    )
                }
            }

            // 家具ゴースト(破線)
            for ghost in ghosts {
                let corners = RoomGeometryMath.footprintCorners(
                    position: ghost.position, rotationY: ghost.rotationY, size: ghost.size
                )
                let path = polygonPath(corners)
                let color = Color(uiColor: ghost.type.uiColor)
                context.fill(path, with: .color(color.opacity(0.15)))
                context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                if showLabels {
                    context.draw(
                        Text(ghost.name.isEmpty ? ghost.type.displayName : ghost.name)
                            .font(.caption2)
                            .foregroundStyle(color),
                        at: point(SIMD2<Float>(ghost.position.x, ghost.position.z))
                    )
                }
            }

            // メモピン
            for pin in pins {
                let center = point(SIMD2<Float>(pin.position.x, pin.position.z))
                let dot = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(pin.category.color))
                context.stroke(dot, with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - 間取り図画面

struct FloorPlan2DView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    let versionID: UUID?

    @State private var steadyZoom: CGFloat = 1
    @GestureState private var pinchZoom: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var version: RoomScanVersion? {
        capsule?.version(id: versionID) ?? capsule?.latestVersion
    }

    var body: some View {
        ZStack {
            CapsuleBackground()

            if let capsule, let version {
                FloorPlanCanvas(
                    geometry: version.simplifiedGeometry,
                    pins: capsule.pins(forVersion: version.id),
                    ghosts: capsule.ghosts(forVersion: version.id)
                )
                .scaleEffect(steadyZoom * pinchZoom)
                .offset(
                    x: steadyOffset.width + dragOffset.width,
                    y: steadyOffset.height + dragOffset.height
                )
                .gesture(
                    MagnificationGesture()
                        .updating($pinchZoom) { value, state, _ in state = value }
                        .onEnded { value in
                            steadyZoom = min(max(steadyZoom * value, 0.5), 6)
                        }
                        .simultaneously(
                            with: DragGesture()
                                .updating($dragOffset) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    steadyOffset.width += value.translation.width
                                    steadyOffset.height += value.translation.height
                                }
                        )
                )

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("図面で見る")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("\(capsule.name)・\(version.name)")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 14)
                        Spacer()
                        CloseButton { dismiss() }
                    }
                    .padding()
                    Spacer()
                    legend
                        .padding()
                }
            } else {
                ContentUnavailableView("表示できる間取りがありません", systemImage: "square.grid.3x3")
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: .white, label: "壁")
            legendItem(color: Theme.accentCyan, label: "窓")
            legendItem(color: .orange, label: "ドア")
            legendItem(color: Color(uiColor: FurnitureCategory.bed.uiColor), label: "家具")
            if FeatureFlags.memoPins {
                legendItem(color: Theme.accentPurple, label: "メモ")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.75))
        }
    }
}
