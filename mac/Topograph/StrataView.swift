import AppKit
import QuartzCore
import SwiftUI
import TopographCore

/// Regions as geological layers through time, each in its own 1-bit pattern.
struct StrataScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var tip: StrataTip?

    /// The chart stays clear of the side panel, or recent months end up behind it.
    private var panel: Double { model.selection == nil ? 0 : DetailPanel.width }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Always all of time, for the filters set: the selection moves the view and the
            // shading, never the shape.
            if let strata = model.strataChart, let map = model.map {
                let window = model.strataWindow
                StrataCanvas(model: strata, labels: { map.regions.regions[$0]?.label }, patterns: Dictionary(map.regions.strataLayers().enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }),
                             colors: nil, range: model.strataShowsSelection && model.strataHold == nil ? nil : model.filter.range, marked: markedItem(in: map), theme: theme,
                             window: window, easing: model.strataEasingTo == window, quiet: model.pointerIsOnStrataMinimap,
                             isPlaying: model.isPlaying,
                             onTip: { tip = $0 },
                             onPick: { model.openRegion($0) },
                             onZoom: { model.zoomStrata(by: $0, atX: $1, width: $2, inset: $3) },
                             onPan: { model.panStrata(byX: $0, width: $1, inset: $2) })
                    .padding(.trailing, panel)
                controls
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
        .onAppear { model.prepareStrataChart() }
    }
}

extension StrataScreen {
    /// What sits on the canvas: the switch, the zoom keys, and while it's fitted to a selection,
    /// a minimap to show where that is in all of time.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            if (model.map?.waiting ?? 0) > 0 {
                Button("not yet mapped") { model.strataShowsWaiting.toggle() }
                    .buttonStyle(KeyStyle(theme: theme, led: model.strataShowsWaiting))
                    .help("A layer for links still waiting for their pictures, by when you engaged with them.")
                    .padding(.trailing, 8)
            }
            // Either way the selection stays, unlike the timeline's "all time", which clears it.
            Button("close up") { model.strataShowsSelection = true }
                .buttonStyle(KeyStyle(theme: theme, led: model.strataShowsSelection))
                .help("Fit the chart to the time selected")
            Button("in context") { model.strataShowsSelection = false }
                .buttonStyle(KeyStyle(theme: theme, led: !model.strataShowsSelection))
                .help("Show all of time, with the selection shaded")
        }
        .padding(.top, 12)
        .padding(.trailing, 16 + panel)
        .frame(maxWidth: .infinity, alignment: .trailing)
        VStack(spacing: 4) {
            Spacer()
            // Their shortcuts are in the Map menu. Stacked this closely, labels go to the side.
            Button("+", action: model.zoomIn).accessibilityLabel("Zoom in")
                .hotkey("⌘+", placement: .beside, model: model, theme: theme)
            Button("−", action: model.zoomOut).accessibilityLabel("Zoom out")
                .hotkey("⌘-", placement: .beside, model: model, theme: theme)
            Button("fit", action: model.fit).accessibilityLabel("Show everything")
                .hotkey("⌘0", placement: .beside, model: model, theme: theme)
        }
        .buttonStyle(SquareKeyStyle(theme: theme))
        .padding(.trailing, 16 + panel)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, alignment: .trailing)
        if model.strataShowsSelection, !model.strataWindow.isWhole, let overview = model.strataChart {
            StrataMinimap(model: overview, selection: model.strataWindow, theme: theme,
                          onMove: { model.centerStrataSelection(at: $0) },
                          onPointer: { model.pointerIsOnStrataMinimap = $0 })
                .padding(.leading, 16)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

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

/// A small Strata of all of time, with what's selected outlined, the same part the timeline
/// shows. Press or drag to move it: taking hold of the outline moves it from there, and
/// anywhere else jumps to that spot.
private struct StrataMinimap: View {
    let model: StrataModel
    let selection: StrataWindow
    let theme: Theme
    let onMove: (Double) -> Void
    let onPointer: (Bool) -> Void
    @State private var grab: Double?
    private let size = CGSize(width: 320, height: 88)

    var body: some View {
        // Never too small to see or to take hold of.
        let width = max(selection.span * size.width, 6)
        let middle = (selection.start + selection.end) / 2 * size.width
        let left = min(max(middle - width / 2, 0), size.width - width)
        ZStack(alignment: .topLeading) {
            theme.surface.color
            Canvas { context, canvas in draw(in: &context, size: canvas) }
            // What isn't selected stands back, so the outline reads over any part of it.
            theme.surface.color.opacity(0.6).frame(width: left)
            theme.surface.color.opacity(0.6)
                .frame(width: max(size.width - left - width, 0))
                .offset(x: left + width)
            Rectangle()
                .strokeBorder(theme.ink.color, lineWidth: 1.5)
                .frame(width: width, height: size.height)
                .offset(x: left)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.ink.color, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grab == nil {
                    grab = abs(value.startLocation.x - middle) <= width / 2 ? value.startLocation.x - middle : 0
                    NSCursor.closedHand.set()
                }
                onMove((value.location.x - (grab ?? 0)) / size.width)
            }
            .onEnded { _ in
                grab = nil
                NSCursor.openHand.set()
            })
        .onContinuousHover { phase in
            if case .active = phase {
                onPointer(true)
                if grab == nil { NSCursor.openHand.set() }
            } else {
                onPointer(false)
                NSCursor.arrow.set()
            }
        }
        .onDisappear { onPointer(false) }
        .accessibilityLabel("Minimap")
    }

    /// The layers as one dark shape with a light line between each, since patterns are too
    /// coarse to show at this size.
    private func draw(in context: inout GraphicsContext, size canvas: CGSize) {
        let axis = model.axis
        let span = max(model.high - model.low, 1e-9)
        func point(_ month: Int, _ value: Double) -> CGPoint {
            CGPoint(x: axis.fraction(of: axis.edges[month]) * canvas.width,
                    y: canvas.height - 3 - (value - model.low) / span * (canvas.height - 6))
        }
        for layer in model.layers {
            let path = CGMutablePath()
            BasisCurve.append((0..<axis.count).map { point($0, layer.top[$0]) }, to: path, joined: false)
            BasisCurve.append((0..<axis.count).reversed().map { point($0, layer.bottom[$0]) }, to: path, joined: true)
            path.closeSubpath()
            context.fill(Path(path), with: .color(theme.ink.color))
            context.stroke(Path(path), with: .color(theme.surface.color), lineWidth: 0.5)
        }
    }
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
    /// The part of time to show, and whether to ease there or follow it directly.
    var window = StrataWindow.whole
    var easing = false
    /// Whether the pointer is on something above the chart, so it shouldn't answer.
    var quiet = false
    /// While the timeline plays, space pauses it instead of moving the chart.
    var isPlaying = false
    let onTip: (StrataTip?) -> Void
    let onPick: (Int) -> Void
    /// Zooming by a factor at a place on the canvas, of a width, with an inset, and moving by
    /// an amount. Without them, the chart stays put.
    var onZoom: ((Double, Double, Double, Double) -> Void)?
    var onPan: ((Double, Double, Double) -> Void)?

    func makeNSView(context: Context) -> StrataNSView { StrataNSView() }

    func updateNSView(_ view: StrataNSView, context: Context) {
        view.onTip = onTip
        view.onPick = onPick
        view.onZoom = onZoom
        view.onPan = onPan
        view.quiet = quiet
        view.isPlaying = isPlaying
        view.show(window, easing: easing)
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
    /// How fast the shown scale is moving, per second: it springs to fit rather than lurching.
    private var scaleVelocity = (low: 0.0, high: 0.0)
    private var lastSpringStep: CFTimeInterval = 0
    /// The spring's stiffness: critically damped, it settles in about half a second.
    private static let scaleSpring = 9.0
    private var scaleLink: CADisplayLink?
    private var lastScaleStep: CFTimeInterval = 0
    /// Layers on their way from where they were on screen, by layer id, and since when.
    private var morph: (from: [Int: (top: [Double], bottom: [Double])], start: CFTimeInterval)?
    private static let morphDuration = 0.55
    /// When the chart last changed, to tell a change on its own from a stream of them.
    private var lastChange: CFTimeInterval = 0
    private var names: [Int: ShownName] = [:]
    private var lastNameStep: CFTimeInterval = 0
    private var namesMoving = false
    /// The part of time on screen right now, what it was last told to show, and where it's easing to.
    private var shownTime = StrataWindow.whole
    private var asked = StrataWindow.whole
    private var windowGoal: StrataWindow?
    fileprivate var isPlaying = false
    /// Space is down, so a drag moves along time.
    private var spaceHeld = false
    /// Where a drag that's moving along time last was.
    private var panningFrom: Double?
    /// Whether the press going on now began with space down, so letting go shouldn't pick a layer.
    private var pressMovesChart = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    fileprivate var quiet = false {
        didSet {
            guard quiet, !oldValue else { return }
            hovered = nil
            onTip?(nil)
            needsDisplay = true
        }
    }

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
    var onZoom: ((Double, Double, Double, Double) -> Void)?
    var onPan: ((Double, Double, Double) -> Void)?

    private let margin = NSEdgeInsets(top: 24, left: 24, bottom: 28, right: 24)

    override var isFlipped: Bool { true }

    func update(model: StrataModel, labels: @escaping (Int) -> String?, patterns: [Int: Int], colors: [Int: CGColor]?,
                range: ClosedRange<Int>?, marked: MapItem?, theme: Theme) {
        // Amounts and shares are on different scales, so easing the scale would drag every
        // layer through the middle. Each layer goes straight from where it is to where it's going.
        //
        // A change on its own, like clearing a selection, morphs the same way, so what was
        // hidden grows back in. A stream of them, from playing or dragging along time, is
        // followed directly, so the chart never trails behind.
        if let shown = self.model, !Self.sameShape(shown, model) {
            let now = CACurrentMediaTime()
            let alone = now - lastChange > 0.15 && !isPlaying
            lastChange = now
            if shown.isShare != model.isShare || alone, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                morph = (Dictionary(shown.layers.map { ($0.id, edges(of: $0, model: shown)) }, uniquingKeysWith: { a, _ in a }), now)
                // The morph goes from where layers are on screen, so the scale can be the new one at once.
                shownScale = scaleGoal(model)
                scaleVelocity = (0, 0)
                startMotion()
            }
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

    private static func sameShape(_ a: StrataModel, _ b: StrataModel) -> Bool {
        a.layers.count == b.layers.count && zip(a.layers, b.layers).allSatisfy { $0.id == $1.id && $0.top == $1.top && $0.bottom == $1.bottom }
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
        shownTime.x(ofFraction: axis.fraction(of: time), width: bounds.width, inset: margin.left)
    }

    /// The months on screen, first and last, with the one past each end.
    private func monthsShown(_ axis: MonthAxis) -> ClosedRange<Int> {
        let first = axis.index(of: axis.time(atFraction: shownTime.start)) ?? 0
        let last = axis.index(of: axis.time(atFraction: shownTime.end)) ?? axis.count - 1
        return first...max(first, last)
    }

    /// Show a part of time, easing there if asked to. Names keep their place in time as it moves.
    fileprivate func show(_ next: StrataWindow, easing: Bool) {
        guard next != asked else { return }
        asked = next
        if easing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            windowGoal = next
            startMotion()
        } else {
            windowGoal = nil
            place(next)
        }
    }

    private func place(_ next: StrataWindow) {
        guard next != shownTime else { return }
        for (id, shown) in names {
            let center = shownTime.fraction(atX: shown.center.x, width: bounds.width, inset: margin.left)
            let goal = shownTime.fraction(atX: shown.goal.x, width: bounds.width, inset: margin.left)
            names[id]?.center.x = next.x(ofFraction: center, width: bounds.width, inset: margin.left)
            names[id]?.goal.x = next.x(ofFraction: goal, width: bounds.width, inset: margin.left)
        }
        shownTime = next
        builtFor = .zero
        needsDisplay = true
        // What's in view has changed, so its height may have.
        if let model, !scaleIsSettled(model) { startMotion() }
    }

    private func y(_ value: Double, model: StrataModel) -> Double {
        let top = margin.top, bottom = bounds.height - margin.bottom
        let (low, high) = shownScale ?? scaleGoal(model)
        let span = max(high - low, 1e-9)
        return bottom + (value - low) / span * (top - bottom)
    }

    // MARK: Scale

    /// Moving to a busier or quieter stretch of time rescales the chart's height. Eased, so
    /// that's a movement rather than a jump.
    private func easeScale() {
        guard let model else { return }
        if shownScale == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            shownScale = scaleGoal(model)
            scaleVelocity = (0, 0)
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
        let goal = scaleGoal(model)
        let tolerance = (goal.high - goal.low) * 0.001
        return abs(shownScale.low - goal.low) <= tolerance && abs(shownScale.high - goal.high) <= tolerance
            && abs(scaleVelocity.low) + abs(scaleVelocity.high) <= tolerance * 20
    }

    /// The height that fits what's on screen: the chart's whole on all of time, and only what's
    /// in view close up, so a quiet stretch still fills the chart. The shape is all of time's
    /// either way; only its height follows you around it.
    ///
    /// It fits where the view is going, so height and time arrive together rather than the
    /// height chasing each step of the way. And it slides across part-shown months at the
    /// edges rather than jumping a month at a time, so scrolling stays smooth.
    private func scaleGoal(_ model: StrataModel) -> (low: Double, high: Double) {
        let window = windowGoal ?? shownTime
        let axis = model.axis
        guard !window.isWhole, axis.count > 1 else { return (model.low, model.high) }
        // Months from the start, continuously: each month's value is drawn at its first edge.
        func position(_ fraction: Double) -> Double {
            let time = axis.time(atFraction: fraction)
            guard let month = axis.index(of: time) else { return fraction <= 0.5 ? 0 : Double(axis.count - 1) }
            return Double(month) + Double(time - axis.edges[month]) / Double(max(axis.edges[month + 1] - axis.edges[month], 1))
        }
        let from = min(max(position(window.start), 0), Double(axis.count - 1))
        let to = min(max(position(window.end), from), Double(axis.count - 1))
        func at(_ values: [Double], _ p: Double) -> Double {
            let below = Int(p.rounded(.down)), above = min(below + 1, values.count - 1)
            return values[below] + (values[above] - values[below]) * (p - Double(below))
        }
        var low = Double.infinity, high = -Double.infinity
        for layer in model.layers {
            high = max(high, at(layer.top, from), at(layer.top, to))
            low = min(low, at(layer.bottom, from), at(layer.bottom, to))
            var month = Int(from.rounded(.up))
            while Double(month) <= to {
                high = max(high, layer.top[month])
                low = min(low, layer.bottom[month])
                month += 1
            }
        }
        return low < high ? (low, high) : (model.low, model.high)
    }

    @objc private func stepMotion() {
        guard let model, shownScale != nil else { return stopEasing() }
        let now = CACurrentMediaTime()
        let elapsed = now - lastScaleStep
        lastScaleStep = now
        if let goal = windowGoal {
            let share = 1 - exp(-elapsed / 0.07)
            if abs(goal.start - shownTime.start) + abs(goal.end - shownTime.end) < 0.0005 {
                windowGoal = nil
                place(goal)
            } else {
                place(StrataWindow(start: shownTime.start + (goal.start - shownTime.start) * share,
                                   end: shownTime.end + (goal.end - shownTime.end) * share))
            }
        }
        if let morph {
            builtFor = .zero
            needsDisplay = true
            if now - morph.start >= Self.morphDuration { self.morph = nil }
            return
        }
        // The height springs as each frame is drawn (`stepScale`), not here: a flick moves time
        // as its events arrive, and stepping the height on this timer instead put the two out
        // of step, frame by frame, as the flick slowed.
        if scaleIsSettled(model), !namesMoving, windowGoal == nil { return stopEasing() }
        needsDisplay = true
    }

    /// Moves the height toward its fit by the time since the last frame drawn, so it moves in
    /// the same frames as time does.
    private func stepScale(_ model: StrataModel) {
        guard morph == nil, let shown = shownScale else { return }
        let now = CACurrentMediaTime()
        // Short steps, so a dropped frame doesn't throw the spring.
        let dt = min(max(now - lastSpringStep, 0), 1.0 / 30)
        lastSpringStep = now
        let goal = scaleGoal(model)
        if scaleIsSettled(model) {
            scaleVelocity = (0, 0)
            if shown != goal {
                shownScale = goal
                builtFor = .zero
            }
            return
        }
        // A critically damped spring: it starts gently, and arrives without overshooting.
        let w = Self.scaleSpring
        func spring(_ x: Double, _ v: inout Double, _ target: Double) -> Double {
            v += (w * w * (target - x) - 2 * w * v) * dt
            return x + v * dt
        }
        var v = scaleVelocity
        shownScale = (spring(shown.low, &v.low, goal.low), spring(shown.high, &v.high, goal.high))
        scaleVelocity = v
        builtFor = .zero
        // Frames keep coming until it settles.
        startMotion()
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
        // Only what's on screen, with enough on each side for the curves to arrive from.
        let shown = monthsShown(axis)
        let months = max(shown.lowerBound - 3, 0)...min(shown.upperBound + 3, axis.count - 1)
        paths = model.layers.map { layer in
            let (top, bottom) = edges(of: layer, model: model)
            let tops = months.map { CGPoint(x: x(axis.edges[$0], axis: axis), y: top[$0]) }
            let bottoms = months.reversed().map { CGPoint(x: x(axis.edges[$0], axis: axis), y: bottom[$0]) }
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
        stepScale(model)
        buildPaths()
        let axis = model.axis
        c.setFillColor(theme.ground.cg)
        c.fill(bounds)

        if let range {
            let left = x(range.lowerBound, axis: axis), right = x(range.upperBound, axis: axis)
            c.setFillColor(theme.ink.cg.copy(alpha: 0.07) ?? theme.ink.cg)
            c.fill(CGRect(x: left, y: margin.top - 8, width: max(1, right - left), height: bounds.height - margin.top - margin.bottom + 8))
        }

        let side = shownTime.inset(margin.left)
        c.saveGState()
        c.clip(to: CGRect(x: side, y: 0, width: bounds.width - 2 * side, height: bounds.height))
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
        c.restoreGState()
        drawNames(c, model: model)
        drawAxis(c, axis: axis)
        drawMarker(c, model: model)
    }

    /// The open item: a rule at its time, topped with the date, and a square on its layer.
    private func drawMarker(_ c: CGContext, model: StrataModel) {
        guard let marked, let place = model.place(of: marked) else { return }
        let at = x(place.time, axis: model.axis).rounded() + 0.5
        guard at >= 0, at <= bounds.width else { return }
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
        let side = shownTime.inset(margin.left)
        let step = (bounds.width - 2 * side) / max(1, Double(axis.count - 1) * shownTime.span)
        let months = monthsShown(axis)
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
            // The whole name has to be on screen.
            let first = max(half, months.lowerBound + half), past = min(axis.count - half, months.upperBound - half + 1)
            guard first < past else { continue }
            var best = -1.0, at = -1
            for i in first..<past {
                let lowest = thinnest(layer, around: i, half: half)
                if lowest > best {
                    best = lowest
                    at = i
                }
            }
            if let shown = names[id], shown.target > 0, shown.month >= first, shown.month < past {
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

    private static let monthName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()

    /// Years, and once there's room, months. A year keeps its place over a month beside it,
    /// and with no new year on screen, the first month says which it is.
    private func drawAxis(_ c: CGContext, axis: MonthAxis) {
        let top = bounds.height - margin.bottom
        let side = shownTime.inset(margin.left)
        c.setStrokeColor(theme.ink.cg)
        c.setLineWidth(1)
        c.move(to: CGPoint(x: side, y: top + 0.5))
        c.addLine(to: CGPoint(x: bounds.width - side, y: top + 0.5))
        let font = NSFont(name: "IBMPlexMono-Regular", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: theme.secondary.cg) ?? .gray]
        var taken: [CGRect] = []
        func label(_ string: String, at x: Double) {
            let text = NSAttributedString(string: string, attributes: attributes)
            let size = text.size()
            // At the sides of the canvas, it stays whole.
            let rect = CGRect(x: min(max(x - size.width / 2, 2), bounds.width - size.width - 2), y: top + 7,
                              width: size.width, height: size.height)
            guard !taken.contains(where: { $0.insetBy(dx: -4, dy: 0).intersects(rect) }) else { return }
            taken.append(rect)
            text.draw(at: rect.origin)
        }
        let years = axis.years().filter { (-1...bounds.width + 1).contains(x($0.time, axis: axis)) }
        for year in years {
            let at = x(year.time, axis: axis).rounded() + 0.5
            c.move(to: CGPoint(x: at, y: top))
            c.addLine(to: CGPoint(x: at, y: top + 5))
            label(String(year.year), at: at)
        }
        let perMonth = (bounds.width - 2 * side) / max(1, Double(axis.count) * shownTime.span)
        if perMonth >= 10 {
            let shown = monthsShown(axis)
            let calendar = Calendar.current
            let firstVisible = shown.first { x(axis.edges[$0], axis: axis) >= 24 }
            for month in shown {
                let at = x(axis.edges[month], axis: axis).rounded() + 0.5
                guard (-1...bounds.width + 1).contains(at) else { continue }
                c.move(to: CGPoint(x: at, y: top))
                c.addLine(to: CGPoint(x: at, y: top + 3))
                let date = Date(timeIntervalSince1970: TimeInterval(axis.edges[month]))
                guard calendar.component(.month, from: date) != 1, perMonth >= 28 else { continue }
                let name = Self.monthName.string(from: date).lowercased()
                label(month == firstVisible && years.isEmpty ? "\(name) \(calendar.component(.year, from: date))" : name, at: at)
            }
        }
        c.strokePath()
    }

    // MARK: Pointer

    private func layerIndex(at point: CGPoint) -> Int? {
        paths.indices.reversed().first { paths[$0].contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let model, !quiet, !spaceHeld else { return }
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
        let fraction = shownTime.fraction(atX: point.x, width: bounds.width, inset: margin.left)
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

    /// Scrolling up and down zooms around the pointer, and sideways moves along the chart.
    override func scrollWheel(with event: NSEvent) {
        guard let onZoom, let onPan else { return super.scrollWheel(with: event) }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas, abs(dx) > abs(dy) {
            onPan(dx, bounds.width, margin.left)
        } else {
            let at = convert(event.locationInWindow, from: nil).x
            onZoom(pow(2, dy * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)), at, bounds.width, margin.left)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let onZoom else { return super.magnify(with: event) }
        onZoom(1 + event.magnification, convert(event.locationInWindow, from: nil).x, bounds.width, margin.left)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
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
        guard event.window === window, event.keyCode == 49, onPan != nil else { return event }
        if event.type == .keyUp {
            guard spaceHeld else { return event }
            setSpaceHeld(false)
            return nil
        }
        guard !isPlaying, !(window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        // Still down from the press that paused playing, it isn't asking to move the chart.
        if event.isARepeat, !spaceHeld { return nil }
        setSpaceHeld(true)
        return nil
    }

    private func setSpaceHeld(_ held: Bool) {
        guard held != spaceHeld else { return }
        spaceHeld = held
        if held {
            hovered = nil
            onTip?(nil)
            needsDisplay = true
        }
        updateCursor()
    }

    private var cursor: NSCursor {
        panningFrom != nil ? .closedHand : spaceHeld ? .openHand : .arrow
    }

    private func updateCursor() {
        window?.invalidateCursorRects(for: self)
        cursor.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        pressMovesChart = spaceHeld
        guard spaceHeld else { return }
        panningFrom = convert(event.locationInWindow, from: nil).x
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = panningFrom else { return }
        let x = convert(event.locationInWindow, from: nil).x
        panningFrom = x
        onPan?(x - from, bounds.width, margin.left)
    }

    override func mouseUp(with event: NSEvent) {
        if pressMovesChart {
            pressMovesChart = false
            panningFrom = nil
            updateCursor()
            return
        }
        guard let model, let index = layerIndex(at: convert(event.locationInWindow, from: nil)),
              let region = model.layers[index].region else { return }
        onPick?(region)
    }
}
