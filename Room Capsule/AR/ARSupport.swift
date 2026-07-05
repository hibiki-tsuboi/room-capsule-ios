import Foundation
import ARKit
import RealityKit
import UIKit
#if canImport(RoomPlan)
import RoomPlan
#endif

// MARK: - 端末サポート判定

enum ARCapabilities {
    /// ワールドトラッキング AR が使えるか(シミュレータでは false)
    static var isARSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// RoomPlan スキャンが使えるか(LiDAR 搭載機 + iOS 16 以降)
    static var isRoomPlanSupported: Bool {
        #if canImport(RoomPlan)
        return RoomCaptureSession.isSupported
        #else
        return false
        #endif
    }
}

// MARK: - ハプティクス

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - 家具ゴーストのドラッグ移動

/// AR / 3D プレビューでゴースト家具を指で掴んで動かすための共通処理
@MainActor
enum GhostDragHelper {

    /// 指の位置の下にある家具ゴーストのエンティティを探す
    static func ghostEntity(at point: CGPoint, in arView: ARView) -> (entity: ModelEntity, ghostID: UUID)? {
        guard let tapped = arView.entity(at: point) else { return nil }
        var target: Entity? = tapped
        while let current = target {
            if let part = current.components[RoomPartComponent.self],
               case .furnitureGhost(let ghost) = part.info.kind,
               let model = current as? ModelEntity {
                return (model, ghost.id)
            }
            target = current.parent
        }
        return nil
    }

    /// Y 軸回転のみのエンティティからヨー角を取り出す(ゴーストの回転保存用)
    static func yaw(of entity: Entity) -> Float {
        let q = entity.orientation
        return 2 * atan2(q.imag.y, q.real)
    }

    /// ドラッグ先のルーム座標を計算してゴーストを動かす(高さは維持、部屋の外へは出しすぎない)
    static func updateDragPosition(
        point: CGPoint,
        arView: ARView,
        dragging: (entity: ModelEntity, ghostID: UUID),
        roomEntity: Entity?,
        geometry: SimplifiedRoomGeometry
    ) {
        guard let content = roomEntity?.findEntity(named: "RoomContent"),
              let target = dragTarget(point: point, arView: arView, ghostEntity: dragging.entity, content: content)
        else { return }
        var x = target.x
        var z = target.z
        if let bounds = geometry.horizontalBounds {
            x = min(max(x, bounds.min.x - 0.5), bounds.max.x + 0.5)
            z = min(max(z, bounds.min.y - 0.5), bounds.max.y + 0.5)
        }
        dragging.entity.position = [x, dragging.entity.position.y, z]
    }

    /// 指のレイと「ゴーストの現在の高さの水平面」の交点をルーム座標で返す。
    /// レイが取れない場合はコリジョン hitTest(自分自身は除外)へフォールバック。
    private static func dragTarget(
        point: CGPoint,
        arView: ARView,
        ghostEntity: Entity,
        content: Entity
    ) -> SIMD3<Float>? {
        let ghostWorld = ghostEntity.convert(position: .zero, to: nil)
        if let ray = arView.ray(through: point) {
            let denom = ray.direction.y
            if abs(denom) > 1e-4 {
                let t = (ghostWorld.y - ray.origin.y) / denom
                if t > 0 {
                    return content.convert(position: ray.origin + ray.direction * t, from: nil)
                }
            }
        }
        for hit in arView.hitTest(point) {
            var node: Entity? = hit.entity
            var isDraggedGhost = false
            while let current = node {
                if current === ghostEntity {
                    isDraggedGhost = true
                    break
                }
                node = current.parent
            }
            if !isDraggedGhost {
                return content.convert(position: hit.position, from: nil)
            }
        }
        return nil
    }
}

// MARK: - タップ選択

/// タップ選択とハイライトの共通処理(全 AR / プレビュー画面で共用)
@MainActor
final class RoomSelectionManager {
    private weak var selectedEntity: ModelEntity?

    /// タップ位置のパーツを探して選択状態を切り替える。
    /// 戻り値: 新しく選択されたパーツ情報(選択解除なら nil)
    func handleTap(at point: CGPoint, in arView: ARView) -> RoomPartInfo? {
        guard let tapped = arView.entity(at: point) else {
            clearSelection()
            return nil
        }
        // RoomPartComponent を持つ祖先を探す
        var target: Entity? = tapped
        while let current = target, current.components[RoomPartComponent.self] == nil {
            target = current.parent
        }
        guard let entity = target as? ModelEntity,
              let part = entity.components[RoomPartComponent.self] else {
            clearSelection()
            return nil
        }
        if entity === selectedEntity {
            clearSelection()
            return nil
        }
        clearSelection()
        selectedEntity = entity
        let baseOpacity = entity.components[BaseAppearanceComponent.self]?.opacity ?? 1
        entity.model?.materials = [
            RoomEntityFactory.material(
                color: UIColor.systemYellow,
                opacity: max(baseOpacity, 0.85),
                emissive: UIColor.systemYellow
            )
        ]
        Haptics.light()
        return part.info
    }

    func clearSelection() {
        if let entity = selectedEntity,
           let base = entity.components[BaseAppearanceComponent.self] {
            entity.model?.materials = [
                RoomEntityFactory.material(color: base.color, opacity: base.opacity, emissive: base.emissiveColor)
            ]
        }
        selectedEntity = nil
    }
}
