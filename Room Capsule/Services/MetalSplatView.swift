import Foundation
import Metal
import MetalKit
import SwiftUI
import UIKit
import simd

// MARK: - サポート判定

enum MetalSplatSupport {
    /// Metal デバイスが取れるか(シミュレータでも true)
    static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }
}

nonisolated enum MetalSplatError: LocalizedError {
    case deviceUnavailable
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "Metal デバイスを初期化できませんでした"
        case .libraryUnavailable: return "Metal シェーダライブラリを読み込めませんでした"
        }
    }
}

// MARK: - 深度ソート

/// 奥→手前の描画順を作る 16bit カウンティングソート。
/// 100 万スプラットでも数十 ms で終わるのでバックグラウンドで回す。
nonisolated enum SplatDepthSorter {
    static func backToFrontIndices(positions: [Float], count: Int, forward: SIMD3<Float>) -> [UInt32] {
        guard count > 0 else { return [] }

        var depths = [Float](repeating: 0, count: count)
        var minDepth = Float.greatestFiniteMagnitude
        var maxDepth = -Float.greatestFiniteMagnitude
        positions.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let d = p[3 * i] * forward.x + p[3 * i + 1] * forward.y + p[3 * i + 2] * forward.z
                depths[i] = d
                if d < minDepth { minDepth = d }
                if d > maxDepth { maxDepth = d }
            }
        }

        let bucketCount = 65536
        let scale = Float(bucketCount - 1) / max(maxDepth - minDepth, 1e-6)
        var keys = [UInt16](repeating: 0, count: count)
        var counts = [UInt32](repeating: 0, count: bucketCount)
        for i in 0..<count {
            // 遠い(forward 方向に大きい)ものを先に描くため降順キーにする
            let q = Int((depths[i] - minDepth) * scale)
            let key = UInt16(bucketCount - 1 - min(bucketCount - 1, max(0, q)))
            keys[i] = key
            counts[Int(key)] += 1
        }
        var starts = [UInt32](repeating: 0, count: bucketCount)
        var running: UInt32 = 0
        for bucket in 0..<bucketCount {
            starts[bucket] = running
            running += counts[bucket]
        }
        var output = [UInt32](repeating: 0, count: count)
        for i in 0..<count {
            let key = Int(keys[i])
            output[Int(starts[key])] = UInt32(i)
            starts[key] += 1
        }
        return output
    }
}

// MARK: - Uniforms(GaussianSplat.metal と同一レイアウト)

struct SplatUniforms {
    var view: simd_float4x4
    var projection: simd_float4x4
    var viewport: SIMD2<Float>
    var focal: SIMD2<Float>

    static func placeholder(viewport: CGSize) -> SplatUniforms {
        SplatUniforms(
            view: matrix_identity_float4x4,
            projection: matrix_identity_float4x4,
            viewport: [Float(viewport.width), Float(viewport.height)],
            focal: [1, 1]
        )
    }
}

// MARK: - 共通レンダリングコア

/// パイプライン・バッファ・深度ソートを持つ共通コア。
/// オービットビューア(SplatMetalRenderer)と AR オーバーレイ(SplatARRenderer)で共用する。
@MainActor
final class SplatRenderCore {
    let device: MTLDevice
    let cloud: GaussianSplatCloud
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let positionBuffer: MTLBuffer
    private let covarianceBuffer: MTLBuffer
    private let colorBuffer: MTLBuffer
    private var indexBuffers: [MTLBuffer]
    private var activeIndexBuffer = 0

    // ソート状態
    private var lastSortForward: SIMD3<Float>?
    private var lastSortOrigin: SIMD3<Float>?
    private var sortInFlight = false

    init(cloud: GaussianSplatCloud) throws {
        guard cloud.count > 0 else {
            throw SplatLoadError.corruptFile("表示できるスプラットがありません")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw MetalSplatError.deviceUnavailable
        }
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "splatVertex"),
              let fragmentFunction = library.makeFunction(name: "splatFragment") else {
            throw MetalSplatError.libraryUnavailable
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        if let attachment = descriptor.colorAttachments[0] {
            attachment.pixelFormat = .bgra8Unorm
            // プリマルチプライド α の奥→手前合成(透明背景の上でも成立する)
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        guard let positionBuffer = cloud.positions.withUnsafeBufferPointer({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)
              }),
              let covarianceBuffer = cloud.covariances.withUnsafeBufferPointer({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)
              }),
              let colorBuffer = cloud.colors.withUnsafeBufferPointer({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
              }),
              let indexBufferA = device.makeBuffer(length: cloud.count * 4, options: .storageModeShared),
              let indexBufferB = device.makeBuffer(length: cloud.count * 4, options: .storageModeShared) else {
            throw MetalSplatError.deviceUnavailable
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.positionBuffer = positionBuffer
        self.covarianceBuffer = covarianceBuffer
        self.colorBuffer = colorBuffer
        self.indexBuffers = [indexBufferA, indexBufferB]
        self.cloud = cloud

        // ソート完了までの間も描画が成立するよう、元の並びで初期化しておく
        upload(Array(0..<UInt32(cloud.count)), into: 0)
        upload(Array(0..<UInt32(cloud.count)), into: 1)
    }

    /// モデル行列まで合成済みのビュー行列から、同期でソートする(初期表示用)
    func sortNow(combinedView: simd_float4x4) {
        guard let forward = sortForward(of: combinedView) else { return }
        let indices = SplatDepthSorter.backToFrontIndices(
            positions: cloud.positions, count: cloud.count, forward: forward
        )
        upload(indices, into: activeIndexBuffer)
        lastSortForward = forward
        lastSortOrigin = cameraPositionInModelSpace(combinedView)
    }

    /// カメラの向き・位置が一定以上変わっていたらバックグラウンドで再ソート
    func resortIfNeeded(combinedView: simd_float4x4) {
        guard let forward = sortForward(of: combinedView) else { return }
        let origin = cameraPositionInModelSpace(combinedView)
        if let lastForward = lastSortForward, let lastOrigin = lastSortOrigin,
           simd_dot(lastForward, forward) > 0.999,
           simd_distance(lastOrigin, origin) < max(0.3, cloud.boundingRadius * 0.05) {
            return
        }
        guard !sortInFlight else { return }
        sortInFlight = true

        let positions = cloud.positions
        let count = cloud.count
        Task.detached(priority: .userInitiated) { [forward] in
            let indices = SplatDepthSorter.backToFrontIndices(
                positions: positions, count: count, forward: forward
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                let inactive = 1 - self.activeIndexBuffer
                self.upload(indices, into: inactive)
                self.activeIndexBuffer = inactive
                self.lastSortForward = forward
                self.lastSortOrigin = origin
                self.sortInFlight = false
            }
        }
    }

    /// 1 フレーム描画する。visible = false のときはクリア(透明)のみ
    func render(in view: MTKView, uniforms: SplatUniforms, visible: Bool = true) {
        guard let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
            if visible {
                var uniforms = uniforms
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(covarianceBuffer, offset: 0, index: 1)
                encoder.setVertexBuffer(colorBuffer, offset: 0, index: 2)
                encoder.setVertexBuffer(indexBuffers[activeIndexBuffer], offset: 0, index: 3)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 4)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cloud.count)
            }
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: 内部

    /// ビュー行列の -z 行 = 「カメラから遠ざかる方向」(モデル空間)
    private func sortForward(of view: simd_float4x4) -> SIMD3<Float>? {
        let row2 = SIMD3<Float>(view.columns.0.z, view.columns.1.z, view.columns.2.z)
        guard simd_length(row2) > 1e-6 else { return nil }
        return simd_normalize(-row2)
    }

    private func cameraPositionInModelSpace(_ view: simd_float4x4) -> SIMD3<Float> {
        let inverse = view.inverse
        return SIMD3<Float>(inverse.columns.3.x, inverse.columns.3.y, inverse.columns.3.z)
    }

    private func upload(_ indices: [UInt32], into bufferIndex: Int) {
        indices.withUnsafeBytes { raw in
            indexBuffers[bufferIndex].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
    }
}

// MARK: - オービットカメラのレンダラー(ビューア用)

/// MTKView に Gaussian Splatting を描画するレンダラー。
/// オービットカメラの状態もここで持つ(ジェスチャは MetalSplatView から流し込む)。
@MainActor
final class SplatMetalRenderer: NSObject, MTKViewDelegate {
    private let core: SplatRenderCore
    var device: MTLDevice { core.device }

    // オービットカメラ(少し上から見下ろす引きの構図で開始)
    private var yaw: Float = 0.6
    private var pitch: Float = 0.85
    private var radius: Float
    private let target = SIMD3<Float>(repeating: 0)
    var flipUpsideDown = true

    init(cloud: GaussianSplatCloud) throws {
        self.core = try SplatRenderCore(cloud: cloud)
        self.radius = max(cloud.boundingRadius * 2.6, 0.5)
        super.init()
        // 最初のフレームから正しい順序で描けるよう同期ソート
        core.sortNow(combinedView: combinedViewMatrix())
    }

    // MARK: ジェスチャ入力

    func orbit(deltaX: Float, deltaY: Float) {
        yaw -= deltaX * 0.008
        pitch = min(max(pitch + deltaY * 0.006, -1.4), 1.4)
    }

    func zoom(by scale: Float) {
        radius = min(max(radius / scale, core.cloud.boundingRadius * 0.15), core.cloud.boundingRadius * 5)
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            render(in: view)
        }
    }

    private func render(in view: MTKView) {
        let size = view.drawableSize
        guard size.width > 1, size.height > 1 else { return }
        let uniforms = makeUniforms(drawableSize: size)
        core.resortIfNeeded(combinedView: uniforms.view)
        core.render(in: view, uniforms: uniforms)
    }

    // MARK: カメラ・行列

    private func makeUniforms(drawableSize: CGSize) -> SplatUniforms {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        let fovY: Float = 50 * .pi / 180
        let near = max(0.02, radius * 0.01)
        let far = max(core.cloud.boundingRadius * 20, radius * 4)
        let projection = Self.perspective(fovY: fovY, aspect: width / height, near: near, far: far)
        let focalY = 0.5 * height / tan(fovY * 0.5)
        return SplatUniforms(
            view: combinedViewMatrix(),
            projection: projection,
            viewport: [width, height],
            focal: [focalY, focalY]
        )
    }

    private func combinedViewMatrix() -> simd_float4x4 {
        let eye = SIMD3<Float>(
            target.x + radius * cos(pitch) * sin(yaw),
            target.y + radius * sin(pitch),
            target.z + radius * cos(pitch) * cos(yaw)
        )
        var view = Self.lookAt(eye: eye, target: target, up: [0, 1, 0])
        if flipUpsideDown {
            // 3DGS データは上下反転していることが多いので X 軸 180° 回転で補正
            view = view * Self.rotationX(.pi)
        }
        return view
    }

    // MARK: 行列ヘルパー(右手系、カメラは -z を向く)

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func uniformScale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(s, 0, 0, 0),
            SIMD4<Float>(0, s, 0, 0),
            SIMD4<Float>(0, 0, s, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}

// MARK: - SwiftUI ラッパー(ビューア)

/// Gaussian Splatting 実レンダリングビュー(ドラッグで回転・ピンチで拡大縮小)
struct MetalSplatView: UIViewRepresentable {
    let cloud: GaussianSplatCloud
    var flipUpsideDown: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.clearColor = MTLClearColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60

        if let renderer = try? SplatMetalRenderer(cloud: cloud) {
            renderer.flipUpsideDown = flipUpsideDown
            view.device = renderer.device
            view.delegate = renderer
            context.coordinator.renderer = renderer // MTKView.delegate は weak なのでここで保持

            view.addGestureRecognizer(
                UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
            )
            view.addGestureRecognizer(
                UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
            )
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.flipUpsideDown = flipUpsideDown
    }

    @MainActor
    final class Coordinator: NSObject {
        var renderer: SplatMetalRenderer?

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            renderer?.orbit(deltaX: Float(translation.x), deltaY: Float(translation.y))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            let scale = Float(recognizer.scale)
            recognizer.scale = 1
            renderer?.zoom(by: scale)
        }
    }
}

// MARK: - SplatRenderable 実装

/// Metal による本物の Gaussian Splatting レンダラー。
/// SplatRendererRegistry.active に登録して使う。
struct MetalGaussianSplatRenderer: SplatRenderable {
    let rendererName = "Metal Gaussian Splatting"
    let isRealGaussianSplatting = true

    func canRender(_ asset: SplatAsset) -> Bool {
        asset.fileType != .spz && MetalSplatSupport.isAvailable
    }
}
