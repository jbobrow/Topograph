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

    /// Move to a spot on the map at a given zoom.
    func fly(x: Double, y: Double, k: Double) { view?.fly(x: x, y: y, k: k) }

    /// Close enough to a region that the regions inside it are named.
    func fly(to region: Region) {
        guard let view else { return }
        let factor = region.children.isEmpty ? 0.7 : 1.15
        fly(x: region.x, y: region.y, k: LabelPlanner.expandAt(view.bounds.size) * factor / region.r)
    }

    /// To an item, at least close enough to see it as a picture.
    func fly(toItem item: MapItem) {
        guard let view else { return }
        fly(x: Double(item.x), y: Double(item.y), k: max(view.zoom, 4))
    }
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
    var onFailure: (String) -> Void
    var onHover: (Hover?) -> Void
    var onPickItem: (Int32) -> Void
    var onPickRegion: (Int) -> Void
    var onWhere: ([Int]) -> Void

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
        view.show(scene, root: root, imageMode: imageMode, selected: selected)
    }
}

final class TerrainMTKView: MTKView, MTKViewDelegate {
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
    private var dragStart: CGPoint?
    private var dragged = false
    private var animation: (from: MapTransform, to: MapTransform, start: CFTimeInterval, duration: CFTimeInterval)?
    private var link: CADisplayLink?
    private var tracking: NSTrackingArea?

    private var planner = LabelPlanner()
    private var placed: [PlacedLabel] = []
    /// Names fade in and out on the clock, and always come to rest shown or hidden.
    private var labelAlpha: [Int: Double] = [:]
    private var lastLabelFrame: CFTimeInterval = 0
    private var labelsMoving = false

    private var hovered: Int32?
    private var whereKey: [Int] = []

    var onHover: ((Hover?) -> Void)?
    var onPickItem: ((Int32) -> Void)?
    var onPickRegion: ((Int) -> Void)?
    var onWhere: (([Int]) -> Void)?

    var zoom: Double { transform.k }

    func setUp() throws {
        colorPixelFormat = .bgra8Unorm
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
        self.selected = selected
        if root != self.root, let root, let renderer {
            self.root = root
            let store = ThumbnailStore(device: renderer.device, queue: renderer.queue, root: root)
            store.onReady = { [weak self] in self?.needsDisplay = true }
            thumbnails = store
        }
        guard scene?.id != shownScene else { return }
        shownScene = scene?.id
        self.scene = scene
        renderer?.setScene(scene)
        needsDisplay = true
    }

    // MARK: Drawing

    func draw(in view: MTKView) {
        guard let renderer else { return }
        var overlay = TerrainOverlay()
        if let scene {
            let size = bounds.size
            let scale = bounds.width > 0 ? Double(drawableSize.width / bounds.width) : 1
            overlay.dots = transform.k >= TerrainStyle.thumbnailZoom
            thumbnails?.beginFrame()
            if overlay.dots { overlay.thumbs = thumbnailPlacements(scene, scale: scale) }
            thumbnails?.endFrame()
            if let selected, scene.visible.contains(selected) {
                let item = scene.map.items[Int(selected)]
                let half = overlay.dots ? TerrainStyle.thumbnailSize(k: transform.k) * 0.5 + 8 : 10
                overlay.viewfinder = (screen(item), half)
            }
            overlay.labels = labelPlacements(scene, size: size, scale: scale)
            updateWhere(scene)
        }
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
            out.append(ThumbPlacement(center: screen(item), size: size, frame: item.mine || lifted ? 2 : 1, mine: item.mine || lifted,
                                      texture: texture, mode: mode,
                                      nearest: dither && long * scale >= Double(texture?.width ?? 0)))
        }
        for index in chosen.reversed() where index != hovered { place(index, lifted: false) }
        if let hovered, chosen.contains(hovered) { place(hovered, lifted: true) }
        return out
    }

    private func labelPlacements(_ scene: TerrainScene, size: CGSize, scale: Double) -> [LabelPlacement] {
        guard let labels else { return [] }
        placed = planner.plan(tree: scene.map.regions, counts: scene.counts, transform: transform, size: size,
                              width: { labels.width($0, size: $1) })
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
            let label = shown[id] ?? PlacedLabel.geometry(
                id: id, x: region.x * transform.k + transform.x, y: region.y * transform.k + transform.y,
                top: region.depth == 0, count: scene.counts[id] ?? 0,
                nameWidth: labels.width(region.label, size: region.depth == 0 ? 12 : 11),
                countWidth: labels.width((scene.counts[id] ?? 0).formatted(), size: 10))
            guard let texture = labels.texture(label: label, name: region.label, theme: theme, dark: dark, scale: scale) else { continue }
            out.append(LabelPlacement(origin: label.box.origin, size: label.box.size, texture: texture, alpha: alpha))
        }
        labelsMoving = moving
        if moving { needsDisplay = true }
        return out
    }

    /// The regions you've zoomed inside, as a path from the top.
    private func updateWhere(_ scene: TerrainScene) {
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

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        stopAnimating()
        if fitted {
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

    // MARK: Pan and zoom

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
        addCursorRect(bounds, cursor: dragStart != nil ? .closedHand : .crosshair)
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
        stopAnimating()
        dragStart = location(of: event)
        dragged = false
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = location(of: event)
        if abs(now.x - start.x) + abs(now.y - start.y) > 0 { dragged = true }
        apply(transform.panned(dx: now.x - start.x, dy: now.y - start.y))
        dragStart = now
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        window?.invalidateCursorRects(for: self)
        guard !dragged else { return }
        let point = location(of: event)
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
        if event.hasPreciseScrollingDeltas && !zoomKey {
            apply(transform.panned(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
        } else {
            let rate = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            apply(transform.zoomed(by: pow(2, event.scrollingDeltaY * rate), around: location(of: event)))
        }
    }

    override func magnify(with event: NSEvent) {
        apply(transform.zoomed(by: 1 + event.magnification, around: location(of: event)))
    }

    fileprivate func zoomFromCenter(by factor: Double) {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        fitted = false
        // Quick presses add up: each one starts from where the last was heading.
        animate(to: (animation?.to ?? transform).zoomed(by: factor, around: center), duration: 0.25)
    }

    fileprivate func animateToFit() {
        fitted = true
        animate(to: .fit(bounds.size), duration: 0.4)
    }

    fileprivate func fly(x: Double, y: Double, k: Double) {
        fitted = false
        let zoom = min(max(k, MapTransform.zoomRange.lowerBound), MapTransform.zoomRange.upperBound)
        animate(to: MapTransform(k: zoom, x: bounds.width / 2 - x * zoom, y: bounds.height / 2 - y * zoom), duration: 0.6)
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
        link?.invalidate()
        link = nil
    }
}
