import MetalKit
import simd
import TopographCore

/// What the terrain draws: the items showing and their elevation field.
struct TerrainScene: Sendable {
    let id = UUID()
    let map: LibraryMap
    let visible: [Int32]
    let field: DensityField
    let counts: [Int: Int]
    let spatial: SpatialIndex
    /// Visible items with pictures, most resonant first.
    let pictures: [Int32]
    /// The chart for these items, made together with them while Strata is showing so its
    /// shape and its time range change in the same frame.
    let strata: StrataModel?
    /// Likewise for color through time, while that's showing.
    let colorStrata: StrataModel?
    let range: ClosedRange<Int>?

    init(map: LibraryMap, visible: [Int32], fullPeak: Double, strata: StrataModel? = nil, colorStrata: StrataModel? = nil, range: ClosedRange<Int>? = nil) {
        self.colorStrata = colorStrata
        self.map = map
        self.visible = visible
        self.strata = strata
        self.range = range
        field = DensityField(items: map.items, visible: visible, fullPeak: fullPeak)
        counts = map.regions.counts(items: map.items, visible: visible)
        spatial = SpatialIndex(items: map.items, visible: visible)
        pictures = visible.filter { map.items[Int($0)].thumb != nil }
            .sorted { map.items[Int($0)].resonance > map.items[Int($1)].resonance }
    }
}

/// How pictures show: gray by default, in full color on hover.
enum ImageMode: String, CaseIterable, Sendable {
    case color, gray, dither

    var label: String { self == .dither ? "1-bit" : rawValue }
}

/// Keep in step with `Uniforms` in Terrain.metal.
struct Uniforms {
    var ground: SIMD4<Float>
    var ink: SIMD4<Float>
    var hair: SIMD4<Float>
    var surface: SIMD4<Float>
    var drawable: SIMD2<Float>
    var translate: SIMD2<Float>
    var scale: Float
    var k: Float
    var origin: Float
    var cell: Float
    var dotRadius: Float
}

private struct Marker {
    var position: SIMD2<Float>
    var base: Float
    var mine: Float
}

struct ThumbDraw {
    var center: SIMD2<Float>
    var half: SIMD2<Float>
    var frame: Float
    var mine: Float
    var mode: Float
    var hasImage: Float
    var nearest: Float
}

struct Bar {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
}

private struct LabelDraw {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var alpha: Float
}

/// One thumbnail to draw this frame, in points.
struct ThumbPlacement {
    let center: CGPoint
    let size: CGSize
    let frame: Double
    let mine: Bool
    let texture: MTLTexture?
    let mode: ImageMode
    /// Drawn larger than its pixels, in 1-bit: keep the dots square.
    let nearest: Bool
}

/// One region name to draw this frame.
struct LabelPlacement {
    let origin: CGPoint
    let size: CGSize
    let texture: MTLTexture
    let alpha: Double
}

/// Everything on top of the terrain.
struct TerrainOverlay {
    var thumbs: [ThumbPlacement] = []
    var dots = false
    /// The selection's viewfinder: its center and half its width, in points.
    var viewfinder: (center: CGPoint, half: Double)?
    /// The rectangle being drawn to zoom into, in points.
    var zoomBox: CGRect?
    var labels: [LabelPlacement] = []
}

/// Draws the terrain with one full-view pass, an instanced pass of markers, and then
/// pictures and names. Nothing runs between frames: the view redraws only when something changes.
@MainActor
final class TerrainRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let terrainPipeline: MTLRenderPipelineState
    private let markerPipeline: MTLRenderPipelineState
    private let thumbPipeline: MTLRenderPipelineState
    private let barPipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
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

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool, premultiplied: Bool = true) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = view.colorPixelFormat
            if blended {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        terrainPipeline = try pipeline("terrainVertex", "terrainFragment", blended: false)
        markerPipeline = try pipeline("markerVertex", "markerFragment", blended: true)
        thumbPipeline = try pipeline("thumbVertex", "thumbFragment", blended: false)
        barPipeline = try pipeline("barVertex", "barFragment", blended: false)
        labelPipeline = try pipeline("labelVertex", "labelFragment", blended: true)
    }

    func setScene(_ scene: TerrainScene?) {
        guard let scene else {
            field = nil
            markers = nil
            markerCount = 0
            return
        }
        // Filtering rebuilds the field often, and the grid's size never changes.
        if field?.width != scene.field.width || field?.height != scene.field.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: scene.field.width, height: scene.field.height, mipmapped: false)
            descriptor.usage = .shaderRead
            field = device.makeTexture(descriptor: descriptor)
        }
        scene.field.elevation.withUnsafeBytes { bytes in
            field?.replace(region: MTLRegionMake2D(0, 0, scene.field.width, scene.field.height),
                           mipmapLevel: 0, withBytes: bytes.baseAddress!,
                           bytesPerRow: scene.field.width * MemoryLayout<Float>.stride)
        }

        let instances = scene.visible.map { index -> Marker in
            let item = scene.map.items[Int(index)]
            return Marker(position: SIMD2(item.x, item.y),
                          base: TerrainStyle.markerBase(resonance: item.resonance),
                          mine: item.mine ? 1 : 0)
        }
        markers = instances.isEmpty ? nil : device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<Marker>.stride)
        markerCount = instances.count
    }

    func draw(in view: MTKView, transform: MapTransform, theme: Theme, overlay: TerrainOverlay) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        let ground = theme.ground.simd
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(ground.x), green: Double(ground.y),
                                                            blue: Double(ground.z), alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        let scale = view.bounds.width > 0 ? Float(size.width / view.bounds.width) : 1
        var uniforms = Uniforms(ground: ground, ink: theme.ink.simd, hair: theme.hair.simd, surface: theme.surface.simd,
                                drawable: SIMD2(Float(size.width), Float(size.height)),
                                translate: SIMD2(Float(transform.x), Float(transform.y)),
                                scale: scale, k: Float(transform.k),
                                origin: Float(DensityField.origin), cell: Float(DensityField.cellSize),
                                dotRadius: overlay.dots ? TerrainStyle.dotRadius : 0)
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

        if !overlay.thumbs.isEmpty {
            encoder.setRenderPipelineState(thumbPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            for thumb in overlay.thumbs {
                var data = ThumbDraw(center: SIMD2(Float(thumb.center.x), Float(thumb.center.y)) * scale,
                                     half: SIMD2(Float(thumb.size.width), Float(thumb.size.height)) * scale / 2,
                                     frame: Float(thumb.frame) * scale,
                                     mine: thumb.mine ? 1 : 0,
                                     mode: thumb.mode == .color ? 0 : 1,
                                     hasImage: thumb.texture == nil ? 0 : 1,
                                     nearest: thumb.nearest ? 1 : 0)
                encoder.setVertexBytes(&data, length: MemoryLayout<ThumbDraw>.stride, index: 1)
                encoder.setFragmentBytes(&data, length: MemoryLayout<ThumbDraw>.stride, index: 1)
                encoder.setFragmentTexture(thumb.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        if let finder = overlay.viewfinder {
            let bars = Self.viewfinder(center: finder.center, half: finder.half, scale: Double(scale))
            encoder.setRenderPipelineState(barPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            bars.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bars.count)
        }

        if !overlay.labels.isEmpty {
            encoder.setRenderPipelineState(labelPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            for label in overlay.labels {
                // On whole pixels, so the text stays as crisp as it was drawn.
                let origin = SIMD2(Float(label.origin.x), Float(label.origin.y)) * scale
                var data = LabelDraw(origin: origin.rounded(.toNearestOrAwayFromZero),
                                     size: SIMD2(Float(label.texture.width), Float(label.texture.height)),
                                     alpha: Float(label.alpha))
                encoder.setVertexBytes(&data, length: MemoryLayout<LabelDraw>.stride, index: 1)
                encoder.setFragmentTexture(label.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        if let box = overlay.zoomBox {
            let bars = Self.outline(box, scale: Double(scale))
            encoder.setRenderPipelineState(barPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            bars.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bars.count)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// Four sides, one point wide, in pixels.
    static func outline(_ box: CGRect, scale: Double) -> [Bar] {
        let x = Float((box.minX * scale).rounded()), y = Float((box.minY * scale).rounded())
        let width = Float((box.width * scale).rounded()), height = Float((box.height * scale).rounded())
        let weight = Float(scale)
        return [
            Bar(origin: SIMD2(x, y), size: SIMD2(width, weight)),
            Bar(origin: SIMD2(x, y + height - weight), size: SIMD2(width, weight)),
            Bar(origin: SIMD2(x, y), size: SIMD2(weight, height)),
            Bar(origin: SIMD2(x + width - weight, y), size: SIMD2(weight, height)),
        ]
    }

    /// Four corners, two bars each, in pixels.
    static func viewfinder(center: CGPoint, half: Double, scale: Double) -> [Bar] {
        let arm = max(5, half * 0.35) * scale, weight = 2 * scale, reach = half * scale
        let cx = center.x * scale, cy = center.y * scale
        var bars: [Bar] = []
        for (sx, sy) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
            let px = cx + sx * reach, py = cy + sy * reach
            let horizontal = Bar(origin: SIMD2(Float(sx < 0 ? px : px - arm), Float(py - weight / 2)),
                                 size: SIMD2(Float(arm), Float(weight)))
            let vertical = Bar(origin: SIMD2(Float(px - weight / 2), Float(sy < 0 ? py : py - arm)),
                               size: SIMD2(Float(weight), Float(arm)))
            bars += [horizontal, vertical]
        }
        return bars
    }

    private func setBytes(_ values: [Float], _ encoder: MTLRenderCommandEncoder, index: Int) {
        values.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: index) }
    }
}

enum RendererError: LocalizedError {
    case unavailable
    var errorDescription: String? { "This Mac's graphics hardware couldn't be set up for Metal." }
}
