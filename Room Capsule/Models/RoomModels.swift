import Foundation
import SwiftUI
import UIKit
import simd

// MARK: - 部屋カプセル(1 部屋ぶんの保存データ一式)

/// 1 つの部屋 = 複数のスキャンバージョン + メモピン + 家具ゴースト
struct RoomCapsule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var versions: [RoomScanVersion] = []
    var memoPins: [RoomMemoPin] = []
    var furnitureGhosts: [FurnitureGhost] = []

    /// 最新(撮影日時が最も新しい)バージョン
    var latestVersion: RoomScanVersion? {
        versions.max { $0.capturedAt < $1.capturedAt }
    }

    var hasSplat: Bool { versions.contains { $0.splatAsset != nil } }

    func version(id: UUID?) -> RoomScanVersion? {
        guard let id else { return nil }
        return versions.first { $0.id == id }
    }

    /// 指定バージョンで表示すべきメモピン(versionID == nil は全バージョン共通)
    func pins(forVersion versionID: UUID?) -> [RoomMemoPin] {
        memoPins.filter { $0.versionID == nil || $0.versionID == versionID }
    }

    func ghosts(forVersion versionID: UUID?) -> [FurnitureGhost] {
        furnitureGhosts.filter { $0.versionID == nil || $0.versionID == versionID }
    }
}

// MARK: - スキャンバージョン(同じ部屋の時間違いスナップショット)

struct RoomScanVersion: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var capturedAt: Date = Date()
    var isDemo: Bool = false
    /// RoomPlan の CapturedRoom を JSON エンコードしたファイル(相対パス)
    var roomDataPath: String?
    /// RoomPlan からエクスポートした USDZ(相対パス)
    var usdzPath: String?
    /// 一覧カード用サムネイル PNG(相対パス)
    var thumbnailPath: String?
    /// 紐づく Gaussian Splatting アセット
    var splatAsset: SplatAsset?
    /// 簡易ジオメトリ(RealityKit / 2D 間取り描画の共通ソース)
    var simplifiedGeometry: SimplifiedRoomGeometry = SimplifiedRoomGeometry()

    var roomDataURL: URL? { roomDataPath.map(AppFiles.url(forRelativePath:)) }
    var usdzURL: URL? { usdzPath.map(AppFiles.url(forRelativePath:)) }
    var thumbnailURL: URL? { thumbnailPath.map(AppFiles.url(forRelativePath:)) }
}

// MARK: - 簡易ジオメトリ

/// RoomPlan の CapturedRoom を、描画しやすい「箱の集まり」に落とした表現。
/// RoomPlan 非対応環境でもデモデータとして手組みできる。
struct SimplifiedRoomGeometry: Codable, Hashable {
    var walls: [RoomWall] = []
    var openings: [RoomOpening] = []
    var furniture: [RoomFurniture] = []
    var floor: RoomFloor?

    var isEmpty: Bool { walls.isEmpty && furniture.isEmpty && floor == nil }
}

struct RoomWall: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// 壁の中心位置(メートル、スキャン時のワールド座標)
    var position: SIMD3<Float>
    /// Y 軸回転(ラジアン)
    var rotationY: Float
    /// 幅(壁に沿った長さ) × 高さ × 厚み
    var size: SIMD3<Float>
}

struct RoomOpening: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case door
        case window
        case opening

        var displayName: String {
            switch self {
            case .door: return "ドア"
            case .window: return "窓"
            case .opening: return "開口部"
            }
        }

        var symbolName: String {
            switch self {
            case .door: return "door.left.hand.open"
            case .window: return "window.casement"
            case .opening: return "rectangle.portrait"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var position: SIMD3<Float>
    var rotationY: Float
    var size: SIMD3<Float>
}

struct RoomFurniture: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var category: FurnitureCategory
    var position: SIMD3<Float>
    var rotationY: Float
    var size: SIMD3<Float>
}

struct RoomFloor: Codable, Hashable {
    var position: SIMD3<Float>
    var rotationY: Float
    /// 幅 × 厚み × 奥行
    var size: SIMD3<Float>
}

/// RoomPlan の CapturedRoom.Object.Category に対応する家具分類
enum FurnitureCategory: String, Codable, Hashable, CaseIterable {
    case bed, sofa, table, chair, storage, television
    case refrigerator, stove, sink, toilet, bathtub, oven
    case dishwasher, washerDryer, fireplace, stairs, unknown

    var displayName: String {
        switch self {
        case .bed: return "ベッド"
        case .sofa: return "ソファ"
        case .table: return "テーブル"
        case .chair: return "椅子"
        case .storage: return "収納"
        case .television: return "テレビ"
        case .refrigerator: return "冷蔵庫"
        case .stove: return "コンロ"
        case .sink: return "シンク"
        case .toilet: return "トイレ"
        case .bathtub: return "浴槽"
        case .oven: return "オーブン"
        case .dishwasher: return "食洗機"
        case .washerDryer: return "洗濯機"
        case .fireplace: return "暖炉"
        case .stairs: return "階段"
        case .unknown: return "家具"
        }
    }

    var symbolName: String {
        switch self {
        case .bed: return "bed.double.fill"
        case .sofa: return "sofa.fill"
        case .table: return "table.furniture"
        case .chair: return "chair.fill"
        case .storage: return "books.vertical.fill"
        case .television: return "tv.fill"
        case .refrigerator: return "refrigerator.fill"
        case .stove: return "stove.fill"
        case .sink: return "sink.fill"
        case .toilet: return "toilet.fill"
        case .bathtub: return "bathtub.fill"
        case .oven: return "oven.fill"
        case .dishwasher: return "dishwasher.fill"
        case .washerDryer: return "washer.fill"
        case .fireplace: return "fireplace.fill"
        case .stairs: return "stairs"
        case .unknown: return "cube.fill"
        }
    }

    /// 写真モードで塗り分けるときの色
    var uiColor: UIColor {
        switch self {
        case .bed: return UIColor.systemIndigo
        case .sofa: return UIColor.systemGreen
        case .table, .chair: return UIColor.brown
        case .storage: return UIColor.systemOrange
        case .television: return UIColor.darkGray
        case .refrigerator, .washerDryer, .dishwasher: return UIColor.systemGray
        case .stove, .oven, .fireplace: return UIColor.systemRed
        case .sink, .toilet, .bathtub: return UIColor.systemTeal
        case .stairs: return UIColor.systemBrown
        case .unknown: return UIColor.systemBlue
        }
    }
}

// MARK: - メモピン

enum MemoCategory: String, Codable, Hashable, CaseIterable, Identifiable {
    case scratch, favorite, furnitureIdea, renovation, viewing, memory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scratch: return "傷"
        case .favorite: return "お気に入り"
        case .furnitureIdea: return "家具候補"
        case .renovation: return "リフォーム案"
        case .viewing: return "内見メモ"
        case .memory: return "思い出"
        }
    }

    var symbolName: String {
        switch self {
        case .scratch: return "bandage.fill"
        case .favorite: return "heart.fill"
        case .furnitureIdea: return "sofa.fill"
        case .renovation: return "hammer.fill"
        case .viewing: return "magnifyingglass"
        case .memory: return "sparkles"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .scratch: return UIColor.systemOrange
        case .favorite: return UIColor.systemPink
        case .furnitureIdea: return UIColor.systemTeal
        case .renovation: return UIColor.systemYellow
        case .viewing: return UIColor.systemBlue
        case .memory: return UIColor.systemPurple
        }
    }

    var color: Color { Color(uiColor: uiColor) }
}

struct RoomMemoPin: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var category: MemoCategory
    var createdAt: Date = Date()
    /// 部屋空間(スキャン座標系)での位置
    var position: SIMD3<Float>
    /// nil = 全バージョン共通
    var versionID: UUID?
    /// 添付写真(Documents からの相対パス)
    var photoPaths: [String] = []
}

// MARK: - 家具ゴースト

enum FurnitureGhostType: String, Codable, Hashable, CaseIterable, Identifiable {
    case bed, desk, sofa, bookshelf, tvStand, plant, refrigerator, washingMachine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bed: return "ベッド"
        case .desk: return "机"
        case .sofa: return "ソファ"
        case .bookshelf: return "本棚"
        case .tvStand: return "テレビ台"
        case .plant: return "観葉植物"
        case .refrigerator: return "冷蔵庫"
        case .washingMachine: return "洗濯機"
        }
    }

    var symbolName: String {
        switch self {
        case .bed: return "bed.double.fill"
        case .desk: return "studentdesk"
        case .sofa: return "sofa.fill"
        case .bookshelf: return "books.vertical.fill"
        case .tvStand: return "tv.fill"
        case .plant: return "leaf.fill"
        case .refrigerator: return "refrigerator.fill"
        case .washingMachine: return "washer.fill"
        }
    }

    /// 幅 × 高さ × 奥行(メートル)
    var defaultSize: SIMD3<Float> {
        switch self {
        case .bed: return [1.4, 0.45, 2.0]
        case .desk: return [1.2, 0.72, 0.6]
        case .sofa: return [1.8, 0.8, 0.85]
        case .bookshelf: return [0.8, 1.8, 0.3]
        case .tvStand: return [1.5, 0.45, 0.4]
        case .plant: return [0.4, 1.2, 0.4]
        case .refrigerator: return [0.65, 1.7, 0.65]
        case .washingMachine: return [0.6, 0.85, 0.6]
        }
    }

    var uiColor: UIColor {
        switch self {
        case .bed: return UIColor.systemCyan
        case .desk: return UIColor.systemMint
        case .sofa: return UIColor.systemGreen
        case .bookshelf: return UIColor.systemOrange
        case .tvStand: return UIColor.systemPurple
        case .plant: return UIColor.systemGreen
        case .refrigerator: return UIColor.systemTeal
        case .washingMachine: return UIColor.systemBlue
        }
    }

    var color: Color { Color(uiColor: uiColor) }
}

struct FurnitureGhost: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var type: FurnitureGhostType
    var name: String
    var position: SIMD3<Float>
    var rotationY: Float = 0
    var size: SIMD3<Float>
    /// nil = 全バージョン共通
    var versionID: UUID?
}

// MARK: - ジオメトリ計算ヘルパー

enum RoomGeometryMath {
    /// Y 軸回転した箱の上面図 4 隅を (x, z) で返す
    static func footprintCorners(position: SIMD3<Float>, rotationY: Float, size: SIMD3<Float>) -> [SIMD2<Float>] {
        let hx = size.x / 2
        let hz = size.z / 2
        let c = cos(rotationY)
        let s = sin(rotationY)
        // +Y 回転でローカル X 軸 → (c, -s)、ローカル Z 軸 → (s, c)
        let ax = SIMD2<Float>(c, -s)
        let az = SIMD2<Float>(s, c)
        let center = SIMD2<Float>(position.x, position.z)
        return [
            center + ax * hx + az * hz,
            center + ax * hx - az * hz,
            center - ax * hx - az * hz,
            center - ax * hx + az * hz,
        ]
    }

    /// 壁の両端点(上面図)
    static func wallEndpoints(_ wall: RoomWall) -> (SIMD2<Float>, SIMD2<Float>) {
        let c = cos(wall.rotationY)
        let s = sin(wall.rotationY)
        let dir = SIMD2<Float>(c, -s)
        let center = SIMD2<Float>(wall.position.x, wall.position.z)
        let half = wall.size.x / 2
        return (center - dir * half, center + dir * half)
    }
}

extension SimplifiedRoomGeometry {
    /// 上面図での全パーツの外接矩形 (min, max)
    var horizontalBounds: (min: SIMD2<Float>, max: SIMD2<Float>)? {
        var points: [SIMD2<Float>] = []
        for w in walls {
            points.append(contentsOf: RoomGeometryMath.footprintCorners(position: w.position, rotationY: w.rotationY, size: w.size))
        }
        for f in furniture {
            points.append(contentsOf: RoomGeometryMath.footprintCorners(position: f.position, rotationY: f.rotationY, size: f.size))
        }
        if let floor {
            points.append(contentsOf: RoomGeometryMath.footprintCorners(position: floor.position, rotationY: floor.rotationY, size: floor.size))
        }
        guard !points.isEmpty else { return nil }
        var minP = points[0]
        var maxP = points[0]
        for p in points {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        return (minP, maxP)
    }

    /// 床面の高さ(Y)。壁の下端の最小値、なければ 0
    var floorY: Float {
        let wallBottoms = walls.map { $0.position.y - $0.size.y / 2 }
        if let floor {
            return min(wallBottoms.min() ?? 0, floor.position.y + floor.size.y / 2)
        }
        return wallBottoms.min() ?? 0
    }

    /// 天井までの高さ。壁の高さの最大値、なければ 2.4m
    var wallHeight: Float {
        walls.map(\.size.y).max() ?? 2.4
    }

    /// 上面図の中心(部屋の再センタリング用)
    var horizontalCenter: SIMD2<Float> {
        guard let bounds = horizontalBounds else { return .zero }
        return (bounds.min + bounds.max) / 2
    }

    /// おおまかな部屋サイズ(幅, 高さ, 奥行)
    var approximateSize: SIMD3<Float> {
        guard let bounds = horizontalBounds else { return [4, 2.4, 3] }
        let extent = bounds.max - bounds.min
        return [max(extent.x, 0.5), wallHeight, max(extent.y, 0.5)]
    }
}
