import MetalKit
import simd
import TopographCore

/// What the terrain draws: the items and their elevation field.
struct TerrainScene: Sendable {
    let id = UUID()
    let items: [MapItem]
    let field: DensityField
}

/// Keep in step with `Uniforms` in Terrain.metal.
private struct Uniforms {
    var ground: SIMD4<Float>
    var ink: SIMD4<Float>
    var hair: SIMD4<Float>
    var drawable: SIMD2<Float>
    var translate: SIMD2<Float>
    var scale: Float
    var k: Float
    var origin: Float
    var cell: Float
    var markerZoom: Float
}

private struct Marker {
    var position: SIMD2<Float>
    var base: Float
    var mine: Float
}

/// Draws the terrain with one full-view pass and one instanced pass of markers.
/// Nothing runs between frames: the view redraws only when something changes.
@MainActor
final class TerrainRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let terrainPipeline: MTLRenderPipelineState
    private let markerPipeline: MTLRenderPipelineState
    private var field: MTLTexture?
    private var markers: MTLBuffer?
    private var markerCount = 0

    init(view: MTKView) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw RendererError.unavailable
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        self.device = device
        self.queue = queue

        let terrain = MTLRenderPipelineDescriptor()
        terrain.vertexFunction = library.makeFunction(name: "terrainVertex")
        terrain.fragmentFunction = library.makeFunction(name: "terrainFragment")
        terrain.colorAttachments[0].pixelFormat = view.colorPixelFormat
        terrainPipeline = try device.makeRenderPipelineState(descriptor: terrain)

        let marker = MTLRenderPipelineDescriptor()
        marker.vertexFunction = library.makeFunction(name: "markerVertex")
        marker.fragmentFunction = library.makeFunction(name: "markerFragment")
        let color = marker.colorAttachments[0]!
        color.pixelFormat = view.colorPixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        markerPipeline = try device.makeRenderPipelineState(descriptor: marker)
    }

    func setScene(_ scene: TerrainScene?) {
        guard let scene else {
            field = nil
            markers = nil
            markerCount = 0
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: scene.field.width, height: scene.field.height, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)
        scene.field.elevation.withUnsafeBytes { bytes in
            texture?.replace(region: MTLRegionMake2D(0, 0, scene.field.width, scene.field.height),
                             mipmapLevel: 0, withBytes: bytes.baseAddress!,
                             bytesPerRow: scene.field.width * MemoryLayout<Float>.stride)
        }
        field = texture

        let instances = scene.items.map { item in
            Marker(position: SIMD2(item.x, item.y),
                   base: TerrainStyle.markerBase(resonance: item.resonance),
                   mine: item.mine ? 1 : 0)
        }
        markers = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<Marker>.stride)
        markerCount = instances.count
    }

    func draw(in view: MTKView, transform: MapTransform, theme: Theme) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        let ground = theme.ground.simd
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(ground.x), green: Double(ground.y),
                                                            blue: Double(ground.z), alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        let scale = view.bounds.width > 0 ? Float(size.width / view.bounds.width) : 1
        var uniforms = Uniforms(ground: ground, ink: theme.ink.simd, hair: theme.hair.simd,
                                drawable: SIMD2(Float(size.width), Float(size.height)),
                                translate: SIMD2(Float(transform.x), Float(transform.y)),
                                scale: scale, k: Float(transform.k),
                                origin: Float(DensityField.origin), cell: Float(DensityField.cellSize),
                                markerZoom: Float(TerrainStyle.markerZoomLimit))
        let uniformLength = MemoryLayout<Uniforms>.stride

        if let field {
            var levels = UInt32(TerrainStyle.levels)
            encoder.setRenderPipelineState(terrainPipeline)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            setBytes(TerrainStyle.thresholds, encoder, index: 1)
            setBytes(TerrainStyle.ditherDensity, encoder, index: 2)
            setBytes(TerrainStyle.bayer, encoder, index: 3)
            encoder.setFragmentBytes(&levels, length: MemoryLayout<UInt32>.stride, index: 4)
            encoder.setFragmentTexture(field, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        if let markers, markerCount > 0 {
            encoder.setRenderPipelineState(markerPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            encoder.setVertexBuffer(markers, offset: 0, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: markerCount)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private func setBytes(_ values: [Float], _ encoder: MTLRenderCommandEncoder, index: Int) {
        values.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: index) }
    }
}

enum RendererError: LocalizedError {
    case unavailable
    var errorDescription: String? { "This Mac's graphics hardware couldn't be set up for Metal." }
}
