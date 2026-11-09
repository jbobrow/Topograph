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
    /// The weather over the land on the field's grid, when clouds are showing (`Clouds.weather`).
    let weather: [Float]?
    /// The end of the season the weather is for.
    let weatherEnd: Int?

    init(map: LibraryMap, visible: [Int32], fullPeak: Double, strata: StrataModel? = nil, colorStrata: StrataModel? = nil, range: ClosedRange<Int>? = nil,
         clouds: Bool = false) {
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
        // The season up to the end of the time shown: with all time, the latest.
        weatherEnd = range?.upperBound ?? map.clouds.searches.last?.time
        weather = clouds ? weatherEnd.flatMap { map.clouds.weather(endingAt: $0) } : nil
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
    /// Metal's depth, for a picture standing in 3D.
    var depth: Float = 0
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
    /// Metal's depth where it stands, in 3D, so the ground in front of it hides it.
    var depth: Float = 0
}

/// One region name to draw this frame.
struct LabelPlacement {
    let origin: CGPoint
    let size: CGSize
    let texture: MTLTexture
    let alpha: Double
    /// The region it names.
    var region: Int? = nil
}

/// The open item's picture, lifted off the map or the wheel and drifting above its place, so
/// you can see where it is however far out you are. A rule ties it to that place.
enum FloatingPicture {
    /// Slow enough to read as drifting, and to go easy on the machine while a panel stays open.
    static let period = 2.8
    /// How close to the edges of what's clear of the side panel an open item is kept.
    static let margin = 96.0

    /// Where it goes this moment, in points. `long` is what it would be drawn at otherwise.
    static func layout(place: CGPoint, aspect: Double, long: Double, bounds: CGSize) -> (center: CGPoint, size: CGSize, stem: CGRect) {
        let long = max(long * 1.2, 84)
        let size = aspect >= 1 ? CGSize(width: long, height: long / aspect) : CGSize(width: long * aspect, height: long)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let drift = still ? 0 : sin(CACurrentMediaTime() * 2 * .pi / period) * 3
        // Above its place, or below when there's no room above.
        let lift = size.height / 2 + 26 + drift
        let above = place.y - lift - size.height / 2 >= 8
        let y = above ? place.y - lift : place.y + lift
        // Clear of the side panel and the window's edge, while the rule stays on its place.
        let right = bounds.width - DetailPanel.width - size.width / 2 - 8
        let x = min(max(place.x, size.width / 2 + 8), max(right, size.width / 2 + 8))
        let near = above ? y + size.height / 2 : y - size.height / 2
        let top = min(near, place.y), bottom = max(near, place.y)
        return (CGPoint(x: x, y: y), size, CGRect(x: place.x - 0.5, y: top, width: 1, height: max(bottom - top, 0)))
    }

    /// How far to move so an item opening the side panel isn't left under it or off the edge.
    static func correction(for place: CGPoint, bounds: CGSize) -> CGSize {
        let right = bounds.width - DetailPanel.width - margin
        let dx = place.x > right ? right - place.x : place.x < margin ? margin - place.x : 0
        let bottom = bounds.height - margin
        let dy = place.y > bottom ? bottom - place.y : place.y < margin ? margin - place.y : 0
        return CGSize(width: dx, height: dy)
    }

    static func stemBar(_ stem: CGRect, scale: Float) -> Bar {
        Bar(origin: SIMD2(Float((stem.minX * Double(scale)).rounded()), Float(stem.minY) * scale),
            size: SIMD2(Float(stem.width) * scale, Float(stem.height) * scale))
    }
}

/// Everything on top of the terrain.
struct TerrainOverlay {
    var thumbs: [ThumbPlacement] = []
    var dots = false
    /// The selection's viewfinder: its center and half its width, in points.
    var viewfinder: (center: CGPoint, half: Double)?
    /// The selection's picture, floating over its place, and the rule that ties them, in points.
    var floating: ThumbPlacement?
    var stem: CGRect?
    /// The rectangle being drawn to zoom into, in points.
    var zoomBox: CGRect?
    var labels: [LabelPlacement] = []
    /// In 3D, the rules from each name down to the ground it names, in points.
    var stems: [(from: CGPoint, to: CGPoint, alpha: Double)] = []
}

/// Keep in step with `Relief` in Terrain.metal.
private struct ReliefUniforms {
    var viewProjection: simd_float4x4
    var eye: SIMD4<Float>
    var sun: SIMD4<Float>
    var height: Float
    var exponent: Float
    var fogNear: Float
    var fogFar: Float
    var focal: Float
    var thumbnailZoom: Float
    var dotRadius: Float
    var gridStep: Float
    var side: UInt32
    var extent: Float
    var center: SIMD2<Float>
}

/// The terrain seen in 3D this frame.
struct ReliefFrame {
    let camera: OrbitCamera
    let projection: Projection
    /// How far the relief has risen out of the flat map, 0 to 1.
    let rise: Float
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
    private let reliefPipeline: MTLRenderPipelineState
    private let groundPipeline: MTLRenderPipelineState
    private let reliefMarkerPipeline: MTLRenderPipelineState
    private let cloudPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    /// Depth for the relief: tested and written by the ground, only tested by what stands on
    /// it, and ignored by everything on top.
    private let solid: MTLDepthStencilState
    private let standing: MTLDepthStencilState
    private let flat: MTLDepthStencilState
    private var field: MTLTexture?
    /// The weather on the same grid, while clouds show.
    private var weather: MTLTexture?
    /// What the shaders read for weather when there is none: one cell of clear sky.
    private lazy var clearSky: MTLTexture? = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)
        var zero: Float = 0
        texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: MemoryLayout<Float>.stride)
        return texture
    }()
    /// The relief's triangles, two to a cell of the field.
    private var mesh: MTLBuffer?
    private var meshCount = 0
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
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
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
        reliefPipeline = try pipeline("reliefVertex", "reliefFragment", blended: false)
        groundPipeline = try pipeline("groundVertex", "reliefFragment", blended: false)
        reliefMarkerPipeline = try pipeline("reliefMarkerVertex", "markerFragment", blended: true)
        cloudPipeline = try pipeline("cloudVertex", "cloudFragment", blended: true)
        linePipeline = try pipeline("paletteLineVertex", "paletteLineFragment", blended: true)

        func depth(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = write
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else { throw RendererError.unavailable }
            return state
        }
        solid = try depth(.less, write: true)
        standing = try depth(.lessEqual, write: false)
        flat = try depth(.always, write: false)
    }

    func setScene(_ scene: TerrainScene?) {
        guard let scene else {
            field = nil
            weather = nil
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
            makeMesh(width: scene.field.width, height: scene.field.height)
        }
        scene.field.elevation.withUnsafeBytes { bytes in
            field?.replace(region: MTLRegionMake2D(0, 0, scene.field.width, scene.field.height),
                           mipmapLevel: 0, withBytes: bytes.baseAddress!,
                           bytesPerRow: scene.field.width * MemoryLayout<Float>.stride)
        }
        if let values = scene.weather {
            if weather?.width != scene.field.width || weather?.height != scene.field.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r32Float, width: scene.field.width, height: scene.field.height, mipmapped: false)
                descriptor.usage = .shaderRead
                weather = device.makeTexture(descriptor: descriptor)
            }
            values.withUnsafeBytes { bytes in
                weather?.replace(region: MTLRegionMake2D(0, 0, scene.field.width, scene.field.height),
                                 mipmapLevel: 0, withBytes: bytes.baseAddress!,
                                 bytesPerRow: scene.field.width * MemoryLayout<Float>.stride)
            }
        } else {
            weather = nil
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

    private func makeMesh(width: Int, height: Int) {
        var indices: [UInt32] = []
        indices.reserveCapacity((width - 1) * (height - 1) * 6)
        for j in 0..<(height - 1) {
            for i in 0..<(width - 1) {
                let a = UInt32(j * width + i), b = a + 1, c = a + UInt32(width), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        mesh = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride)
        meshCount = indices.count
    }

    func draw(in view: MTKView, transform: MapTransform, theme: Theme, overlay: TerrainOverlay, relief: ReliefFrame? = nil) {
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
                                // In 3D, markers are sized by their depth, and go without outlines, which crowd at a distance.
                                dotRadius: overlay.dots || relief != nil ? TerrainStyle.dotRadius : 0)
        let uniformLength = MemoryLayout<Uniforms>.stride

        if let relief {
            drawRelief(relief, encoder: encoder, uniforms: &uniforms)
        } else if let field {
            var levels = UInt32(TerrainStyle.levels)
            encoder.setRenderPipelineState(terrainPipeline)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            setBytes(TerrainStyle.thresholds, encoder, index: 1)
            setBytes(TerrainStyle.ditherDensity, encoder, index: 2)
            setBytes(TerrainStyle.bayer, encoder, index: 3)
            encoder.setFragmentBytes(&levels, length: MemoryLayout<UInt32>.stride, index: 4)
            encoder.setFragmentTexture(field, index: 0)
            encoder.setFragmentTexture(weather ?? clearSky, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        if relief == nil, let markers, markerCount > 0 {
            encoder.setRenderPipelineState(markerPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            encoder.setVertexBuffer(markers, offset: 0, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: markerCount)
        }

        if !overlay.thumbs.isEmpty {
            if relief != nil { encoder.setDepthStencilState(standing) }
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
                                     nearest: thumb.nearest ? 1 : 0,
                                     depth: thumb.depth)
                encoder.setVertexBytes(&data, length: MemoryLayout<ThumbDraw>.stride, index: 1)
                encoder.setFragmentBytes(&data, length: MemoryLayout<ThumbDraw>.stride, index: 1)
                encoder.setFragmentTexture(thumb.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        // Everything from here floats above the ground, the names like clouds.
        encoder.setDepthStencilState(flat)

        if !overlay.stems.isEmpty {
            let lines = overlay.stems.map {
                LineDraw(from: SIMD2(Float($0.from.x), Float($0.from.y)) * scale, to: SIMD2(Float($0.to.x), Float($0.to.y)) * scale,
                         width: scale, alpha: 0.55 * Float($0.alpha))
            }
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            lines.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
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

        if let stem = overlay.stem {
            let bars = [FloatingPicture.stemBar(stem, scale: scale)]
            encoder.setRenderPipelineState(barPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            bars.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bars.count)
        }

        if let thumb = overlay.floating {
            encoder.setRenderPipelineState(thumbPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
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

    /// The ground plane, the relief over it, the markers standing on it, and the clouds over them.
    private func drawRelief(_ relief: ReliefFrame, encoder: MTLRenderCommandEncoder, uniforms: inout Uniforms) {
        guard let field, let mesh else { return }
        let camera = relief.camera, projection = relief.projection
        let sun = simd_normalize(SIMD3<Float>(-0.55, 0.75, -0.45))
        let extent = Float(projection.far * 0.9)
        var r = ReliefUniforms(viewProjection: projection.viewProjection,
                               eye: SIMD4(projection.eye, 1), sun: SIMD4(sun, 0),
                               height: Relief.height * relief.rise, exponent: Relief.exponent,
                               fogNear: Float(camera.distance * 1.2), fogFar: Float(camera.distance * 3 + 400),
                               focal: Float(projection.focal), thumbnailZoom: Float(TerrainStyle.thumbnailZoom),
                               dotRadius: TerrainStyle.dotRadius, gridStep: 100, side: UInt32(field.width),
                               extent: extent, center: SIMD2(Float(camera.x), Float(camera.y)))
        let length = MemoryLayout<ReliefUniforms>.stride
        let uniformLength = MemoryLayout<Uniforms>.stride
        var levels = UInt32(TerrainStyle.levels)

        encoder.setDepthStencilState(solid)
        encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
        encoder.setVertexBytes(&r, length: length, index: 1)
        encoder.setVertexTexture(field, index: 0)
        encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
        setBytes(TerrainStyle.thresholds, encoder, index: 1)
        setBytes(TerrainStyle.ditherDensity, encoder, index: 2)
        setBytes(TerrainStyle.bayer, encoder, index: 3)
        encoder.setFragmentBytes(&levels, length: MemoryLayout<UInt32>.stride, index: 4)
        encoder.setFragmentBytes(&r, length: length, index: 5)
        encoder.setFragmentTexture(field, index: 0)
        encoder.setFragmentTexture(weather ?? clearSky, index: 1)

        encoder.setRenderPipelineState(groundPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.setRenderPipelineState(reliefPipeline)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: meshCount, indexType: .uint32, indexBuffer: mesh, indexBufferOffset: 0)

        if let markers, markerCount > 0 {
            encoder.setDepthStencilState(standing)
            encoder.setRenderPipelineState(reliefMarkerPipeline)
            encoder.setVertexBuffer(markers, offset: 0, index: 1)
            encoder.setVertexBytes(&r, length: length, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: markerCount)
        }
        // The clouds above, after the markers so that what's under a cloud shows between its dots,
        // and before the pictures, which they hide where the dots fall.
        if weather != nil {
            encoder.setDepthStencilState(solid)
            encoder.setRenderPipelineState(cloudPipeline)
            encoder.setVertexBytes(&r, length: length, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Self.cloudSlices)
        }
        encoder.setDepthStencilState(flat)
    }

    /// Keep in step with `cloudSlices` in Terrain.metal.
    private static let cloudSlices = 4

    /// How high the lowest of the clouds floats. Keep in step with `cloudAltitude` in Terrain.metal.
    static func cloudAltitude(rise: Float) -> Float {
        Relief.height * rise * 1.35 + 1.5
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
