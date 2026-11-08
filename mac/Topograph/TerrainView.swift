import AppKit
import MetalKit
import SwiftUI
import TopographCore

/// Lets the keys, menu commands and panel reach the map.
@MainActor
final class TerrainController {
    fileprivate weak var view: TerrainMTKView?

    func zoomIn() { view?.zoomFromCenter(by: 1.8) }
    func zoomOut() { view?.zoomFromCenter(by: 1 / 1.8) }
    func fit() { view?.animateToFit() }

    /// See the terrain in 3D, rising out of the flat map, or settle back down onto it.
    func setRelief(_ on: Bool) { view?.setRelief(on) }

    /// Put a spot on the map at the middle of the view, right away, as a drag on the minimap does.
    func center(x: Double, y: Double) { view?.center(x: x, y: y) }

    /// The minimap keeps its own cursor; everything else on top of the map gets an arrow.
    var pointerIsOnMinimap: Bool {
        get { view?.pointerIsOnMinimap ?? false }
        set { view?.pointerIsOnMinimap = newValue }
    }

    /// Move to a spot on the map at a given zoom.
    func fly(x: Double, y: Double, k: Double) { view?.fly(x: x, y: y, k: k) }

    /// Close enough to a region that the regions inside it are named.
    func fly(to region: Region) {
        guard let view else { return }
        let factor = region.children.isEmpty ? 0.7 : 1.15
        fly(x: region.x, y: region.y, k: LabelPlanner.expandAt(view.bounds.size) * factor / region.r)
    }

    /// Back to where this region's own name is the one showing.
    func fly(inside region: Region) {
        guard let view else { return }
        fly(x: region.x, y: region.y, k: LabelPlanner.expandAt(view.bounds.size) * 0.7 / region.r)
    }

    /// To an item, at least close enough to see it as a picture.
    func fly(toItem item: MapItem) {
        guard let view else { return }
        view.fly(x: Double(item.x), y: Double(item.y), k: max(view.zoom, 4), besidePanel: true)
    }
}

/// How much of the map is showing, for the minimap.
struct MapViewport: Equatable {
    let transform: MapTransform
    let size: CGSize
}

/// What's under the pointer, in points within the map.
struct Hover: Equatable {
    let item: Int32
    let location: CGPoint
    let mapSize: CGSize
}

struct TerrainView: NSViewRepresentable {
    let scene: TerrainScene?
    let root: URL?
    let controller: TerrainController
    let imageMode: ImageMode
    let selected: Int32?
    let isActive: Bool
    let isPlaying: Bool
    /// The terrain stood up in 3D, to fly over.
    let relief: Bool
    var onFailure: (String) -> Void
    var onHover: (Hover?) -> Void
    var onPickItem: (Int32) -> Void
    var onPickRegion: (Int) -> Void
    var onWhere: ([Int]) -> Void
    var onViewport: (MapViewport) -> Void

    func makeNSView(context: Context) -> TerrainMTKView {
        let view = TerrainMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        controller.view = view
        do {
            try view.setUp()
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { onFailure(message) }
        }
        return view
    }

    func updateNSView(_ view: TerrainMTKView, context: Context) {
        controller.view = view
        view.onHover = onHover
        view.onPickItem = onPickItem
        view.onPickRegion = onPickRegion
        view.onWhere = onWhere
        view.onViewport = onViewport
        view.isActive = isActive
        view.isPlaying = isPlaying
        view.show(scene, root: root, imageMode: imageMode, selected: selected)
        view.setRelief(relief)
    }
}

final class TerrainMTKView: MTKView, MTKViewDelegate {
    /// What a press on the map is doing. Space at the press decides which.
    private enum Drag {
        case pan(last: CGPoint)
        case box(start: CGPoint, now: CGPoint?)
        /// In 3D: turning and tilting. Without moving, it's a click.
        case orbit(start: CGPoint, last: CGPoint, moved: Bool)
    }

    private var renderer: TerrainRenderer?
    private var thumbnails: ThumbnailStore?
    private var labels: LabelStore?
    private var scene: TerrainScene?
    private var root: URL?
    private var imageMode = ImageMode.gray
    private var selected: Int32?
    private var transform = MapTransform(k: 1, x: 0, y: 0)
    /// Whether the whole map is what's meant to be showing, so it stays fitted as the
    /// window changes size. Ends when you pan or zoom.
    private var fitted = true
    private var shownScene: UUID?
    private var theme = Theme.light
    private var dark = false
    private var drag: Drag?
    /// Space is down, so a drag moves the map.
    private var spaceHeld = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var animation: (from: MapTransform, to: MapTransform, start: CFTimeInterval, duration: CFTimeInterval)?
    private var link: CADisplayLink?
    private var floatLink: CADisplayLink?
    private var tracking: NSTrackingArea?

    private var planner = LabelPlanner()
    private var placed: [PlacedLabel] = []
    /// Names fade in and out on the clock, and always come to rest shown or hidden.
    private var labelAlpha: [Int: Double] = [:]
    private var lastLabelFrame: CFTimeInterval = 0
    private var labelsMoving = false

    /// While the terrain is in 3D, the camera flying over it. Everything that works on the flat
    /// map's transform uses `shown`, the flat equivalent of what the camera sees.
    private var camera: OrbitCamera?
    /// How far the relief has risen out of the flat map, 0 to 1.
    private var rise = 0.0
    private var wantsRelief = false
    private var flight: (from: OrbitCamera, to: OrbitCamera, riseFrom: Double, riseTo: Double,
                         start: CFTimeInterval, duration: CFTimeInterval)?
    /// Where each item stands on the relief, for this scene.
    private var points: ReliefPoints?
    /// Pictures standing in 3D last frame, nearest last, for finding what's under the pointer.
    private var standing: [(index: Int32, frame: CGRect)] = []

    private var hovered: Int32?
    var pointerIsOnMinimap = false
    private var whereKey: [Int] = []

    var onHover: ((Hover?) -> Void)?
    var onPickItem: ((Int32) -> Void)?
    var onPickRegion: ((Int) -> Void)?
    var onWhere: (([Int]) -> Void)?
    var onViewport: ((MapViewport) -> Void)?
    /// Whether the map is the view showing. Other views get the keyboard to themselves.
    var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive { setSpaceHeld(false) }
            updateFloating()
            window?.invalidateCursorRects(for: self)
        }
    }
    /// While the timeline plays, space pauses it instead of moving the map.
    var isPlaying = false
    private var lastViewport: MapViewport?

    var zoom: Double { shown.k }

    /// The flat map's transform, or in 3D the flat transform showing the same middle at the same scale.
    private var shown: MapTransform { camera?.transform(viewSize: bounds.size) ?? transform }

    func setUp() throws {
        colorPixelFormat = .bgra8Unorm
        // For the terrain in 3D, where the ground hides what's behind it.
        depthStencilPixelFormat = .depth32Float
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true
        enableSetNeedsDisplay = true
        let renderer = try TerrainRenderer(view: self)
        self.renderer = renderer
        labels = LabelStore(device: renderer.device)
        delegate = self
        updateTheme()
    }

    func show(_ scene: TerrainScene?, root: URL?, imageMode: ImageMode, selected: Int32?) {
        if self.imageMode != imageMode || self.selected != selected { needsDisplay = true }
        self.imageMode = imageMode
        let newlySelected = selected != self.selected ? selected : nil
        self.selected = selected
        updateFloating()
        if root != self.root, let root, let renderer {
            self.root = root
            let store = ThumbnailStore(device: renderer.device, queue: renderer.queue, root: root)
            store.onReady = { [weak self] in self?.needsDisplay = true }
            thumbnails = store
        }
        guard scene?.id != shownScene else { return keep(newlySelected) }
        shownScene = scene?.id
        self.scene = scene
        points = nil
        renderer?.setScene(scene)
        needsDisplay = true
        keep(newlySelected)
    }

    private func keep(_ index: Int32?) {
        guard let index, let scene, isActive, scene.visible.contains(index) else { return }
        keepInView(index, scene: scene)
    }

    // MARK: The selection

    /// The picture floats for as long as it's selected and can be seen.
    private func updateFloating() {
        let wanted = selected != nil && isActive && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wanted, floatLink == nil {
            let link = displayLink(target: self, selector: #selector(stepFloating))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            floatLink = link
        } else if !wanted {
            floatLink?.invalidate()
            floatLink = nil
        }
    }

    @objc private func stepFloating() {
        if window?.occlusionState.contains(.visible) == true { needsDisplay = true }
    }

    /// Opening the side panel covers the right of the map, so an item there moves out from under it.
    private func keepInView(_ index: Int32, scene: TerrainScene) {
        guard animation == nil, flight == nil else { return }
        if let camera {
            guard let at = camera.projection(viewSize: bounds.size).project(reliefPoints(scene).position(index, rise: Float(rise))) else { return }
            let move = FloatingPicture.correction(for: at.point, bounds: bounds.size)
            if move != .zero { fly(to: camera.panned(dx: move.width, dy: move.height, viewSize: bounds.size), duration: 0.3) }
            return
        }
        let move = FloatingPicture.correction(for: screen(scene.map.items[Int(index)]), bounds: bounds.size)
        if move != .zero { animate(to: transform.panned(dx: move.width, dy: move.height), duration: 0.3) }
    }

    /// `place` is where it is on screen, and `k` the scale it's seen at there.
    private func placeFloating(_ index: Int32, scene: TerrainScene, place: CGPoint, k: Double, scale: Double, into overlay: inout TerrainOverlay) {
        let item = scene.map.items[Int(index)]
        guard let path = item.thumb, let thumbnails else { return }
        let long = TerrainStyle.thumbnailSize(k: k) * TerrainStyle.thumbnailScale(resonance: item.resonance)
        let placed = FloatingPicture.layout(place: place, aspect: Double(item.aspect ?? 1), long: long, bounds: bounds.size)
        let texture = thumbnails.texture(item: index, path: path, pixels: max(placed.size.width, placed.size.height) * scale, dither: false)
        overlay.floating = ThumbPlacement(center: placed.center, size: placed.size, frame: 2, mine: true,
                                          texture: texture, mode: .color, nearest: false)
        overlay.stem = placed.stem
    }

    // MARK: Drawing

    func draw(in view: MTKView) {
        guard let renderer else { return }
        if let camera { return draw(renderer, camera: camera) }
        var overlay = TerrainOverlay()
        if let scene {
            let size = bounds.size
            let scale = bounds.width > 0 ? Double(drawableSize.width / bounds.width) : 1
            overlay.dots = transform.k >= TerrainStyle.thumbnailZoom
            thumbnails?.beginFrame()
            if overlay.dots { overlay.thumbs = thumbnailPlacements(scene, scale: scale) }
            if let selected, scene.visible.contains(selected) {
                // With a picture lifted off, this marks the place it came from.
                let item = scene.map.items[Int(selected)]
                overlay.viewfinder = (screen(item), item.thumb == nil && overlay.dots ? TerrainStyle.thumbnailSize(k: transform.k) * 0.5 + 8 : 10)
                placeFloating(selected, scene: scene, place: screen(item), k: transform.k, scale: scale, into: &overlay)
            }
            thumbnails?.endFrame()
            let transform = transform
            overlay.labels = labelPlacements(scene, size: size, scale: scale) { region in
                (CGPoint(x: region.x * transform.k + transform.x, y: region.y * transform.k + transform.y), transform.k)
            }
            updateWhere(scene)
        }
        overlay.zoomBox = zoomBox
        updateViewport()
        renderer.draw(in: self, transform: transform, theme: theme, overlay: overlay)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func screen(_ item: MapItem) -> CGPoint {
        CGPoint(x: Double(item.x) * transform.k + transform.x, y: Double(item.y) * transform.k + transform.y)
    }

    /// The most resonant pictures in view, least resonant first so the rest draw on top.
    private func thumbnailPlacements(_ scene: TerrainScene, scale: Double) -> [ThumbPlacement] {
        guard let thumbnails else { return [] }
        let k = transform.k, limit = 1500
        let margin = 20 * max(1, 2.4 / k)
        let x0 = -transform.x / k - margin, y0 = -transform.y / k - margin
        let x1 = (bounds.width - transform.x) / k + margin, y1 = (bounds.height - transform.y) / k + margin

        var chosen: [Int32] = []
        chosen.reserveCapacity(limit)
        for index in scene.pictures {
            let item = scene.map.items[Int(index)]
            let x = Double(item.x), y = Double(item.y)
            guard x >= x0, x <= x1, y >= y0, y <= y1 else { continue }
            chosen.append(index)
            if chosen.count == limit { break }
        }

        let sizePoints = TerrainStyle.thumbnailSize(k: k)
        var out: [ThumbPlacement] = []
        out.reserveCapacity(chosen.count + 1)
        func place(_ index: Int32, lifted: Bool) {
            let item = scene.map.items[Int(index)]
            guard let path = item.thumb else { return }
            let long = sizePoints * TerrainStyle.thumbnailScale(resonance: item.resonance) * (lifted ? 1.18 : 1)
            let aspect = Double(item.aspect ?? 1)
            let size = aspect >= 1 ? CGSize(width: long, height: long / aspect) : CGSize(width: long * aspect, height: long)
            // Hover shows it in full color, so it needs a color copy whatever the mode.
            let mode = lifted ? ImageMode.color : imageMode
            let dither = mode == .dither
            let texture = thumbnails.texture(item: index, path: path, pixels: long * scale, dither: dither)
            // Stays a dot until its picture is ready. With the timeline playing, pictures arrive
            // faster than they can load, and empty frames would flicker across the map.
            if texture == nil, !lifted { return }
            out.append(ThumbPlacement(center: screen(item), size: size, frame: item.mine || lifted ? 2 : 1, mine: item.mine || lifted,
                                      texture: texture, mode: mode,
                                      nearest: dither && long * scale >= Double(texture?.width ?? 0)))
        }
        // The selected picture is lifted off the map, so it isn't here as well.
        for index in chosen.reversed() where index != hovered && index != selected { place(index, lifted: false) }
        if let hovered, hovered != selected, chosen.contains(hovered) { place(hovered, lifted: true) }
        return out
    }

    /// `locate` says where a region's name is anchored on screen and the scale it's seen at.
    private func labelPlacements(_ scene: TerrainScene, size: CGSize, scale: Double,
                                 locate: (Region) -> (point: CGPoint, k: Double)?) -> [LabelPlacement] {
        guard let labels else { return [] }
        placed = planner.plan(tree: scene.map.regions, counts: scene.counts, size: size,
                              width: { labels.width($0, size: $1) }, locate: locate)
        let now = CACurrentMediaTime()
        // The first step after a pause is one frame's worth, so a slow frame never
        // leaves a name half-visible for long.
        let dt = labelsMoving ? min(now - lastLabelFrame, 0.14) : 0.016
        lastLabelFrame = now
        let step = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : min(1, dt / 0.14)

        let shown = Dictionary(placed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in shown.keys where labelAlpha[id] == nil { labelAlpha[id] = 0 }
        var moving = false
        var out: [LabelPlacement] = []
        for (id, before) in labelAlpha {
            let target = shown[id] != nil ? 1.0 : 0.0
            let alpha = before == target ? before : target > before ? min(1, before + step) : max(0, before - step)
            if alpha <= 0 && target == 0 {
                labelAlpha[id] = nil
                continue
            }
            labelAlpha[id] = alpha
            if alpha != target { moving = true }
            guard let region = scene.map.regions.regions[id] else { continue }
            // A name that's leaving keeps following its anchor as it fades.
            guard let anchor = shown[id].map({ CGPoint(x: $0.x, y: $0.y) }) ?? locate(region)?.point else { continue }
            let label = shown[id] ?? PlacedLabel.geometry(
                id: id, x: anchor.x, y: anchor.y,
                top: region.depth == 0, count: scene.counts[id] ?? 0,
                nameWidth: labels.width(region.label, size: region.depth == 0 ? 12 : 11),
                countWidth: labels.width((scene.counts[id] ?? 0).formatted(), size: 10))
            guard let texture = labels.texture(label: label, name: region.label, theme: theme, dark: dark, scale: scale) else { continue }
            out.append(LabelPlacement(origin: label.box.origin, size: label.box.size, texture: texture, alpha: alpha, region: id))
        }
        labelsMoving = moving
        if moving { needsDisplay = true }
        return out
    }

    /// The regions you've zoomed inside, as a path from the top.
    private func updateWhere(_ scene: TerrainScene) {
        let transform = shown
        let cx = (bounds.width / 2 - transform.x) / transform.k, cy = (bounds.height / 2 - transform.y) / transform.k
        var path: [Int] = []
        if let index = scene.spatial.nearest(x: cx, y: cy, radius: 80 / transform.k),
           let region = scene.map.items[Int(index)].region, let full = scene.map.regions.regions[region]?.path {
            path = full.filter(planner.expanded.contains)
        }
        guard path != whereKey else { return }
        whereKey = path
        let notify = onWhere
        DispatchQueue.main.async { notify?(path) }
    }

    private func updateViewport() {
        let viewport = MapViewport(transform: shown, size: bounds.size)
        guard viewport != lastViewport else { return }
        lastViewport = viewport
        let notify = onViewport
        DispatchQueue.main.async { notify?(viewport) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        stopAnimating()
        if let camera {
            if fitted { self.camera = settled(.overview(viewSize: newSize, yaw: camera.yaw)) }
        } else if wantsRelief {
            // Asked for before there was a size to start from.
            rise = 1
            camera = settled(.overview(viewSize: newSize))
        } else if fitted {
            transform = .fit(newSize)
        } else {
            transform = transform.panned(dx: (newSize.width - old.width) / 2, dy: (newSize.height - old.height) / 2)
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTheme()
    }

    private func updateTheme() {
        dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        theme = dark ? .dark : .light
        needsDisplay = true
    }

    // MARK: Pan, zoom and the keyboard

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        updateFloating()
        guard let window else { return setSpaceHeld(false) }
        // Through a monitor rather than keyDown, so space works whatever has focus,
        // short of somewhere you're typing.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        // A key released in another app never reaches this one.
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
        guard isActive, !isPlaying, !(window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        // Still down from the press that paused playing, it isn't asking to move the map.
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

    private var cursor: NSCursor {
        if case .pan = drag { return .closedHand }
        if case .orbit(_, _, true) = drag { return .closedHand }
        return spaceHeld ? .openHand : .crosshair
    }

    private func updateCursor() {
        window?.invalidateCursorRects(for: self)
        if pointerIsOverMap { cursor.set() }
    }

    /// False when the minimap, a key or the side panel is on top of the map there.
    private var pointerIsOverMap: Bool { viewUnderPointer === self }

    private var viewUnderPointer: NSView? {
        guard let window, let content = window.contentView else { return nil }
        let point = window.mouseLocationOutsideOfEventStream
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }

    /// The map's crosshair covers its whole area, so whatever sits on top of it needs telling
    /// apart. Text fields look after their own cursor.
    private func setCursorOverChrome() {
        guard !pointerIsOnMinimap, !(viewUnderPointer is NSText), !(viewUnderPointer is NSTextField) else { return }
        NSCursor.arrow.set()
    }

    /// The rectangle being drawn, once the pointer has moved enough to mean it.
    private var zoomBox: CGRect? {
        guard case .box(let start, let now?) = drag else { return nil }
        let box = CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
        return box.intersection(bounds)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        // The map stays alive under other views, invisibly, and has no say in their cursor.
        guard isActive else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    /// In view points, y down, like map coordinates.
    private func location(of event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func apply(_ next: MapTransform) {
        stopAnimating()
        fitted = false
        transform = next
        clearHover()
        needsDisplay = true
    }

    private func itemIndex(at point: CGPoint) -> Int32? {
        guard let scene else { return nil }
        if let camera {
            if let hit = standing.last(where: { $0.frame.contains(point) }) { return hit.index }
            return reliefPoints(scene).nearest(scene.visible, to: point, projection: camera.projection(viewSize: bounds.size),
                                               rise: Float(rise), radius: 8)
        }
        let k = transform.k
        let radius = (k >= TerrainStyle.thumbnailZoom ? TerrainStyle.thumbnailSize(k: k) * 0.5 : 8) / k
        return scene.spatial.nearest(x: (point.x - transform.x) / k, y: (point.y - transform.y) / k, radius: radius)
    }

    private func labelID(at point: CGPoint) -> Int? {
        placed.first { $0.box.contains(point) }?.id
    }

    private func clearHover() {
        guard hovered != nil else { return }
        hovered = nil
        onHover?(nil)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        // Hidden under another view, the map has no say in the cursor.
        guard isActive else { return }
        guard pointerIsOverMap else {
            setCursorOverChrome()
            return clearHover()
        }
        if spaceHeld {
            NSCursor.openHand.set()
            return
        }
        let point = location(of: event)
        let onLabel = labelID(at: point) != nil
        let index = onLabel ? nil : itemIndex(at: point)
        if onLabel || index != nil { NSCursor.pointingHand.set() } else { NSCursor.crosshair.set() }
        guard let index else { return clearHover() }
        if index != hovered { needsDisplay = true }
        hovered = index
        onHover?(Hover(item: index, location: point, mapSize: bounds.size))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        stopAnimating()
        clearHover()
        drag = spaceHeld ? .pan(last: point) : camera != nil ? .orbit(start: point, last: point, moved: false) : .box(start: point, now: nil)
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = location(of: event)
        switch drag {
        case .pan(let last):
            if let camera {
                apply(camera.panned(dx: now.x - last.x, dy: now.y - last.y, viewSize: bounds.size))
            } else {
                apply(transform.panned(dx: now.x - last.x, dy: now.y - last.y))
            }
            drag = .pan(last: now)
        case .orbit(let start, let last, let moved):
            guard moved || abs(now.x - start.x) + abs(now.y - start.y) > 3, let camera else { return }
            // Dragging sideways turns the map under the pointer; down looks more from above.
            apply(camera.orbited(yaw: -(now.x - last.x) * 0.006, pitch: (now.y - last.y) * 0.005))
            drag = .orbit(start: start, last: now, moved: true)
            if !moved { updateCursor() }
        case .box(let start, let moved):
            // A hand's small wobble on a click isn't a rectangle.
            guard moved != nil || abs(now.x - start.x) + abs(now.y - start.y) > 3 else { return }
            drag = .box(start: start, now: now)
            needsDisplay = true
            NSCursor.crosshair.set()
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        // The last drag event can be some way short of where the button came up.
        if case .box(let start, let now?) = drag { drag = .box(start: start, now: location(of: event)) }
        let finished = drag
        let box = zoomBox
        drag = nil
        updateCursor()
        if case .orbit(_, _, let moved) = finished {
            if !moved { pick(at: location(of: event)) }
            return
        }
        guard case .box = finished else { return }
        needsDisplay = true
        if let box {
            // Too small to have been meant.
            guard max(box.width, box.height) >= 12 else { return }
            fitted = false
            animate(to: transform.zoomed(toFill: box, viewSize: bounds.size), duration: 0.35)
            return
        }
        pick(at: location(of: event))
    }

    private func pick(at point: CGPoint) {
        if let id = labelID(at: point) {
            onPickRegion?(id)
        } else if let index = itemIndex(at: point) {
            onPickItem?(index)
        }
    }

    /// Two fingers on a trackpad pan, as they do in Maps. A mouse wheel zooms, and
    /// so do two fingers with ⌘ or ⌥ held.
    override func scrollWheel(with event: NSEvent) {
        let zoomKey = !event.modifierFlags.intersection([.command, .option]).isEmpty
        if let camera {
            if event.hasPreciseScrollingDeltas && !zoomKey {
                apply(camera.panned(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, viewSize: bounds.size))
            } else {
                let rate = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
                zoomCamera(camera, by: pow(2, event.scrollingDeltaY * rate), at: location(of: event))
            }
            return
        }
        if event.hasPreciseScrollingDeltas && !zoomKey {
            apply(transform.panned(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
        } else {
            let rate = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            apply(transform.zoomed(by: pow(2, event.scrollingDeltaY * rate), around: location(of: event)))
        }
    }

    override func magnify(with event: NSEvent) {
        if let camera { return zoomCamera(camera, by: 1 + event.magnification, at: location(of: event)) }
        apply(transform.zoomed(by: 1 + event.magnification, around: location(of: event)))
    }

    /// Two fingers turning on a trackpad turn the map with them, in 3D.
    override func rotate(with event: NSEvent) {
        guard let camera else { return }
        apply(camera.orbited(yaw: -Double(event.rotation) * .pi / 180, pitch: 0))
    }

    /// Toward the ground under the pointer.
    private func zoomCamera(_ camera: OrbitCamera, by factor: Double, at point: CGPoint) {
        let spot = camera.projection(viewSize: bounds.size).ground(at: point, height: camera.ground)
        apply(camera.zoomed(by: factor, toward: spot))
    }

    fileprivate func zoomFromCenter(by factor: Double) {
        if let camera {
            fitted = false
            return fly(to: (flight?.to ?? camera).zoomed(by: factor), duration: 0.25)
        }
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        fitted = false
        // Quick presses add up: each one starts from where the last was heading.
        animate(to: (animation?.to ?? transform).zoomed(by: factor, around: center), duration: 0.25)
    }

    fileprivate func animateToFit() {
        fitted = true
        if camera != nil { return fly(to: .overview(viewSize: bounds.size), duration: 0.6) }
        animate(to: .fit(bounds.size), duration: 0.4)
    }

    fileprivate func center(x: Double, y: Double) {
        if var camera {
            camera.x = x
            camera.y = y
            return apply(camera)
        }
        apply(transform.centered(onX: x, y: y, viewSize: bounds.size))
    }

    /// `besidePanel` puts it in the middle of what the side panel leaves showing.
    fileprivate func fly(x: Double, y: Double, k: Double, besidePanel: Bool = false) {
        fitted = false
        let zoom = min(max(k, MapTransform.zoomRange.lowerBound), MapTransform.zoomRange.upperBound)
        if var camera = flight?.to ?? camera {
            camera.x = x
            camera.y = y
            camera.distance = OrbitCamera.focal(bounds.size) / zoom
            if besidePanel { camera = camera.panned(dx: -DetailPanel.width / 2, dy: 0, viewSize: bounds.size) }
            return fly(to: camera, duration: 0.6)
        }
        let width = bounds.width - (besidePanel ? DetailPanel.width : 0)
        animate(to: MapTransform(k: zoom, x: width / 2 - x * zoom, y: bounds.height / 2 - y * zoom), duration: 0.6)
    }

    // MARK: Animation

    private func animate(to target: MapTransform, duration: CFTimeInterval) {
        clearHover()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            transform = target
            needsDisplay = true
            return
        }
        animation = (transform, target, CACurrentMediaTime(), duration)
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step() {
        if let flight { return stepFlight(flight) }
        guard let animation else { return stopAnimating() }
        let t = min((CACurrentMediaTime() - animation.start) / animation.duration, 1)
        let eased = t * t * (3 - 2 * t)
        transform = t < 1
            ? animation.from.interpolated(to: animation.to, t: eased, viewSize: bounds.size)
            : animation.to
        needsDisplay = true
        if t >= 1 { stopAnimating() }
    }

    private func stopAnimating() {
        animation = nil
        if let flight {
            // Cut short, the relief finishes rising or settling at once, from wherever the camera is.
            self.flight = nil
            rise = flight.riseTo
            if rise == 0 { land() } else { camera = camera.map(settled) }
        }
        link?.invalidate()
        link = nil
    }
}

// MARK: - 3D

extension TerrainMTKView {
    /// Rises out of the flat map, seen from straight above, and tilts; or turns back north,
    /// looks straight down and settles flat again, where the flat map takes over.
    fileprivate func setRelief(_ on: Bool) {
        guard on != wantsRelief else { return }
        wantsRelief = on
        guard bounds.width > 0, bounds.height > 0 else { return }
        if on {
            let start = camera ?? OrbitCamera(above: transform, viewSize: bounds.size)
            flight = nil
            camera = start
            var tilted = start
            tilted.pitch = OrbitCamera.tilt
            fly(to: tilted, rise: 1, duration: 0.9)
        } else if let camera {
            var down = flight?.to ?? camera
            down.pitch = .pi / 2
            down.yaw = 0
            down.ground = 0
            fly(to: down, rise: 0, duration: 0.7)
        }
    }

    /// The camera as moved by a pan, zoom or turn, at the height of the ground it's circling.
    fileprivate func apply(_ next: OrbitCamera) {
        stopAnimating()
        // Cutting short the way down lands on the flat map.
        guard camera != nil else { return }
        fitted = false
        camera = settled(next)
        clearHover()
        needsDisplay = true
    }

    fileprivate func settled(_ camera: OrbitCamera) -> OrbitCamera {
        var camera = camera
        camera.ground = scene.map { Double(Relief.height($0.field, x: camera.x, y: camera.y, rise: Float(rise))) } ?? 0
        return camera
    }

    fileprivate func fly(to target: OrbitCamera, duration: CFTimeInterval) {
        fly(to: target, rise: flight?.riseTo ?? rise, duration: duration)
    }

    private func fly(to target: OrbitCamera, rise riseTo: Double, duration: CFTimeInterval) {
        guard let camera else { return }
        clearHover()
        var target = target
        if riseTo > 0 {
            target.ground = scene.map { Double(Relief.height($0.field, x: target.x, y: target.y, rise: Float(riseTo))) } ?? 0
        }
        animation = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            flight = nil
            self.camera = target
            rise = riseTo
            if riseTo == 0 { land() }
            needsDisplay = true
            return
        }
        flight = (camera, target, rise, riseTo, CACurrentMediaTime(), duration)
        if link == nil {
            let link = displayLink(target: self, selector: #selector(stepRelief))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func stepRelief() {
        if let flight { stepFlight(flight) } else { stopAnimating() }
    }

    fileprivate func stepFlight(_ flight: (from: OrbitCamera, to: OrbitCamera, riseFrom: Double, riseTo: Double,
                                           start: CFTimeInterval, duration: CFTimeInterval)) {
        let t = min((CACurrentMediaTime() - flight.start) / flight.duration, 1)
        let eased = t * t * (3 - 2 * t)
        camera = flight.from.interpolated(to: flight.to, t: eased)
        rise = flight.riseFrom + (flight.riseTo - flight.riseFrom) * eased
        needsDisplay = true
        if t >= 1 {
            self.flight = nil
            if rise == 0 { land() }
            stopAnimating()
        }
    }

    /// Back on the flat map, showing just what the camera showed looking straight down.
    private func land() {
        guard let camera else { return }
        transform = camera.transform(viewSize: bounds.size)
        self.camera = nil
        rise = 0
        standing = []
        needsDisplay = true
    }

    fileprivate func reliefPoints(_ scene: TerrainScene) -> ReliefPoints {
        if let points { return points }
        let made = ReliefPoints(items: scene.map.items, visible: scene.visible, field: scene.field)
        points = made
        return made
    }

    fileprivate func draw(_ renderer: TerrainRenderer, camera: OrbitCamera) {
        let size = bounds.size
        let scale = bounds.width > 0 ? Double(drawableSize.width / bounds.width) : 1
        let projection = camera.projection(viewSize: size)
        let rise = Float(self.rise)
        var overlay = TerrainOverlay()
        if let scene {
            let points = reliefPoints(scene)
            thumbnails?.beginFrame()
            overlay.thumbs = standingPlacements(scene, points: points, projection: projection, camera: camera, scale: scale)
            if let selected, scene.visible.contains(selected), let at = projection.project(points.position(selected, rise: rise)) {
                let item = scene.map.items[Int(selected)]
                let near = at.scale >= TerrainStyle.thumbnailZoom
                overlay.viewfinder = (at.point, item.thumb == nil && near ? TerrainStyle.thumbnailSize(k: at.scale) * 0.5 + 8 : 10)
                placeFloating(selected, scene: scene, place: at.point, k: at.scale, scale: scale, into: &overlay)
            }
            thumbnails?.endFrame()

            // Names float like clouds above the ground they name, a rule running down to it.
            var grounds: [Int: CGPoint] = [:]
            overlay.labels = labelPlacements(scene, size: size, scale: scale) { region in
                let height = Relief.height(scene.field, x: region.x, y: region.y, rise: rise)
                let x = Float(region.x), y = Float(region.y)
                guard let ground = projection.project(SIMD3(x, height, y)),
                      let sky = projection.project(SIMD3(x, height + Relief.height * 0.3 * rise, y)) else { return nil }
                grounds[region.id] = ground.point
                return (sky.point, ground.scale)
            }
            for label in overlay.labels {
                guard let id = label.region, let ground = grounds[id] else { continue }
                // The crosshair, as `PlacedLabel.geometry` places it.
                let anchor = CGPoint(x: label.origin.x + 5, y: label.origin.y + label.size.height / 2)
                if hypot(anchor.x - ground.x, anchor.y - ground.y) > 4 { overlay.stems.append((anchor, ground, label.alpha)) }
            }
            updateWhere(scene)
        }
        updateViewport()
        renderer.draw(in: self, transform: camera.transform(viewSize: size), theme: theme, overlay: overlay,
                      relief: ReliefFrame(camera: camera, projection: projection, rise: rise))
    }

    /// The most resonant pictures near enough to show, standing on their spots, farthest first
    /// so nearer ones draw over them. Seen straight down they lie flat, as on the flat map.
    private func standingPlacements(_ scene: TerrainScene, points: ReliefPoints, projection: Projection,
                                    camera: OrbitCamera, scale: Double) -> [ThumbPlacement] {
        guard let thumbnails else { return [] }
        let rise = Float(self.rise)
        let found = points.onScreen(scene.pictures, projection: projection, rise: rise, margin: 80,
                                    minimumScale: TerrainStyle.thumbnailZoom, limit: 800)
        let stand = min(1, cos(camera.pitch) * 3)
        var out: [ThumbPlacement] = []
        var hits: [(Int32, CGRect)] = []
        func place(_ index: Int32, _ at: Projection.Projected, lifted: Bool) {
            let item = scene.map.items[Int(index)]
            guard let path = item.thumb else { return }
            let long = TerrainStyle.thumbnailSize(k: at.scale) * TerrainStyle.thumbnailScale(resonance: item.resonance) * (lifted ? 1.18 : 1)
            let aspect = Double(item.aspect ?? 1)
            let size = aspect >= 1 ? CGSize(width: long, height: long / aspect) : CGSize(width: long * aspect, height: long)
            let mode = lifted ? ImageMode.color : imageMode
            let dither = mode == .dither
            let texture = thumbnails.texture(item: index, path: path, pixels: long * scale, dither: dither)
            if texture == nil, !lifted { return }
            let center = CGPoint(x: at.point.x, y: at.point.y - size.height / 2 * stand)
            // A little toward the eye, so the ground it stands on doesn't cut into it. Lifted, nothing does.
            let spot = points.position(index, rise: rise)
            let toward = simd_normalize(projection.eye - spot)
            let depth = lifted ? 0 : projection.project(spot + toward * 3)?.depth ?? at.depth
            out.append(ThumbPlacement(center: center, size: size, frame: item.mine || lifted ? 2 : 1, mine: item.mine || lifted,
                                      texture: texture, mode: mode,
                                      nearest: dither && long * scale >= Double(texture?.width ?? 0), depth: depth))
            hits.append((index, CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)))
        }
        for (index, at) in found.sorted(by: { $0.at.depth > $1.at.depth }) where index != hovered && index != selected {
            place(index, at, lifted: false)
        }
        if let hovered, hovered != selected, let at = found.first(where: { $0.index == hovered })?.at { place(hovered, at, lifted: true) }
        standing = hits
        return out
    }
}
