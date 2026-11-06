import AppKit
import MetalKit
import SwiftUI
import TopographCore

/// Lets the keys and menu commands reach the map.
@MainActor
final class TerrainController {
    fileprivate weak var view: TerrainMTKView?

    func zoomIn() { view?.zoomFromCenter(by: 1.8) }
    func zoomOut() { view?.zoomFromCenter(by: 1 / 1.8) }
    func fit() { view?.animateToFit() }
}

struct TerrainView: NSViewRepresentable {
    let scene: TerrainScene?
    let controller: TerrainController
    var onFailure: (String) -> Void

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
        view.show(scene)
    }
}

final class TerrainMTKView: MTKView, MTKViewDelegate {
    private var renderer: TerrainRenderer?
    private var transform = MapTransform(k: 1, x: 0, y: 0)
    /// Whether the whole map is what's meant to be showing, so it stays fitted as the
    /// window changes size. Ends when you pan or zoom.
    private var fitted = true
    private var shownScene: UUID?
    private var theme = Theme.light
    private var dragStart: CGPoint?
    private var animation: (from: MapTransform, to: MapTransform, start: CFTimeInterval, duration: CFTimeInterval)?
    private var link: CADisplayLink?

    func setUp() throws {
        colorPixelFormat = .bgra8Unorm
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true
        enableSetNeedsDisplay = true
        renderer = try TerrainRenderer(view: self)
        delegate = self
        updateTheme()
    }

    func show(_ scene: TerrainScene?) {
        guard scene?.id != shownScene else { return }
        shownScene = scene?.id
        renderer?.setScene(scene)
        needsDisplay = true
    }

    // MARK: Drawing

    func draw(in view: MTKView) {
        renderer?.draw(in: self, transform: transform, theme: theme)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        animation = nil
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
        theme = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        needsDisplay = true
    }

    // MARK: Pan and zoom

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        stopAnimating()
        dragStart = location(of: event)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = location(of: event)
        apply(transform.panned(dx: now.x - start.x, dy: now.y - start.y))
        dragStart = now
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        window?.invalidateCursorRects(for: self)
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

    // MARK: Animation

    private func animate(to target: MapTransform, duration: CFTimeInterval) {
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
