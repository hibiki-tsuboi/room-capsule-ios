import Foundation
import SwiftUI
import SceneKit
import UIKit

// MARK: - レンダラー抽象化
//
// 将来 Metal / RealityKit ベースの本物の Gaussian Splatting レンダラーに
// 差し替えられるよう、ビューアはこの抽象化を経由してレンダラーを選ぶ。
// アプリ本体は具体的なレンダリング実装に依存しない。

/// このビルドで Splat アセットをどう表示できるか
enum SplatRendererAvailability {
    /// 本物の Gaussian Splatting レンダリング(将来の Metal / RealityKit 実装)
    case realRendering(name: String)
    /// 点群による簡易プレビュー
    case pointCloudPreview
    /// メタデータ表示のみ
    case metadataOnly(reason: String)

    static func availability(for asset: SplatAsset) -> SplatRendererAvailability {
        if SplatRendererRegistry.active.isRealGaussianSplatting,
           SplatRendererRegistry.active.canRender(asset) {
            return .realRendering(name: SplatRendererRegistry.active.rendererName)
        }
        if asset.fileType.supportsPointCloudPreview {
            return .pointCloudPreview
        }
        return .metadataOnly(reason: "\(asset.fileType.displayName) の展開はこのビルドでは未対応です")
    }

    var badgeText: String {
        switch self {
        case .realRendering(let name): return "実レンダリング(\(name))"
        case .pointCloudPreview: return "簡易プレビュー(点群)"
        case .metadataOnly: return "プレビュー未対応"
        }
    }
}

/// Splat レンダラーが満たすべきインターフェース
protocol SplatRenderable {
    var rendererName: String { get }
    /// 本物の Gaussian Splatting(楕円ガウスの重ね合わせ)を描けるか
    var isRealGaussianSplatting: Bool { get }
    func canRender(_ asset: SplatAsset) -> Bool
}

/// SceneKit の点群でそれっぽく見せるフォールバックレンダラー
struct PointCloudSplatRenderer: SplatRenderable {
    let rendererName = "PointCloud (SceneKit)"
    let isRealGaussianSplatting = false

    func canRender(_ asset: SplatAsset) -> Bool {
        asset.fileType.supportsPointCloudPreview
    }
}

enum SplatRendererRegistry {
    /// 現在使用するレンダラー。
    /// Metal による実レンダリング(MetalGaussianSplatRenderer)を使い、
    /// 3DGS 属性のないファイルはビューア側で点群プレビューへフォールバックする。
    static let active: any SplatRenderable = MetalGaussianSplatRenderer()
}

// MARK: - SceneKit 点群ビュー

/// パース済み点群を SceneKit で表示する。
/// カメラ操作は SceneKit 標準(ドラッグで回転、ピンチでズーム)。
struct SplatPointCloudView: UIViewRepresentable {
    let cloud: SplatPointCloud
    var flipUpsideDown: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false

        let scene = SCNScene()
        let cloudNode = SCNNode(geometry: Self.makeGeometry(cloud))
        cloudNode.name = "cloud"
        scene.rootNode.addChildNode(cloudNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = Double(cloud.boundingRadius) * 20 + 100
        cameraNode.position = SCNVector3(0, 0, cloud.boundingRadius * 2.2)
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        context.coordinator.cloudNode = cloudNode
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // 3DGS データは上下反転していることが多いので、トグルで補正できるようにする
        context.coordinator.cloudNode?.eulerAngles.x = flipUpsideDown ? .pi : 0
    }

    static func makeGeometry(_ cloud: SplatPointCloud) -> SCNGeometry {
        let vertices = cloud.positions.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        let colorData = cloud.colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: cloud.colors.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: 4,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let element = SCNGeometryElement(
            data: nil,
            primitiveType: .point,
            primitiveCount: cloud.positions.count,
            bytesPerIndex: 0
        )
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 8

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        return geometry
    }

    final class Coordinator {
        var cloudNode: SCNNode?
    }
}
