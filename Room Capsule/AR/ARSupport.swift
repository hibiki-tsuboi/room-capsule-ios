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
