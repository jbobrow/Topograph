import AppKit
import QuartzCore
import SwiftUI
import TopographCore

/// Regions as geological layers through time, each in its own 1-bit pattern.
struct StrataScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var strata: StrataModel?
    @State private var tip: StrataTip?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let strata = model.scene?.strata ?? strata, let map = model.map {
                StrataCanvas(model: strata, labels: { map.regions.regions[$0]?.label }, patterns: Dictionary(map.regions.strataLayers().enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }),
                             colors: nil, range: model.scene?.range, marked: markedItem(in: map), theme: theme,
                             onTip: { tip = $0 },
                             onPick: { model.openRegion($0) })
                    // The chart stays clear of the side panel, or recent months end up behind it.
                    .padding(.trailing, model.selection == nil ? 0 : DetailPanel.width)
            } else {
                LoadingNote(text: "laying down the strata", theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let tip {
                Text(tip.text)
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.ink.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.surface.color)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.ink.color, lineWidth: 1))
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: tip.x, y: tip.y)
                    .allowsHitTesting(false)
            }
        }
        .background(theme.ground.color)
        // For a scene made while another view was showing, which has no chart of its own.
        .task(id: model.scene?.id) {
            guard let scene = model.scene, scene.strata == nil, let axis = model.axis else { return }
            let order = model.strataOrder
            strata = await Task.detached(priority: .userInitiated) {
                StrataModel(map: scene.map, visible: scene.visible, axis: axis, order: order)
            }.value
        }
    }
}

extension StrataScreen {
    private func markedItem(in map: LibraryMap) -> MapItem? {
        if case .item(let index) = model.selection { return map.items[Int(index)] }
        return nil
    }
}

struct StrataTip: Equatable {
    let text: String
    let x: Double
    let y: Double
}

struct StrataCanvas: NSViewRepresentable {
    let model: StrataModel
    /// A layer's name, by its key.
    let labels: (Int) -> String?
    /// A layer's pattern, by its key.
    let patterns: [Int: Int]
    /// A layer's color, by its key, in place of a pattern.
    let colors: [Int: CGColor]?
    let range: ClosedRange<Int>?
    let marked: MapItem?
    let theme: Theme
    let onTip: (StrataTip?) -> Void
    let onPick: (Int) -> Void

    func makeNSView(context: Context) -> StrataNSView { StrataNSView() }

    func updateNSView(_ view: StrataNSView, context: Context) {
        view.onTip = onTip
        view.onPick = onPick
        view.update(model: model, labels: labels, patterns: patterns, colors: colors, range: range, marked: marked, theme: theme)
    }
}

final class StrataNSView: NSView {
    private var model: StrataModel?
    private var labels: (Int) -> String? = { _ in nil }
    private var colors: [Int: CGColor]?
    private var range: ClosedRange<Int>?
    private var marked: MapItem?
    private var theme = Theme.light
    private var patternOf: [Int: Int] = [:]
    private var paths: [CGPath] = []
    private var hovered: Int?
    private var tiles: [CGImage] = []
    private var waitingTile: CGImage?
    private var tilesFor: (theme: RGB, scale: Double)?
    private var tracking: NSTrackingArea?
    private var builtFor: CGSize = .zero
    private var shownScale: (low: Double, high: Double)?
    private var scaleLink: CADisplayLink?
    private var lastScaleStep: CFTimeInterval = 0
    /// Layers on their way from where they were on screen, by layer id, and since when.
    private var morph: (from: [Int: (top: [Double], bottom: [Double])], start: CFTimeInterval)?
    private static let morphDuration = 0.55
    private var names: [Int: ShownName] = [:]
    private var lastNameStep: CFTimeInterval = 0
    private var namesMoving = false

    private struct ShownName {
        var name: String
        var center: CGPoint
        var alpha: Double
        /// 1 while it's wanted, 0 once it's on its way out.
        var target: Double
        var goal: CGPoint
        var month: Int
    }

    var onTip: ((StrataTip?) -> Void)?
    var onPick: ((Int) -> Void)?

    private let margin = NSEdgeInsets(top: 24, left: 24, bottom: 28, right: 24)

    override var isFlipped: Bool { true }

    func update(model: StrataModel, labels: @escaping (Int) -> String?, patterns: [Int: Int], colors: [Int: CGColor]?,
                range: ClosedRange<Int>?, marked: MapItem?, theme: Theme) {
        // Amounts and shares are on different scales, so easing the scale would drag every
        // layer through the middle. Each layer goes straight from where it is to where it's going.
        if let shown = self.model, shown.isShare != model.isShare,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            morph = (Dictionary(shown.layers.map { ($0.id, edges(of: $0, model: shown)) }, uniquingKeysWith: { a, _ in a }), CACurrentMediaTime())
            shownScale = (model.low, model.high)
            startMotion()
        }
        self.model = model
        self.labels = labels
        self.colors = colors
        self.range = range
        self.marked = marked
        self.theme = theme
        patternOf = patterns
        builtFor = .zero
        easeScale()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Geometry

    private func x(_ time: Int, axis: MonthAxis) -> Double {
        margin.left + axis.fraction(of: time) * (bounds.width - margin.left - margin.right)
    }

    private func y(_ value: Double, model: StrataModel) -> Double {
        let top = margin.top, bottom = bounds.height - margin.bottom
        let (low, high) = shownScale ?? (model.low, model.high)
        let span = max(high - low, 1e-9)
        return bottom + (value - low) / span * (top - bottom)
    }

    // MARK: Scale

    /// A burst of activity coming into a time range rescales the whole chart. Eased, so
    /// that's a movement rather than a jump.
    private func easeScale() {
        guard let model else { return }
        if shownScale == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            shownScale = (model.low, model.high)
            return
        }
        if !scaleIsSettled(model) { startMotion() }
    }

    /// Runs while the scale or the names are on their way somewhere.
    private func startMotion() {
        guard scaleLink == nil else { return }
        lastScaleStep = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(stepMotion))
        link.add(to: .main, forMode: .common)
        scaleLink = link
    }

    private func scaleIsSettled(_ model: StrataModel) -> Bool {
        guard let shownScale else { return true }
        let tolerance = (model.high - model.low) * 0.001
        return abs(shownScale.low - model.low) <= tolerance && abs(shownScale.high - model.high) <= tolerance
    }

    @objc private func stepMotion() {
        guard let model, let shown = shownScale else { return stopEasing() }
        let now = CACurrentMediaTime()
        if let morph {
            builtFor = .zero
            needsDisplay = true
            if now - morph.start >= Self.morphDuration { self.morph = nil }
            return
        }
        let share = 1 - exp(-(now - lastScaleStep) / 0.09)
        lastScaleStep = now
        if scaleIsSettled(model) {
            if shown != (model.low, model.high) {
                shownScale = (model.low, model.high)
                builtFor = .zero
            }
            if !namesMoving { stopEasing() }
        } else {
            shownScale = (shown.low + (model.low - shown.low) * share, shown.high + (model.high - shown.high) * share)
            builtFor = .zero
        }
        needsDisplay = true
    }

    private func stopEasing() {
        scaleLink?.invalidate()
        scaleLink = nil
    }

    /// Where a layer's edges are on screen right now, month by month.
    private func edges(of layer: StrataModel.Layer, model: StrataModel) -> (top: [Double], bottom: [Double]) {
        let target = (top: layer.top.map { y($0, model: model) }, bottom: layer.bottom.map { y($0, model: model) })
        guard let morph, let from = morph.from[layer.id], from.top.count == target.top.count else { return target }
        let t = min((CACurrentMediaTime() - morph.start) / Self.morphDuration, 1)
        let eased = t * t * (3 - 2 * t)
        func mix(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { $0 + ($1 - $0) * eased } }
        return (mix(from.top, target.top), mix(from.bottom, target.bottom))
    }

    private func buildPaths() {
        guard let model, builtFor != bounds.size else { return }
        builtFor = bounds.size
        let axis = model.axis
        paths = model.layers.map { layer in
            let (top, bottom) = edges(of: layer, model: model)
            let tops = (0..<axis.count).map { CGPoint(x: x(axis.edges[$0], axis: axis), y: top[$0]) }
            let bottoms = (0..<axis.count).reversed().map { CGPoint(x: x(axis.edges[$0], axis: axis), y: bottom[$0]) }
            let path = CGMutablePath()
            BasisCurve.append(tops, to: path, joined: false)
            BasisCurve.append(bottoms, to: path, joined: true)
            path.closeSubpath()
            return path
        }
    }

    // MARK: Patterns

    /// Screens, hatches, rules and checks, from light to dark. In points, y down.
    private static let patterns: [(w: Int, h: Int, rects: [CGRect], lines: [(CGPoint, CGPoint)], stroke: Double)] = [
        (4, 4, [CGRect(x: 0, y: 0, width: 1, height: 1)], [], 0),
        (6, 6, [], [(CGPoint(x: 0, y: 6), CGPoint(x: 6, y: 0))], 1),
        (4, 3, [], [(CGPoint(x: 0, y: 0.5), CGPoint(x: 4, y: 0.5))], 1),
        (3, 3, [CGRect(x: 0, y: 0, width: 1, height: 1)], [], 0),
        (6, 6, [], [(CGPoint(x: 0, y: 6), CGPoint(x: 6, y: 0)), (CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 6))], 0.8),
        (3, 4, [], [(CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 4))], 1),
        (4, 4, [CGRect(x: 0, y: 0, width: 2, height: 2), CGRect(x: 2, y: 2, width: 2, height: 2)], [], 0),
        (5, 5, [], [(CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5))], 1),
        (6, 6, [CGRect(x: 1, y: 1, width: 2, height: 2)], [], 0),
        (8, 4, [], [(CGPoint(x: 0, y: 0.5), CGPoint(x: 4, y: 0.5))], 1),
        (2, 2, [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 1, y: 1, width: 1, height: 1)], [], 0),
        (4, 4, [CGRect(x: 0, y: 0, width: 3, height: 1), CGRect(x: 0, y: 2, width: 1, height: 1)], [], 0),
    ]

    private func tile(w: Int, h: Int, scale: Double, ink: CGColor, draw: (CGContext) -> Void) -> CGImage? {
        let pw = Int(Double(w) * scale), ph = Int(Double(h) * scale)
        guard let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(ph))
        c.scaleBy(x: scale, y: -scale)
        c.setFillColor(theme.ground.cg)
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(ink)
        c.setStrokeColor(ink)
        draw(c)
        return c.makeImage()
    }

    private func buildTiles(scale: Double) {
        if let done = tilesFor, done.scale == scale, done.theme.red == theme.ink.red { return }
        tilesFor = (theme.ink, scale)
        tiles = Self.patterns.compactMap { pattern in
            tile(w: pattern.w, h: pattern.h, scale: scale, ink: theme.ink.cg) { c in
                c.setShouldAntialias(false)
                c.fill(pattern.rects)
                if !pattern.lines.isEmpty {
                    c.setLineWidth(pattern.stroke)
                    for (a, b) in pattern.lines {
                        c.move(to: a)
                        c.addLine(to: b)
                    }
                    c.strokePath()
                }
            }
        }
        waitingTile = tile(w: 8, h: 8, scale: scale, ink: theme.secondary.cg) { c in
            c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let c = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        buildTiles(scale: scale)
        buildPaths()
        let axis = model.axis
        c.setFillColor(theme.ground.cg)
        c.fill(bounds)

        if let range {
            let left = x(range.lowerBound, axis: axis), right = x(range.upperBound, axis: axis)
            c.setFillColor(theme.ink.cg.copy(alpha: 0.07) ?? theme.ink.cg)
            c.fill(CGRect(x: left, y: margin.top - 8, width: max(1, right - left), height: bounds.height - margin.top - margin.bottom + 8))
        }

        for (index, layer) in model.layers.enumerated() {
            c.saveGState()
            if let hovered, hovered != index { c.setAlpha(0.22) }
            if let color = layer.region.flatMap({ colors?[$0] }) {
                // The color's enough to tell a layer from the next, so it needs no outline.
                c.addPath(paths[index])
                c.setFillColor(color)
                c.fillPath()
            } else {
                let tile: CGImage? = layer.region.flatMap { patternOf[$0] }.map { tiles[$0 % tiles.count] } ?? waitingTile
                c.saveGState()
                c.addPath(paths[index])
                c.clip()
                if let tile {
                    c.draw(tile, in: CGRect(x: 0, y: 0, width: Double(tile.width) / scale, height: Double(tile.height) / scale), byTiling: true)
                }
                c.restoreGState()
                c.addPath(paths[index])
                c.setStrokeColor(theme.ink.cg)
                c.setLineWidth(0.75)
                c.strokePath()
            }
            c.restoreGState()
        }
        drawNames(c, model: model)
        drawAxis(c, axis: axis)
        drawMarker(c, model: model)
    }

    /// The open item: a rule at its time, topped with the date, and a square on its layer.
    private func drawMarker(_ c: CGContext, model: StrataModel) {
        guard let marked, let place = model.place(of: marked) else { return }
        let at = x(place.time, axis: model.axis).rounded() + 0.5
        let bottom = bounds.height - margin.bottom

        // A ground-colored edge keeps the rule visible over any pattern.
        c.setStrokeColor(theme.ground.cg)
        c.setLineWidth(3)
        c.move(to: CGPoint(x: at, y: 16))
        c.addLine(to: CGPoint(x: at, y: bottom))
        c.strokePath()
        c.setStrokeColor(theme.ink.cg)
        c.setLineWidth(1)
        c.move(to: CGPoint(x: at, y: 16))
        c.addLine(to: CGPoint(x: at, y: bottom))
        c.strokePath()

        if let height = place.height {
            let square = CGRect(x: at - 7, y: y(height, model: model).rounded() - 7, width: 14, height: 14)
            c.setFillColor(theme.ground.cg)
            c.fill(square.insetBy(dx: -2, dy: -2))
            c.setFillColor(theme.ink.cg)
            c.stroke(square.insetBy(dx: 0.5, dy: 0.5))
            c.fill(square.insetBy(dx: 4, dy: 4))
        }

        let font = NSFont(name: "IBMPlexMono-Medium", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .medium)
        let date = NSAttributedString(string: Format.month(place.time), attributes: [.font: font, .foregroundColor: NSColor(cgColor: theme.ground.cg) ?? .white])
        let size = date.size()
        let width = size.width + 10
        let box = CGRect(x: min(max(at - width / 2, 0), bounds.width - width), y: 0, width: width, height: 16)
        c.setFillColor(theme.ink.cg)
        c.fill(box)
        date.draw(at: CGPoint(x: box.minX + 5, y: (16 - size.height) / 2))
    }

    /// Name each layer where the whole name fits inside it: the stretch of months under
    /// the label must all be at least a line tall.
    ///
    /// The best spot changes with every step of a moving time range. So a name stays at its
    /// month until a clearly better one comes along, shown names keep their place over new
    /// ones, and each eases to where it's going, fading in or out when it comes or goes.
    private func drawNames(_ c: CGContext, model: StrataModel) {
        let axis = model.axis
        let step = (bounds.width - margin.left - margin.right) / max(1, Double(axis.count - 1))
        func thinnest(_ layer: StrataModel.Layer, around month: Int, half: Int) -> Double {
            var lowest = Double.infinity
            for j in (month - half)...(month + half) {
                lowest = min(lowest, y(layer.bottom[j], model: model) - y(layer.top[j], model: model))
            }
            return lowest
        }
        var candidates: [(best: Double, month: Int, layer: StrataModel.Layer, id: Int, name: String)] = []
        for layer in model.layers {
            guard let id = layer.region, let name = labels(id) else { continue }
            let half = Int((((Double(name.count) * 6.8 + 10) / 2) / step).rounded(.up))
            guard half < axis.count - half else { continue }
            var best = -1.0, at = -1
            for i in half..<(axis.count - half) {
                let lowest = thinnest(layer, around: i, half: half)
                if lowest > best {
                    best = lowest
                    at = i
                }
            }
            if let shown = names[id], shown.target > 0, shown.month >= half, shown.month < axis.count - half {
                let there = thinnest(layer, around: shown.month, half: half)
                if there >= 14, there >= best * 0.7 {
                    best = there
                    at = shown.month
                }
            }
            if at >= 0, best >= 14 { candidates.append((best, at, layer, id, name)) }
        }

        let font = NSFont(name: "IBMPlexMono-Medium", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        func favored(_ candidate: (best: Double, month: Int, layer: StrataModel.Layer, id: Int, name: String)) -> Double {
            (names[candidate.id]?.target ?? 0) > 0 ? candidate.best * 1.5 : candidate.best
        }
        var placed: [CGRect] = []
        var wanted: Set<Int> = []
        for candidate in candidates.sorted(by: { favored($0) > favored($1) }) {
            // On screen as it is now, so a name stays with its layer while the layers change over.
            let shownEdges = edges(of: candidate.layer, model: model)
            let middle = (shownEdges.bottom[candidate.month] + shownEdges.top[candidate.month]) / 2
            let size = NSAttributedString(string: candidate.name, attributes: [.font: font]).size()
            let center = CGPoint(x: x(axis.edges[candidate.month], axis: axis), y: middle)
            let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            if placed.contains(where: { $0.intersects(rect) }) { continue }
            placed.append(rect)
            wanted.insert(candidate.id)
            var shown = names[candidate.id] ?? ShownName(name: candidate.name, center: center, alpha: 0, target: 1, goal: center, month: candidate.month)
            shown.name = candidate.name
            // Coming back after fading out, it starts where it's going, not where it was.
            if shown.alpha == 0 { shown.center = center }
            shown.goal = center
            shown.target = 1
            shown.month = candidate.month
            names[candidate.id] = shown
        }
        for id in names.keys where !wanted.contains(id) { names[id]?.target = 0 }

        let now = CACurrentMediaTime()
        let elapsed = min(now - lastNameStep, 0.05)
        lastNameStep = now
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let move = still ? 1 : 1 - exp(-elapsed / 0.12)
        let fade = still ? 1 : elapsed / 0.14
        var moving = false
        for (id, var shown) in names {
            shown.center.x += (shown.goal.x - shown.center.x) * move
            shown.center.y += (shown.goal.y - shown.center.y) * move
            if abs(shown.goal.x - shown.center.x) < 0.25, abs(shown.goal.y - shown.center.y) < 0.25 {
                shown.center = shown.goal
            } else {
                moving = true
            }
            shown.alpha = shown.target > shown.alpha ? min(shown.target, shown.alpha + fade) : max(shown.target, shown.alpha - fade)
            if shown.alpha != shown.target { moving = true }
            if shown.alpha == 0, shown.target == 0 {
                names[id] = nil
                continue
            }
            names[id] = shown

            let fill = NSAttributedString(string: shown.name, attributes: [.font: font, .foregroundColor: NSColor(cgColor: theme.ink.cg) ?? .black])
            let size = fill.size()
            let rect = CGRect(x: shown.center.x - size.width / 2, y: shown.center.y - size.height / 2, width: size.width, height: size.height)
            let halo = NSAttributedString(string: shown.name, attributes: [
                .font: font, .strokeColor: NSColor(cgColor: theme.ground.cg) ?? .white, .strokeWidth: 36,
            ])
            c.saveGState()
            c.setAlpha(shown.alpha)
            halo.draw(in: rect)
            fill.draw(in: rect)
            c.restoreGState()
        }
        namesMoving = moving
        if moving { startMotion() }
    }

    private func drawAxis(_ c: CGContext, axis: MonthAxis) {
        let top = bounds.height - margin.bottom
        c.setStrokeColor(theme.ink.cg)
        c.setLineWidth(1)
        c.move(to: CGPoint(x: margin.left, y: top + 0.5))
        c.addLine(to: CGPoint(x: bounds.width - margin.right, y: top + 0.5))
        let font = NSFont(name: "IBMPlexMono-Regular", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: theme.secondary.cg) ?? .gray]
        for year in axis.years() {
            let at = x(year.time, axis: axis).rounded() + 0.5
            c.move(to: CGPoint(x: at, y: top))
            c.addLine(to: CGPoint(x: at, y: top + 5))
            let text = NSAttributedString(string: String(year.year), attributes: attributes)
            text.draw(at: CGPoint(x: at - text.size().width / 2, y: top + 7))
        }
        c.strokePath()
    }

    // MARK: Pointer

    private func layerIndex(at point: CGPoint) -> Int? {
        paths.indices.reversed().first { paths[$0].contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = layerIndex(at: point)
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
        guard let index else {
            onTip?(nil)
            return
        }
        let layer = model.layers[index]
        let axis = model.axis
        let fraction = (point.x - margin.left) / (bounds.width - margin.left - margin.right)
        let time = axis.time(atFraction: fraction)
        let month = axis.index(of: time)
        let raw = month.map { layer.raw[$0] } ?? 0
        let name = layer.region.flatMap(labels) ?? "not yet mapped (links waiting for images)"
        let amount = layer.region == nil ? "\(Int(raw)) links" : "resonance \(String(format: "%.1f", raw))"
        onTip?(StrataTip(text: "\(name)  \(Format.month(time))  \(amount)",
                         x: min(point.x + 12, bounds.width - 270), y: point.y + 12))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        onTip?(nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, let index = layerIndex(at: convert(event.locationInWindow, from: nil)),
              let region = model.layers[index].region else { return }
        onPick?(region)
    }
}
