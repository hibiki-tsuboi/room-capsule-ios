import Foundation
import simd
#if canImport(RoomPlan)
import RoomPlan
#endif

/// RoomPlan の CapturedRoom を、アプリ内で扱う SimplifiedRoomGeometry
/// (箱の集まり)へ変換する。RoomPlan の詳細メッシュに依存せず、
/// どの表示モードでも確実に描けるようにするための層。
enum CapturedRoomConverter {

    #if canImport(RoomPlan)
    static func simplifiedGeometry(from room: CapturedRoom) -> SimplifiedRoomGeometry {
        var geometry = SimplifiedRoomGeometry()

        geometry.walls = room.walls.map { surface in
            RoomWall(
                position: translation(of: surface.transform),
                rotationY: yaw(of: surface.transform),
                size: paddedSize(surface.dimensions, minThickness: 0.08)
            )
        }

        var openings: [RoomOpening] = []
        openings += room.doors.map { makeOpening(kind: .door, from: $0) }
        openings += room.windows.map { makeOpening(kind: .window, from: $0) }
        openings += room.openings.map { makeOpening(kind: .opening, from: $0) }
        geometry.openings = openings

        geometry.furniture = room.objects.map { object in
            RoomFurniture(
                category: furnitureCategory(for: object.category),
                position: translation(of: object.transform),
                rotationY: yaw(of: object.transform),
                size: simd_max(object.dimensions, SIMD3<Float>(repeating: 0.05))
            )
        }

        // 床は RoomPlan の床サーフェスに頼らず、壁の外接矩形から安定的に導出する
        geometry.floor = derivedFloor(from: geometry)

        return geometry
    }

    private static func makeOpening(kind: RoomOpening.Kind, from surface: CapturedRoom.Surface) -> RoomOpening {
        RoomOpening(
            kind: kind,
            position: translation(of: surface.transform),
            rotationY: yaw(of: surface.transform),
            size: paddedSize(surface.dimensions, minThickness: 0.06)
        )
    }

    private static func furnitureCategory(for category: CapturedRoom.Object.Category) -> FurnitureCategory {
        switch category {
        case .bed: return .bed
        case .sofa: return .sofa
        case .table: return .table
        case .chair: return .chair
        case .storage: return .storage
        case .television: return .television
        case .refrigerator: return .refrigerator
        case .stove: return .stove
        case .sink: return .sink
        case .toilet: return .toilet
        case .bathtub: return .bathtub
        case .oven: return .oven
        case .dishwasher: return .dishwasher
        case .washerDryer: return .washerDryer
        case .fireplace: return .fireplace
        case .stairs: return .stairs
        @unknown default: return .unknown
        }
    }
    #endif

    // MARK: - 共通ヘルパー(RoomPlan 非依存)

    /// 変換行列から位置を取り出す
    static func translation(of matrix: simd_float4x4) -> SIMD3<Float> {
        [matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z]
    }

    /// 変換行列から Y 軸回転(ヨー)を取り出す。
    /// 壁・家具は鉛直に立っている前提の近似。
    static func yaw(of matrix: simd_float4x4) -> Float {
        atan2(-matrix.columns.0.z, matrix.columns.0.x)
    }

    /// サーフェスの厚みがほぼ 0 のことがあるため最低値を確保する
    static func paddedSize(_ size: SIMD3<Float>, minThickness: Float) -> SIMD3<Float> {
        [max(size.x, 0.05), max(size.y, 0.05), max(size.z, minThickness)]
    }

    /// 壁の外接矩形から床を導出する
    static func derivedFloor(from geometry: SimplifiedRoomGeometry) -> RoomFloor? {
        var wallsOnly = SimplifiedRoomGeometry()
        wallsOnly.walls = geometry.walls
        guard let bounds = wallsOnly.horizontalBounds else { return nil }
        let center = (bounds.min + bounds.max) / 2
        let extent = bounds.max - bounds.min
        let floorY = wallsOnly.floorY
        return RoomFloor(
            position: [center.x, floorY - 0.05, center.y],
            rotationY: 0,
            size: [extent.x + 0.1, 0.1, extent.y + 0.1]
        )
    }
}
