import Foundation
import ARKit
import Metal
import MetalKit
import simd

/// LiDAR スプラットスキャン中のライブプレビュー。
/// 透明な MTKView に、収集済みスプラットを ARFrame のカメラ行列で描画する
/// (キャプチャ座標 = ワールド座標なのでモデル行列は単位行列)。
///
/// SplatRenderCore と違いデータが増え続けるため、上限ぶんを事前確保した
/// バッファへ追記し、描画順は「定期的なバックグラウンドソート + 新規分は
/// 末尾に単純追加(最前面に描かれる)」で近似する。
@MainActor
final class LiveSplatPreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let positionBuffer: MTLBuffer
    private let covarianceBuffer: MTLBuffer
    private let colorBuffer: MTLBuffer
    private let dummySHBuffer: MTLBuffer
    private var indexBuffers: [MTLBuffer]
    private var indexedCounts: [Int] = [0, 0]
    private var activeIndexBuffer = 0
    private var uploadedCount = 0
    private let capacity: Int
    private let sigma: Float

    weak var arSession: ARSession?
    var isVisible = true

    // ソート状態(約 0.5 秒おきにバックグラウンドで再ソート)
    private var sortInFlight = false
    private var framesSinceSort = 0

    init(capacity: Int, voxelSize: Float) throws {
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
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        guard let positionBuffer = device.makeBuffer(length: capacity * 12, options: .storageModeShared),
              let covarianceBuffer = device.makeBuffer(length: capacity * 24, options: .storageModeShared),
              let colorBuffer = device.makeBuffer(length: capacity * 4, options: .storageModeShared),
              let indexBufferA = device.makeBuffer(length: capacity * 4, options: .storageModeShared),
              let indexBufferB = device.makeBuffer(length: capacity * 4, options: .storageModeShared),
              let dummySHBuffer = device.makeBuffer(length: 45 * 2, options: .storageModeShared) else {
            throw MetalSplatError.deviceUnavailable
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.positionBuffer = positionBuffer
        self.covarianceBuffer = covarianceBuffer
        self.colorBuffer = colorBuffer
        self.dummySHBuffer = dummySHBuffer
        self.indexBuffers = [indexBufferA, indexBufferB]
        self.capacity = capacity
        self.sigma = voxelSize * 0.8
        super.init()
    }

    // MARK: - データ追記

    /// 取り込みキューで作った新規スプラットのスナップショットをバッファへ追記する。
    func sync(chunk: LiDARSplatPreviewChunk) {
        let newCount = min(chunk.previewCount, capacity)
        let chunkStart = min(max(chunk.startIndex, 0), newCount)
        let sourceOffset = max(uploadedCount - chunkStart, 0)
        let start = chunkStart + sourceOffset
        let copyCount = min(
            newCount - start,
            chunk.positions.count / 3 - sourceOffset,
            chunk.colors.count / 4 - sourceOffset
        )
        guard copyCount > 0 else { return }
        let uploadedEnd = start + copyCount

        chunk.positions.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            positionBuffer.contents()
                .advanced(by: start * 12)
                .copyMemory(from: baseAddress + sourceOffset * 3, byteCount: copyCount * 12)
        }
        chunk.colors.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            colorBuffer.contents()
                .advanced(by: start * 4)
                .copyMemory(from: baseAddress + sourceOffset * 4, byteCount: copyCount * 4)
        }
        // 等方ガウスの共分散(対角のみ)
        let variance = sigma * sigma
        let covariancePointer = covarianceBuffer.contents().assumingMemoryBound(to: Float.self)
        for i in start..<uploadedEnd {
            let base = i * 6
            covariancePointer[base + 0] = variance
            covariancePointer[base + 1] = 0
            covariancePointer[base + 2] = 0
            covariancePointer[base + 3] = variance
            covariancePointer[base + 4] = 0
            covariancePointer[base + 5] = variance
        }
        // 新規分はアクティブなインデックスバッファの末尾に単純追加
        let indexPointer = indexBuffers[activeIndexBuffer].contents().assumingMemoryBound(to: UInt32.self)
        for i in start..<uploadedEnd {
            indexPointer[i] = UInt32(i)
        }
        indexedCounts[activeIndexBuffer] = uploadedEnd
        uploadedCount = uploadedEnd
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            render(in: view)
        }
    }

    private func render(in view: MTKView) {
        let size = view.drawableSize
        guard size.width > 1, size.height > 1 else { return }

        guard isVisible, uploadedCount > 0, let frame = arSession?.currentFrame else {
            renderClear(in: view)
            return
        }

        let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let viewportSize = CGSize(width: size.width, height: size.height)
        let projection = frame.camera.projectionMatrix(
            for: orientation, viewportSize: viewportSize, zNear: 0.02, zFar: 60
        )
        let cameraView = frame.camera.viewMatrix(for: orientation)

        var uniforms = SplatUniforms(
            view: cameraView,
            projection: projection,
            viewport: [Float(size.width), Float(size.height)],
            focal: [
                projection.columns.0.x * Float(size.width) / 2,
                projection.columns.1.y * Float(size.height) / 2,
            ]
        )
        resortIfNeeded(cameraView: cameraView)

        guard let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(covarianceBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(colorBuffer, offset: 0, index: 2)
            encoder.setVertexBuffer(indexBuffers[activeIndexBuffer], offset: 0, index: 3)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 4)
            encoder.setVertexBuffer(dummySHBuffer, offset: 0, index: 5)
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                instanceCount: indexedCounts[activeIndexBuffer]
            )
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderClear(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - 定期ソート

    private func resortIfNeeded(cameraView: simd_float4x4) {
        framesSinceSort += 1
        guard framesSinceSort >= 30, !sortInFlight, uploadedCount > 2_000 else { return }
        framesSinceSort = 0
        sortInFlight = true

        let count = uploadedCount
        // 共有メモリのバッファからスナップショットを取ってバックグラウンドでソート
        let positionsCopy = [Float](
            UnsafeBufferPointer(
                start: positionBuffer.contents().assumingMemoryBound(to: Float.self),
                count: count * 3
            )
        )
        let row2 = SIMD3<Float>(cameraView.columns.0.z, cameraView.columns.1.z, cameraView.columns.2.z)
        let forward = simd_normalize(-row2)

        Task.detached(priority: .utility) { [forward] in
            let sorted = SplatDepthSorter.backToFrontIndices(
                positions: positionsCopy, count: count, forward: forward
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                let inactive = 1 - self.activeIndexBuffer
                let indexPointer = self.indexBuffers[inactive].contents().assumingMemoryBound(to: UInt32.self)
                sorted.withUnsafeBufferPointer { source in
                    self.indexBuffers[inactive].contents()
                        .copyMemory(from: source.baseAddress!, byteCount: count * 4)
                }
                // ソート後に増えた分は末尾へ単純追加
                if self.uploadedCount > count {
                    for i in count..<self.uploadedCount {
                        indexPointer[i] = UInt32(i)
                    }
                }
                self.indexedCounts[inactive] = self.uploadedCount
                self.activeIndexBuffer = inactive
                self.sortInFlight = false
            }
        }
    }
}
