import Foundation
import RealityKit
import UIKit
import simd

// MARK: - 表示モード

enum RoomDisplayMode: String, CaseIterable, Identifiable {
    case model          // 白いドールハウス
    case scanModel      // RoomPlan の USDZ をそのまま表示(高品質)
    case dimensions     // 寸法ラベル付き
    case xray           // 壁を半透明にして中が見える
    case furnitureOnly  // 家具・設備だけ
    case structureOnly  // 壁・床・窓・ドアだけ
    case memo           // メモピンを浮かせる
    case photo          // 写真っぽい配色(Splat の代替)
    case wireframe      // ワイヤーフレーム風

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .model: return "模型"
        case .scanModel: return "高品質"
        case .dimensions: return "寸法"
        case .xray: return "X線"
        case .furnitureOnly: return "家具だけ"
        case .structureOnly: return "構造だけ"
        case .memo: return "メモ"
        case .photo: return "写真"
        case .wireframe: return "線画"
        }
    }

    var symbolName: String {
        switch self {
        case .model: return "cube.fill"
        case .scanModel: return "shippingbox.fill"
        case .dimensions: return "ruler"
        case .xray: return "cube.transparent"
        case .furnitureOnly: return "sofa.fill"
        case .structureOnly: return "building.2"
        case .memo: return "mappin.circle.fill"
        case .photo: return "sparkles"
        case .wireframe: return "scribble.variable"
        }
    }

    /// USDZ の有無に応じて選択できるモード一覧
    static func availableModes(hasUSDZ: Bool) -> [RoomDisplayMode] {
        hasUSDZ ? allCases : allCases.filter { $0 != .scanModel }
    }
}

// MARK: - USDZ モデルキャッシュ

/// RoomPlan がエクスポートした USDZ の読み込みキャッシュ。
/// Entity は同時に 1 箇所にしか置けないため、利用側には clone を返す。
@MainActor
enum USDZModelCache {
    private static var cache: [URL: Entity] = [:]

    static func cloneEntity(for url: URL) -> Entity? {
        if let cached = cache[url] {
            return cached.clone(recursive: true)
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let entity = try? Entity.load(contentsOf: url) else {
            return nil
        }
        // タップ判定・ピン配置の hitTest 用にコリジョンを付けておく
        entity.generateCollisionShapes(recursive: true)
        cache[url] = entity
        return entity.clone(recursive: true)
    }
}

// MARK: - パーツ情報(タップ選択・インスペクタ表示用)

struct RoomPartInfo {
    enum Kind {
        case wall
        case floor
        case opening(RoomOpening.Kind)
        case furniture(FurnitureCategory)
        case memoPin(RoomMemoPin)
        case furnitureGhost(FurnitureGhost)
    }

    let id: UUID
    let kind: Kind
    let name: String
    let size: SIMD3<Float>
    var subtitle: String?

    var symbolName: String {
        switch kind {
        case .wall: return "rectangle.portrait.fill"
        case .floor: return "square.fill"
        case .opening(let kind): return kind.symbolName
        case .furniture(let category): return category.symbolName
        case .memoPin(let pin): return pin.category.symbolName
        case .furnitureGhost(let ghost): return ghost.type.symbolName
        }
    }

    var sizeText: String {
        String(format: "幅 %.2fm × 高さ %.2fm × 奥行 %.2fm", size.x, size.y, size.z)
    }
}

// MARK: - RealityKit コンポーネント

/// タップ選択時にパーツ情報を引くためのコンポーネント
struct RoomPartComponent: Component {
    let info: RoomPartInfo
}

/// 素材の元の見た目。透明度スライダーや選択解除時の復元に使う
struct BaseAppearanceComponent: Component {
    var color: UIColor
    var opacity: Float
    var emissiveColor: UIColor?
}

// MARK: - エンティティファクトリ

/// SimplifiedRoomGeometry から RealityKit エンティティを組み立てる。
/// AR(ミニチュア / 実寸 / ポータル)と非 AR プレビューの全画面で共用する。
@MainActor
enum RoomEntityFactory {

    static func registerComponents() {
        RoomPartComponent.registerComponent()
        BaseAppearanceComponent.registerComponent()
    }

    // MARK: 部屋全体

    /// 部屋全体のエンティティを生成する。
    /// ルート直下の "RoomContent" ノードがスキャン座標系を保持し、
    /// 床の中央がルート原点に来るようオフセットされている。
    static func makeRoomEntity(
        geometry: SimplifiedRoomGeometry,
        pins: [RoomMemoPin] = [],
        ghosts: [FurnitureGhost] = [],
        mode: RoomDisplayMode = .model,
        usdzURL: URL? = nil
    ) -> Entity {
        let root = Entity()
        root.name = "RoomRoot"
        let content = Entity()
        content.name = "RoomContent"
        let center = geometry.horizontalCenter
        content.position = [-center.x, -geometry.floorY, -center.y]
        root.addChild(content)

        // 高品質モード: RoomPlan の USDZ をそのまま表示。
        // USDZ はスキャン時と同じ座標系なので、簡易ジオメトリと同じオフセットで揃う。
        // 読めない場合は模型(箱)へフォールバック。
        var effectiveMode = mode
        if mode == .scanModel {
            if let usdzURL, let usdzEntity = USDZModelCache.cloneEntity(for: usdzURL) {
                usdzEntity.name = "USDZModel"
                content.addChild(usdzEntity)
                for ghost in ghosts {
                    content.addChild(ghostEntity(ghost, withLabel: false))
                }
                return root
            }
            effectiveMode = .model
        }

        let style = ModeStyle(mode: effectiveMode)

        if style.showsFloor, let floor = geometry.floor {
            let info = RoomPartInfo(id: UUID(), kind: .floor, name: "床", size: floor.size, subtitle: nil)
            content.addChild(
                boxPart(
                    size: floor.size, position: floor.position, rotationY: floor.rotationY,
                    color: style.floorColor, opacity: style.floorOpacity, emissive: nil,
                    info: info, wireframe: style.wireframe
                )
            )
        }

        if style.showsWalls {
            for wall in geometry.walls {
                let info = RoomPartInfo(id: wall.id, kind: .wall, name: "壁", size: wall.size, subtitle: nil)
                content.addChild(
                    boxPart(
                        size: wall.size, position: wall.position, rotationY: wall.rotationY,
                        color: style.wallColor, opacity: style.wallOpacity, emissive: nil,
                        info: info, wireframe: style.wireframe
                    )
                )
                if style.showsLabels, wall.size.x > 0.6 {
                    let label = textEntity(String(format: "%.2fm", wall.size.x), textHeight: 0.13, color: .white)
                    label.position = wall.position + SIMD3<Float>(0, wall.size.y / 2 + 0.15, 0)
                    label.orientation = simd_quatf(angle: wall.rotationY, axis: [0, 1, 0])
                    content.addChild(label)
                }
            }
        }

        if style.showsOpenings {
            for opening in geometry.openings {
                let (color, emissive) = openingAppearance(opening.kind, photo: style.usesPhotoPalette)
                let info = RoomPartInfo(
                    id: opening.id, kind: .opening(opening.kind),
                    name: opening.kind.displayName, size: opening.size, subtitle: nil
                )
                content.addChild(
                    boxPart(
                        size: opening.size, position: opening.position, rotationY: opening.rotationY,
                        color: color, opacity: style.openingOpacity, emissive: emissive,
                        info: info, wireframe: style.wireframe
                    )
                )
            }
        }

        if style.showsFurniture {
            for furniture in geometry.furniture {
                let color = style.usesPhotoPalette
                    ? furniture.category.uiColor
                    : (style.furnitureColorOverride ?? furniture.category.uiColor)
                let info = RoomPartInfo(
                    id: furniture.id, kind: .furniture(furniture.category),
                    name: furniture.category.displayName, size: furniture.size, subtitle: nil
                )
                content.addChild(
                    boxPart(
                        size: furniture.size, position: furniture.position, rotationY: furniture.rotationY,
                        color: color, opacity: style.furnitureOpacity, emissive: nil,
                        info: info, wireframe: style.wireframe, cornerRadius: 0.02
                    )
                )
                if style.showsLabels {
                    let text = String(format: "%@ %.1f×%.1fm", furniture.category.displayName, furniture.size.x, furniture.size.z)
                    let label = textEntity(text, textHeight: 0.09, color: .white)
                    label.position = furniture.position + SIMD3<Float>(0, furniture.size.y / 2 + 0.12, 0)
                    label.orientation = simd_quatf(angle: furniture.rotationY, axis: [0, 1, 0])
                    content.addChild(label)
                }
            }
        }

        if style.showsPins {
            for pin in pins {
                content.addChild(pinEntity(pin, withLabel: style.showsPinLabels))
            }
        }

        if style.showsGhosts {
            for ghost in ghosts {
                content.addChild(ghostEntity(ghost, withLabel: style.showsLabels))
            }
        }

        return root
    }

    // MARK: モード別スタイル

    private struct ModeStyle {
        var showsWalls = true
        var showsFloor = true
        var showsOpenings = true
        var showsFurniture = true
        var showsPins = false
        var showsPinLabels = false
        var showsGhosts = true
        var showsLabels = false
        var wireframe = false
        var usesPhotoPalette = false
        var wallColor = UIColor(white: 0.98, alpha: 1)
        var wallOpacity: Float = 0.95
        var floorColor = UIColor(white: 0.82, alpha: 1)
        var floorOpacity: Float = 1.0
        var furnitureColorOverride: UIColor? = UIColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 1)
        var furnitureOpacity: Float = 0.95
        var openingOpacity: Float = 0.9

        init(mode: RoomDisplayMode) {
            switch mode {
            case .model, .scanModel: // .scanModel は USDZ が読めなかった場合のフォールバック
                break
            case .dimensions:
                showsLabels = true
            case .xray:
                wallOpacity = 0.22
                floorOpacity = 0.35
                openingOpacity = 0.4
            case .furnitureOnly:
                showsWalls = false
                showsOpenings = false
                floorOpacity = 0.15
            case .structureOnly:
                showsFurniture = false
                showsGhosts = false
            case .memo:
                showsPins = true
                showsPinLabels = true
                wallOpacity = 0.28
                floorOpacity = 0.4
                openingOpacity = 0.3
                furnitureOpacity = 0.3
            case .photo:
                usesPhotoPalette = true
                wallColor = UIColor(red: 0.97, green: 0.93, blue: 0.85, alpha: 1)
                floorColor = UIColor(red: 0.62, green: 0.45, blue: 0.30, alpha: 1)
                furnitureColorOverride = nil
                showsPins = false
            case .wireframe:
                wireframe = true
            }
        }
    }

    private static func openingAppearance(_ kind: RoomOpening.Kind, photo: Bool) -> (UIColor, UIColor?) {
        switch kind {
        case .window:
            let color = UIColor(red: 0.45, green: 0.82, blue: 0.95, alpha: 1)
            return (color, photo ? color : nil)
        case .door:
            return (UIColor(red: 0.85, green: 0.6, blue: 0.35, alpha: 1), nil)
        case .opening:
            return (UIColor(white: 0.6, alpha: 1), nil)
        }
    }

    // MARK: パーツ生成

    /// 箱型パーツを生成する(壁・床・家具・窓・ドアすべての基本形)
    static func boxPart(
        size: SIMD3<Float>,
        position: SIMD3<Float>,
        rotationY: Float,
        color: UIColor,
        opacity: Float,
        emissive: UIColor?,
        info: RoomPartInfo,
        wireframe: Bool = false,
        cornerRadius: Float = 0
    ) -> ModelEntity {
        let effectiveOpacity = wireframe ? min(opacity, 0.08) : opacity
        let mesh = MeshResource.generateBox(size: size, cornerRadius: cornerRadius)
        let entity = ModelEntity(
            mesh: mesh,
            materials: [material(color: color, opacity: effectiveOpacity, emissive: emissive)]
        )
        entity.position = position
        entity.orientation = simd_quatf(angle: rotationY, axis: [0, 1, 0])
        entity.components.set(RoomPartComponent(info: info))
        entity.components.set(BaseAppearanceComponent(color: color, opacity: effectiveOpacity, emissiveColor: emissive))
        entity.generateCollisionShapes(recursive: false)
        if wireframe {
            entity.addChild(edgesEntity(size: size, color: UIColor(red: 0.5, green: 0.9, blue: 1.0, alpha: 1)))
        }
        return entity
    }

    /// メモピン(光る球 + ハロー + ラベル)
    static func pinEntity(_ pin: RoomMemoPin, withLabel: Bool) -> Entity {
        let parent = Entity()
        parent.name = "MemoPin-\(pin.id.uuidString)"
        parent.position = pin.position
        let color = pin.category.uiColor
        let info = RoomPartInfo(
            id: pin.id, kind: .memoPin(pin),
            name: pin.title.isEmpty ? pin.category.displayName : pin.title,
            size: .zero,
            subtitle: pin.category.displayName
        )

        let core = ModelEntity(
            mesh: .generateSphere(radius: 0.05),
            materials: [material(color: color, opacity: 1, emissive: color)]
        )
        core.components.set(RoomPartComponent(info: info))
        core.components.set(BaseAppearanceComponent(color: color, opacity: 1, emissiveColor: color))
        core.generateCollisionShapes(recursive: false)
        parent.addChild(core)

        let halo = ModelEntity(
            mesh: .generateSphere(radius: 0.09),
            materials: [material(color: color, opacity: 0.22, emissive: color)]
        )
        halo.components.set(BaseAppearanceComponent(color: color, opacity: 0.22, emissiveColor: color))
        parent.addChild(halo)

        if withLabel, !info.name.isEmpty {
            let label = textEntity(info.name, textHeight: 0.07, color: .white)
            label.position = [0, 0.15, 0]
            parent.addChild(label)
        }
        return parent
    }

    /// 家具ゴースト(淡く光る半透明の箱 + 発光エッジ)
    static func ghostEntity(_ ghost: FurnitureGhost, withLabel: Bool) -> Entity {
        let color = ghost.type.uiColor
        let name = ghost.name.isEmpty ? ghost.type.displayName : ghost.name
        let info = RoomPartInfo(
            id: ghost.id, kind: .furnitureGhost(ghost),
            name: name, size: ghost.size,
            subtitle: "家具ゴースト(\(ghost.type.displayName))"
        )
        let entity = boxPart(
            size: ghost.size, position: ghost.position, rotationY: ghost.rotationY,
            color: color, opacity: 0.38, emissive: color,
            info: info, cornerRadius: 0.02
        )
        entity.name = "Ghost-\(ghost.id.uuidString)"
        entity.addChild(edgesEntity(size: ghost.size, thickness: 0.012, color: color))
        if withLabel {
            let text = String(format: "%@ %.1f×%.1fm", name, ghost.size.x, ghost.size.z)
            let label = textEntity(text, textHeight: 0.08, color: .white)
            label.position = [0, ghost.size.y / 2 + 0.12, 0]
            entity.addChild(label)
        }
        return entity
    }

    /// ワイヤーフレーム風表示用の 12 本のエッジ
    static func edgesEntity(size: SIMD3<Float>, thickness: Float = 0.015, color: UIColor) -> Entity {
        let parent = Entity()
        let hx = size.x / 2
        let hy = size.y / 2
        let hz = size.z / 2
        let edgeMaterial = material(color: color, opacity: 0.9, emissive: color)

        func addEdge(size edgeSize: SIMD3<Float>, position: SIMD3<Float>) {
            let edge = ModelEntity(mesh: .generateBox(size: edgeSize), materials: [edgeMaterial])
            edge.position = position
            edge.components.set(BaseAppearanceComponent(color: color, opacity: 0.9, emissiveColor: color))
            parent.addChild(edge)
        }

        for y in [-hy, hy] {
            for z in [-hz, hz] {
                addEdge(size: [size.x + thickness, thickness, thickness], position: [0, y, z])
            }
        }
        for x in [-hx, hx] {
            for z in [-hz, hz] {
                addEdge(size: [thickness, size.y + thickness, thickness], position: [x, 0, z])
            }
        }
        for x in [-hx, hx] {
            for y in [-hy, hy] {
                addEdge(size: [thickness, thickness, size.z + thickness], position: [x, y, 0])
            }
        }
        return parent
    }

    /// センタリング済みの 3D テキスト
    static func textEntity(_ string: String, textHeight: Float, color: UIColor) -> Entity {
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: textHeight * 0.04,
            font: .systemFont(ofSize: CGFloat(textHeight), weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let model = ModelEntity(mesh: mesh, materials: [material(color: color, opacity: 1, emissive: color)])
        model.components.set(BaseAppearanceComponent(color: color, opacity: 1, emissiveColor: color))
        let bounds = mesh.bounds
        model.position = [-bounds.center.x, -bounds.center.y, 0]
        let holder = Entity()
        holder.addChild(model)
        return holder
    }

    // MARK: マテリアル

    static func material(color: UIColor, opacity: Float, emissive: UIColor? = nil) -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: 0.65)
        m.metallic = .init(floatLiteral: 0.0)
        if opacity < 0.999 {
            m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        if let emissive {
            m.emissiveColor = .init(color: emissive)
            m.emissiveIntensity = 1.6
        }
        return m
    }

    // MARK: 全体操作

    /// 実寸 AR の透明度スライダーや Before/After クロスフェード用に
    /// ツリー全体の透明度係数を変える
    static func applyGlobalOpacity(_ factor: Float, to root: Entity) {
        // USDZ モデルはマテリアル再構築の対象外なので OpacityComponent で丸ごと制御する
        if let usdzModel = root.findEntity(named: "USDZModel") {
            usdzModel.components.set(OpacityComponent(opacity: factor))
        }
        forEachEntity(root) { entity in
            guard let base = entity.components[BaseAppearanceComponent.self],
                  let model = entity as? ModelEntity else { return }
            let opacity = base.opacity * factor
            entity.isEnabled = opacity > 0.02
            guard entity.isEnabled else { return }
            model.model?.materials = [material(color: base.color, opacity: opacity, emissive: base.emissiveColor)]
        }
    }

    static func forEachEntity(_ entity: Entity, _ body: (Entity) -> Void) {
        body(entity)
        for child in entity.children {
            forEachEntity(child, body)
        }
    }
}
