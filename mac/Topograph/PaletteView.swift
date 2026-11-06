import AppKit
import MetalKit
import SwiftUI
import TopographCore

/// Lets the keys and menu commands reach the palette.
@MainActor
final class PaletteController {
    fileprivate weak var view: PaletteMTKView?

    func zoomIn() { view?.zoomFromCenter(by: 1.8) }
    func zoomOut() { view?.zoomFromCenter(by: 1 / 1.8) }
    func fit() { view?.fit() }
    func center(x: Double, y: Double) { view?.center(x: x, y: y) }
    func setCylinder(_ on: Bool) { view?.setCylinder(on) }
    var pointerIsOnMinimap: Bool {
        get { view?.pointerIsOnMinimap ?? false }
        set { view?.pointerIsOnMinimap = newValue }
    }
}

struct PaletteCanvas: NSViewRepresentable {
    let space: PaletteSpace?
    let scene: TerrainScene?
    let root: URL?
    let controller: PaletteController
    let camera: PaletteCamera
    let selected: Int32?
    let imageMode: ImageMode
    var onCamera: (PaletteCamera, CGSize) -> Void
    var onHover: (Hover?) -> Void
    var onPick: (Int32) -> Void

    func makeNSView(context: Context) -> PaletteMTKView {
        let view = PaletteMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        controller.view = view
        view.start(camera: camera)
        return view
    }

    func updateNSView(_ view: PaletteMTKView, context: Context) {
        controller.view = view
        view.onCamera = onCamera
        view.onHover = onHover
        view.onPick = onPick
        view.sceneSource = { scene }
        view.show(space: space, scene: scene, root: root, selected: selected, imageMode: imageMode)
    }
}

/// One dot; keep in step with `PaletteDot` in Terrain.metal.
private struct DotDraw {
    var center: SIMD2<Float>
    var half: Float
    var pad: Float = 0
    var color: SIMD4<Float>
}

/// One guide line; keep in step with `PaletteLine` in Terrain.metal.
private struct LineDraw {
    var from: SIMD2<Float>
    var to: SIMD2<Float>
    var width: Float
    var alpha: Float
}

/// Pictures by color, on a flat wheel or standing as a cylinder. Moves like the terrain:
/// a drag draws a rectangle to zoom into, or turns the cylinder, and space and drag moves it.
final class PaletteMTKView: MTKView, MTKViewDelegate {
    private enum Drag {
        case pan(last: CGPoint)
        case box(start: CGPoint, now: CGPoint?)
        case turn(last: CGPoint, moved: Bool)
    }

    private var queue: MTLCommandQueue?
    private var dotPipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var thumbPipeline: MTLRenderPipelineState?
    private var barPipeline: MTLRenderPipelineState?
    private var thumbnails: ThumbnailStore?

    private var space: PaletteSpace?
    private var showing: [Int32] = []
    private var dots: [PaletteSpace.Dot] = []
    private var dotsAreCurrent = false
    private var shownScene: UUID?
    private var root: URL?
    private var selected: Int32?
    private var imageMode = ImageMode.color
    private var theme = Theme.light

    private var camera = PaletteCamera()
    private var animation: (from: PaletteCamera, to: PaletteCamera, start: CFTimeInterval, duration: CFTimeInterval)?
    private var link: CADisplayLink?
    private var lastPublished: (camera: PaletteCamera, size: CGSize)?

    private var drag: Drag?
    private var spaceHeld = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var tracking: NSTrackingArea?
    private var hovered: Int32?
    var pointerIsOnMinimap = false

    var onCamera: ((PaletteCamera, CGSize) -> Void)?
    var onHover: ((Hover?) -> Void)?
    var onPick: ((Int32) -> Void)?

    private static let thumbnailZoom = 2.5
    private static let thumbnailLimit = 900

    func start(camera: PaletteCamera) {
        self.camera = camera
        colorPixelFormat = .bgra8Unorm
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        updateTheme()
        guard let device, let library = try? device.makeDefaultLibrary(bundle: .main), let queue = device.makeCommandQueue() else { return }
        self.queue = queue
        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = colorPixelFormat
            if blended {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        dotPipeline = pipeline("paletteDotVertex", "paletteDotFragment", blended: false)
        linePipeline = pipeline("paletteLineVertex", "paletteLineFragment", blended: true)
        thumbPipeline = pipeline("thumbVertex", "thumbFragment", blended: false)
        barPipeline = pipeline("barVertex", "barFragment", blended: false)
    }

    func show(space: PaletteSpace?, scene: TerrainScene?, root: URL?, selected: Int32?, imageMode: ImageMode) {
        if selected != self.selected || imageMode != self.imageMode { needsDisplay = true }
        self.selected = selected
        self.imageMode = imageMode
        // The places are worked out after the view first appears.
        let spaceArrived = self.space == nil && space != nil
        self.space = space
        if root != self.root, let root, let device, let queue {
            self.root = root
            let store = ThumbnailStore(device: device, queue: queue, root: root, budget: 256 * 1024 * 1024)
            store.onReady = { [weak self] in self?.needsDisplay = true }
            thumbnails = store
        }
        guard scene?.id != shownScene || spaceArrived else { return }
        shownScene = scene?.id
        showing = scene.flatMap { scene in space?.showing(scene.visible) } ?? []
        dotsAreCurrent = false
        needsDisplay = true
    }

    private func updateDots() {
        guard !dotsAreCurrent, let space else { return }
        dots = space.project(showing, camera: camera, size: bounds.size)
        dotsAreCurrent = true
    }

    private func cameraChanged() {
        dotsAreCurrent = false
        needsDisplay = true
    }

    // MARK: Drawing

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable, let space,
              let commands = queue?.makeCommandBuffer() else { return }
        updateDots()
        publishCamera()
        let ground = theme.ground.simd
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(ground.x), green: Double(ground.y), blue: Double(ground.z), alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = drawableSize
        let scale = bounds.width > 0 ? Float(size.width / bounds.width) : 1
        var uniforms = Uniforms(ground: ground, ink: theme.ink.simd, hair: theme.hair.simd, surface: theme.surface.simd,
                                drawable: SIMD2(Float(size.width), Float(size.height)),
                                translate: .zero, scale: scale, k: 1, origin: 0, cell: 1, dotRadius: 0)
        let uniformLength = MemoryLayout<Uniforms>.stride

        let lines = guideLines(scale: scale)
        if let linePipeline, !lines.isEmpty, let buffer = device?.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<LineDraw>.stride) {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lines.count)
        }

        let half = Float(min(1.8 * camera.zoom.squareRoot(), 5))
        let instances = dots.map { dot -> DotDraw in
            let color = space.places[Int(dot.place)].color
            return DotDraw(center: dot.point * scale, half: half * dot.scale * scale, color: SIMD4(color, 1))
        }
        if let dotPipeline, !instances.isEmpty, let buffer = device?.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<DotDraw>.stride) {
            encoder.setRenderPipelineState(dotPipeline)
            encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }

        drawThumbnails(encoder, space: space, uniforms: &uniforms, scale: scale)

        if let selected, let place = space.place(ofItem: selected), let barPipeline {
            let p = space.position(of: space.places[Int(place)], solid: camera.solid)
            let at = camera.project(x: p.x, y: p.y, z: p.z, size: bounds.size)
            let reach = camera.zoom >= Self.thumbnailZoom ? thumbnailLength * 0.5 + 8 : 10
            draw(bars: TerrainRenderer.viewfinder(center: at.point, half: reach, scale: Double(scale)), encoder, barPipeline, &uniforms)
        }
        if let box = zoomBox, let barPipeline {
            draw(bars: TerrainRenderer.outline(box, scale: Double(scale)), encoder, barPipeline, &uniforms)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func draw(bars: [Bar], _ encoder: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState, _ uniforms: inout Uniforms) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        bars.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bars.count)
    }

    private var thumbnailLength: Double { min(150, 6 * pow(camera.zoom, 0.9)) }

    /// The most resonant pictures in view, as they fall front to back.
    private func drawThumbnails(_ encoder: MTLRenderCommandEncoder, space: PaletteSpace, uniforms: inout Uniforms, scale: Float) {
        guard camera.zoom >= Self.thumbnailZoom, let thumbnails, let thumbPipeline, let map = scene?.map else { return }
        let margin = Float(thumbnailLength)
        let width = Float(bounds.width), height = Float(bounds.height)
        var chosen: Set<Int32> = []
        var byPlace: [Int32: PaletteSpace.Dot] = [:]
        byPlace.reserveCapacity(dots.count)
        for dot in dots { byPlace[dot.place] = dot }
        for place in showing {
            guard let dot = byPlace[place], dot.point.x > -margin, dot.point.y > -margin,
                  dot.point.x < width + margin, dot.point.y < height + margin else { continue }
            chosen.insert(place)
            if chosen.count == Self.thumbnailLimit { break }
        }
        encoder.setRenderPipelineState(thumbPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let dither = imageMode == .dither
        thumbnails.beginFrame()
        for dot in dots where chosen.contains(dot.place) {
            let item = map.items[Int(space.places[Int(dot.place)].index)]
            guard let path = item.thumb else { continue }
            let long = thumbnailLength * TerrainStyle.thumbnailScale(resonance: item.resonance) * Double(dot.scale)
            guard let texture = thumbnails.texture(item: space.places[Int(dot.place)].index, path: path, pixels: long * Double(scale), dither: dither) else { continue }
            let aspect = Double(item.aspect ?? 1)
            let halfSize = aspect >= 1 ? SIMD2(long, long / aspect) / 2 : SIMD2(long * aspect, long) / 2
            var data = ThumbDraw(center: dot.point * scale, half: SIMD2(Float(halfSize.x), Float(halfSize.y)) * scale,
                                 frame: scale, mine: item.mine ? 1 : 0, mode: imageMode == .color ? 0 : 1, hasImage: 1,
                                 nearest: dither && long * Double(scale) >= Double(texture.width) ? 1 : 0)
            encoder.setVertexBytes(&data, length: MemoryLayout<ThumbDraw>.stride, index: 1)
            encoder.setFragmentBytes(&data, length: MemoryLayout<ThumbDraw>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        thumbnails.endFrame()
    }

    /// Rings at the top, middle and bottom, the axis, and the two sides. On the flat wheel
    /// the rings fall together into one.
    private func guideLines(scale: Float) -> [LineDraw] {
        let size = bounds.size
        func pixel(_ x: Double, _ y: Double, _ z: Double) -> SIMD2<Float> {
            let at = camera.project(x: x, y: y, z: z, size: size).point
            return SIMD2(Float(at.x), Float(at.y)) * scale
        }
        let height = PaletteCamera.cylinderHeight * camera.solid
        var lines: [LineDraw] = []
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ alpha: Float) {
            lines.append(LineDraw(from: a, to: b, width: scale, alpha: alpha))
        }
        let steps = 96
        for (z, alpha) in [(height, Float(0.32)), (0, Float(0.12)), (-height, Float(0.32))] where camera.solid > 0 || z == 0 {
            let strength: Float = camera.solid > 0 ? alpha : 0.32
            var last = pixel(1.06, 0, z)
            for step in 1...steps {
                let angle = Double(step) / Double(steps) * 2 * .pi
                let next = pixel(cos(angle) * 1.06, sin(angle) * 1.06, z)
                line(last, next, strength)
                last = next
            }
        }
        if camera.solid > 0 {
            line(pixel(0, 0, -height), pixel(0, 0, height), 0.2)
            let sideX = cos(camera.yaw) * 1.06, sideY = -sin(camera.yaw) * 1.06
            line(pixel(sideX, sideY, -height), pixel(sideX, sideY, height), 0.32)
            line(pixel(-sideX, -sideY, -height), pixel(-sideX, -sideY, height), 0.32)
        }
        return lines
    }

    private func publishCamera() {
        guard lastPublished?.camera != camera || lastPublished?.size != bounds.size else { return }
        lastPublished = (camera, bounds.size)
        let (notify, camera, size) = (onCamera, camera, bounds.size)
        DispatchQueue.main.async { notify?(camera, size) }
    }

    private var scene: TerrainScene? { sceneSource?() }
    var sceneSource: (() -> TerrainScene?)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cameraChanged()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTheme()
    }

    private func updateTheme() {
        theme = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        needsDisplay = true
    }

    // MARK: Moving

    fileprivate func zoomFromCenter(by factor: Double) {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        animate(to: (animation?.to ?? camera).zoomed(by: factor, around: center, size: bounds.size), duration: 0.25)
    }

    fileprivate func fit() {
        var next = animation?.to ?? camera
        next.zoom = 1
        next.panX = 0
        next.panY = 0
        animate(to: next, duration: 0.4)
    }

    fileprivate func center(x: Double, y: Double) {
        apply(camera.centered(onX: x, y: y, size: bounds.size))
    }

    /// Standing up or lying down, the wheel turns to face front on the way.
    fileprivate func setCylinder(_ on: Bool) {
        var next = animation?.to ?? camera
        next.solid = on ? 1 : 0
        next.pitch = on ? PaletteCamera.cylinderPitch : 0
        // The short way round to no turn at all.
        if !on {
            var yaw = camera.yaw.truncatingRemainder(dividingBy: 2 * .pi)
            if yaw > .pi { yaw -= 2 * .pi } else if yaw < -.pi { yaw += 2 * .pi }
            camera.yaw = yaw
            next.yaw = 0
        }
        animate(to: next, duration: 0.7)
    }

    private func apply(_ next: PaletteCamera) {
        stopAnimating()
        camera = next
        clearHover()
        cameraChanged()
    }

    private func animate(to target: PaletteCamera, duration: CFTimeInterval) {
        clearHover()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAnimating()
            camera = target
            cameraChanged()
            return
        }
        animation = (camera, target, CACurrentMediaTime(), duration)
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step() {
        guard let animation else { return stopAnimating() }
        let t = min((CACurrentMediaTime() - animation.start) / animation.duration, 1)
        camera = t < 1 ? animation.from.interpolated(to: animation.to, t: t * t * (3 - 2 * t)) : animation.to
        cameraChanged()
        if t >= 1 { stopAnimating() }
    }

    private func stopAnimating() {
        animation = nil
        link?.invalidate()
        link = nil
    }

    // MARK: Keyboard and pointer

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else {
            stopAnimating()
            return setSpaceHeld(false)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSpaceHeld(false) }
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        if event.keyCode == 53, event.type == .keyDown, zoomBox != nil {
            drag = nil
            needsDisplay = true
            return nil
        }
        guard event.keyCode == 49 else { return event }
        if event.type == .keyUp {
            guard spaceHeld else { return event }
            setSpaceHeld(false)
            return nil
        }
        guard !(window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        if event.isARepeat, !spaceHeld { return nil }
        setSpaceHeld(true)
        return nil
    }

    private func setSpaceHeld(_ held: Bool) {
        guard held != spaceHeld else { return }
        spaceHeld = held
        if held { clearHover() }
        updateCursor()
    }

    private var isCylinder: Bool { (animation?.to.solid ?? camera.solid) > 0.5 }

    private var cursor: NSCursor {
        switch drag {
        case .pan, .turn: return .closedHand
        default: return spaceHeld || isCylinder ? .openHand : .crosshair
        }
    }

    private func updateCursor() {
        window?.invalidateCursorRects(for: self)
        if pointerIsOverCanvas { cursor.set() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    private var viewUnderPointer: NSView? {
        guard let window, let content = window.contentView else { return nil }
        let point = window.mouseLocationOutsideOfEventStream
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }

    private var pointerIsOverCanvas: Bool { viewUnderPointer === self }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func location(of event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    /// The nearest picture to a point, front ones first.
    private func itemIndex(at point: CGPoint) -> Int32? {
        guard let space else { return nil }
        updateDots()
        let target = SIMD2(Float(point.x), Float(point.y))
        let reach = Float(camera.zoom >= Self.thumbnailZoom ? thumbnailLength * 0.5 : 6)
        var best: Int32?
        var bestDistance = reach * reach
        for dot in dots.reversed() {
            let d = dot.point - target
            let distance = d.x * d.x + d.y * d.y
            if distance < bestDistance {
                bestDistance = distance
                best = space.places[Int(dot.place)].index
            }
        }
        return best
    }

    private func clearHover() {
        guard hovered != nil else { return }
        hovered = nil
        onHover?(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        guard pointerIsOverCanvas else {
            let under = viewUnderPointer
            if !pointerIsOnMinimap, !(under is NSText), !(under is NSTextField) { NSCursor.arrow.set() }
            return clearHover()
        }
        if spaceHeld {
            NSCursor.openHand.set()
            return
        }
        let point = location(of: event)
        let index = itemIndex(at: point)
        if index != nil { NSCursor.pointingHand.set() } else { cursor.set() }
        guard let index else { return clearHover() }
        hovered = index
        onHover?(Hover(item: index, location: point, mapSize: bounds.size))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    private var zoomBox: CGRect? {
        guard case .box(let start, let now?) = drag else { return nil }
        let box = CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
        return box.intersection(bounds)
    }

    override func mouseDown(with event: NSEvent) {
        stopAnimating()
        clearHover()
        let point = location(of: event)
        if spaceHeld {
            drag = .pan(last: point)
        } else if isCylinder {
            drag = .turn(last: point, moved: false)
        } else {
            drag = .box(start: point, now: nil)
        }
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = location(of: event)
        switch drag {
        case .pan(let last):
            apply(camera.panned(dx: now.x - last.x, dy: now.y - last.y))
            drag = .pan(last: now)
        case .turn(let last, let moved):
            let dx = now.x - last.x, dy = now.y - last.y
            guard moved || abs(dx) + abs(dy) > 3 else { return }
            var next = camera
            next.yaw -= dx * 0.008
            next.pitch = min(max(next.pitch - dy * 0.006, 0), .pi / 2)
            apply(next)
            drag = .turn(last: now, moved: true)
        case .box(let start, let moved):
            guard moved != nil || abs(now.x - start.x) + abs(now.y - start.y) > 3 else { return }
            drag = .box(start: start, now: now)
            needsDisplay = true
            NSCursor.crosshair.set()
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .box(let start, _?) = drag { drag = .box(start: start, now: location(of: event)) }
        let finished = drag
        let box = zoomBox
        drag = nil
        updateCursor()
        needsDisplay = true
        switch finished {
        case .box(_, let moved):
            if moved != nil, let box {
                guard max(box.width, box.height) >= 12 else { return }
                animate(to: camera.zoomed(toFill: box, size: bounds.size), duration: 0.35)
            } else if let index = itemIndex(at: location(of: event)) {
                onPick?(index)
            }
        case .turn(_, let moved):
            if !moved, let index = itemIndex(at: location(of: event)) { onPick?(index) }
        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let zoomKey = !event.modifierFlags.intersection([.command, .option]).isEmpty
        if event.hasPreciseScrollingDeltas && !zoomKey {
            apply(camera.panned(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
        } else {
            let rate = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            apply(camera.zoomed(by: pow(2, event.scrollingDeltaY * rate), around: location(of: event), size: bounds.size))
        }
    }

    override func magnify(with event: NSEvent) {
        apply(camera.zoomed(by: 1 + event.magnification, around: location(of: event), size: bounds.size))
    }
}
