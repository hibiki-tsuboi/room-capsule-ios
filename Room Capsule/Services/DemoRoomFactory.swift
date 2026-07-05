import Foundation
import simd

/// RoomPlan / LiDAR がない環境でもアプリ全体を体験できるようにする
/// デモ部屋データの生成器。部屋は 4.0m × 3.0m、高さ 2.4m のワンルーム。
enum DemoRoomFactory {

    /// デモカプセル一式(2 バージョン + メモピン 2 つ + 家具ゴースト 1 つ)を作る
    static func makeDemoCapsule(name: String) -> RoomCapsule {
        let now = Date()
        let ninetyDaysAgo = now.addingTimeInterval(-90 * 24 * 60 * 60)

        var before = RoomScanVersion(
            name: "入居前",
            capturedAt: ninetyDaysAgo,
            isDemo: true,
            simplifiedGeometry: makeGeometry(furnished: false)
        )
        before.id = UUID()

        var after = RoomScanVersion(
            name: "家具配置後",
            capturedAt: now,
            isDemo: true,
            simplifiedGeometry: makeGeometry(furnished: true)
        )
        after.id = UUID()

        let pins: [RoomMemoPin] = [
            RoomMemoPin(
                title: "壁に小さな傷",
                body: "入居前からフローリング近くの壁に小さな傷があった。退去時のために記録しておく。",
                category: .scratch,
                createdAt: ninetyDaysAgo,
                position: [-1.9, 1.0, 0.3],
                versionID: nil
            ),
            RoomMemoPin(
                title: "朝日がきれいな窓",
                body: "午前中はこの窓からたっぷり光が入る。机はこの近くに置いて正解だった。",
                category: .favorite,
                createdAt: now,
                position: [0.8, 1.5, -1.35],
                versionID: after.id
            ),
        ]

        let ghost = FurnitureGhost(
            type: .plant,
            name: "観葉植物を置きたい",
            position: [1.7, 0.6, 1.1],
            rotationY: 0,
            size: FurnitureGhostType.plant.defaultSize,
            versionID: nil
        )

        return RoomCapsule(
            name: name,
            createdAt: ninetyDaysAgo,
            updatedAt: now,
            versions: [before, after],
            memoPins: pins,
            furnitureGhosts: [ghost]
        )
    }

    /// デモ部屋の簡易ジオメトリ。座標系は部屋の床中央が原点。
    static func makeGeometry(furnished: Bool) -> SimplifiedRoomGeometry {
        var geometry = SimplifiedRoomGeometry()

        let wallHeight: Float = 2.4
        let wallThickness: Float = 0.1
        let halfHeight = wallHeight / 2

        // 内寸 4.0m × 3.0m の長方形の部屋
        geometry.walls = [
            // 北(奥)
            RoomWall(position: [0, halfHeight, -1.55], rotationY: 0, size: [4.2, wallHeight, wallThickness]),
            // 南(手前・ドアのある壁)
            RoomWall(position: [0, halfHeight, 1.55], rotationY: 0, size: [4.2, wallHeight, wallThickness]),
            // 西
            RoomWall(position: [-2.05, halfHeight, 0], rotationY: .pi / 2, size: [3.0, wallHeight, wallThickness]),
            // 東
            RoomWall(position: [2.05, halfHeight, 0], rotationY: .pi / 2, size: [3.0, wallHeight, wallThickness]),
        ]

        geometry.floor = RoomFloor(position: [0, -0.05, 0], rotationY: 0, size: [4.2, 0.1, 3.2])

        geometry.openings = [
            // 北壁の窓
            RoomOpening(kind: .window, position: [0.8, 1.4, -1.53], rotationY: 0, size: [1.2, 1.0, 0.06]),
            // 南壁のドア
            RoomOpening(kind: .door, position: [-1.2, 1.0, 1.53], rotationY: 0, size: [0.85, 2.0, 0.06]),
        ]

        if furnished {
            geometry.furniture = [
                // ベッド(西側)
                RoomFurniture(category: .bed, position: [-1.25, 0.25, -0.45], rotationY: 0, size: [1.4, 0.5, 2.0]),
                // 机(北東の窓ぎわ)
                RoomFurniture(category: .table, position: [1.4, 0.36, -1.15], rotationY: 0, size: [1.2, 0.72, 0.6]),
                // 椅子
                RoomFurniture(category: .chair, position: [1.4, 0.45, -0.45], rotationY: 0, size: [0.45, 0.9, 0.45]),
                // 本棚(東の壁ぎわ)
                RoomFurniture(category: .storage, position: [1.78, 0.9, 0.6], rotationY: .pi / 2, size: [0.9, 1.8, 0.35]),
            ]
        }

        return geometry
    }
}
