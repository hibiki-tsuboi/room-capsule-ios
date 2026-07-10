import Foundation
import simd

/// 同じ部屋を別々にスキャンした 2 バージョンを重ねて比較するための回転推定。
///
/// RoomPlan の座標系は「スキャン開始時の端末の位置と向き」が基準なので、
/// 同じ部屋でもバージョンごとに任意のヨー回転がかかっている。
/// 表示側(RoomEntityFactory)は外接矩形の中心で平行移動を吸収するため、
/// ここでは「target を reference の向きに合わせる回転角」だけを推定する。
enum RoomGeometryAlignment {

    /// target を reference に重ねるためのヨー回転角(ラジアン、Y 軸まわり)。
    /// 支配的な壁方向を合わせた候補 4 つ(90° 刻み)を、壁・開口部・家具の
    /// ランドマーク点の最近傍距離で採点して選ぶ。ドアや窓の位置が
    /// 長方形の部屋の 180° の曖昧さを解いてくれる。
    static func alignmentYaw(of target: SimplifiedRoomGeometry, to reference: SimplifiedRoomGeometry) -> Float {
        guard !target.walls.isEmpty, !reference.walls.isEmpty else { return 0 }

        let base = dominantWallDirection(of: reference) - dominantWallDirection(of: target)
        let referenceLandmarks = landmarks(of: reference)
        let targetLandmarks = landmarks(of: target)

        var bestYaw: Float = 0
        var bestScore = Float.greatestFiniteMagnitude
        for quarter in 0..<4 {
            let yaw = base + Float(quarter) * (.pi / 2)
            let score = matchScore(reference: referenceLandmarks, target: targetLandmarks, yaw: yaw)
            if score < bestScore {
                bestScore = score
                bestYaw = yaw
            }
        }
        return normalizedAngle(bestYaw)
    }

    // MARK: - 間取り図用の正立化

    /// 間取り図・サムネイル用: 壁が水平・垂直になり、部屋が横長になる回転角。
    /// スキャン開始時の端末の向きがそのまま座標系に焼き付いているのを打ち消す。
    static func uprightYaw(of geometry: SimplifiedRoomGeometry) -> Float {
        guard !geometry.walls.isEmpty else { return 0 }
        var yaw = -dominantWallDirection(of: geometry)
        if let bounds = geometry.rotatedAroundY(yaw).horizontalBounds {
            let extent = bounds.max - bounds.min
            if extent.y > extent.x {
                yaw += .pi / 2
            }
        }
        return normalizedAngle(yaw)
    }

    /// 上面図の回転と同じ規約で 3D 点を Y 軸まわりに回す
    static func rotated(_ point: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let flat = rotated(SIMD2(point.x, point.z), by: angle)
        return [flat.x, point.y, flat.y]
    }

    // MARK: - 支配的な壁方向

    /// 壁方向の加重平均(壁は 90° 単位で直交しがちなので mod 90° で扱う)。
    /// 4 倍角の円平均を使うことで 0°/90°/180°/270° の壁を同じ方向として束ねる。
    private static func dominantWallDirection(of geometry: SimplifiedRoomGeometry) -> Float {
        var sinSum: Float = 0
        var cosSum: Float = 0
        for wall in geometry.walls {
            let weight = max(wall.size.x, 0.1)
            sinSum += weight * sin(4 * wall.rotationY)
            cosSum += weight * cos(4 * wall.rotationY)
        }
        guard sinSum != 0 || cosSum != 0 else { return 0 }
        return atan2(sinSum, cosSum) / 4
    }

    // MARK: - ランドマーク採点

    private struct Landmark {
        var point: SIMD2<Float>
        var weight: Float
    }

    /// 表示時のセンタリング(horizontalCenter)と同じ基準で中心化した上面図の特徴点。
    private static func landmarks(of geometry: SimplifiedRoomGeometry) -> [Landmark] {
        let center = geometry.horizontalCenter
        var result: [Landmark] = []
        for wall in geometry.walls {
            result.append(Landmark(
                point: SIMD2(wall.position.x - center.x, wall.position.z - center.y),
                weight: max(wall.size.x, 0.1)
            ))
        }
        for opening in geometry.openings {
            // ドア・窓は長方形の部屋の対称性を破る一番のランドマークなので重めに
            result.append(Landmark(
                point: SIMD2(opening.position.x - center.x, opening.position.z - center.y),
                weight: 2.0
            ))
        }
        for furniture in geometry.furniture {
            result.append(Landmark(
                point: SIMD2(furniture.position.x - center.x, furniture.position.z - center.y),
                weight: 1.0
            ))
        }
        return result
    }

    /// 双方向の加重最近傍距離。小さいほどよく重なっている。
    private static func matchScore(reference: [Landmark], target: [Landmark], yaw: Float) -> Float {
        let rotatedTarget = target.map { Landmark(point: rotated($0.point, by: yaw), weight: $0.weight) }
        return directedScore(from: reference, to: rotatedTarget) + directedScore(from: rotatedTarget, to: reference)
    }

    private static func directedScore(from source: [Landmark], to candidates: [Landmark]) -> Float {
        guard !candidates.isEmpty else { return 0 }
        var total: Float = 0
        for landmark in source {
            var nearest = Float.greatestFiniteMagnitude
            for candidate in candidates {
                nearest = min(nearest, simd_distance_squared(landmark.point, candidate.point))
            }
            total += landmark.weight * nearest.squareRoot()
        }
        return total
    }

    /// エンティティの Y 軸回転(右手系)と同じ向きで上面図 (x, z) を回す
    static func rotated(_ point: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
        SIMD2(
            cos(angle) * point.x + sin(angle) * point.y,
            -sin(angle) * point.x + cos(angle) * point.y
        )
    }

    private static func normalizedAngle(_ angle: Float) -> Float {
        var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if result > .pi { result -= 2 * .pi }
        if result <= -.pi { result += 2 * .pi }
        return result
    }
}

extension SimplifiedRoomGeometry {
    /// 全パーツを原点まわりに Y 軸回転したコピー
    func rotatedAroundY(_ yaw: Float) -> SimplifiedRoomGeometry {
        var result = self
        result.walls = walls.map { wall in
            var rotated = wall
            rotated.position = RoomGeometryAlignment.rotated(wall.position, by: yaw)
            rotated.rotationY += yaw
            return rotated
        }
        result.openings = openings.map { opening in
            var rotated = opening
            rotated.position = RoomGeometryAlignment.rotated(opening.position, by: yaw)
            rotated.rotationY += yaw
            return rotated
        }
        result.furniture = furniture.map { item in
            var rotated = item
            rotated.position = RoomGeometryAlignment.rotated(item.position, by: yaw)
            rotated.rotationY += yaw
            return rotated
        }
        if let floor {
            var rotated = floor
            rotated.position = RoomGeometryAlignment.rotated(floor.position, by: yaw)
            rotated.rotationY += yaw
            result.floor = rotated
        }
        return result
    }
}
