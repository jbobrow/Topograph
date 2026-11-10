import SwiftUI
import TopographCore

/// Where things came from, what you did, what they are, how pictures show, and find: in one
/// row, or two when the window is narrow.
struct FilterBar: View {
    @Bindable var model: AppModel
    let theme: Theme
    @FocusState private var findFocused: Bool
    /// A try to turn off the last of a pair, which has to keep one on.
    @State private var lastOff: LastOff?

    private static let kinds: [(ContentKinds, String, KeyEquivalent)] = [
        (.image, "image", "i"), (.text, "text", "u"),
    ]

    private static let groups: [(ActionGroups, String, KeyEquivalent)] = [
        (.creation, "creation", "["), (.consumption, "consumption", "]"),
    ]

    private static let imageKeys: [ImageMode: KeyEquivalent] = [.color: "l", .gray: "g", .dither: "b"]

    var body: some View {
        // One row when the window has room, else find and the sources above the rest.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                platforms
                filters
                Spacer(minLength: 0)
                find
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    platforms
                    Spacer(minLength: 0)
                    find
                }
                HStack(spacing: 14) {
                    filters
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .task(id: lastOff) {
            guard let tried = lastOff else { return }
            try? await Task.sleep(for: .seconds(2))
            // A newer try has started its own two seconds.
            if !Task.isCancelled, lastOff == tried { lastOff = nil }
        }
        .task(id: FindRequest(query: model.findQuery, byMeaning: model.findsByMeaning)) {
            // Wait for a pause in the typing.
            try? await Task.sleep(for: .milliseconds(model.findsByMeaning ? 300 : 150))
            guard !Task.isCancelled else { return }
            await model.find(model.findQuery)
        }
    }

    /// What things are, what you did, the terrain's own keys, and how pictures show.
    @ViewBuilder
    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(Self.groups, id: \.1) { group, label, key in
                Button(label) {
                    if !model.filter.groups.isSuperset(of: group) {
                        model.filter.groups.formUnion(group)
                    } else if model.filter.groups != group {
                        model.filter.groups.subtract(group)
                    } else {
                        // The last one stays on: with neither, the map would be empty.
                        lastOff = LastOff(pair: "groups")
                    }
                }
                .buttonStyle(KeyStyle(theme: theme, led: model.filter.groups.isSuperset(of: group)))
                .hotkey("⌘\(key.character)", key: key, model: model, theme: theme)
            }
        }
        .overlay(alignment: .topLeading) { staysOn("groups") }
        HStack(spacing: 4) {
            ForEach(Self.kinds, id: \.1) { kind, label, key in
                Button(label) {
                    if !model.filter.kinds.contains(kind) {
                        model.filter.kinds.insert(kind)
                    } else if model.filter.kinds != kind {
                        model.filter.kinds.remove(kind)
                    } else {
                        lastOff = LastOff(pair: "kinds")
                    }
                }
                .buttonStyle(KeyStyle(theme: theme, led: model.filter.kinds.contains(kind)))
                .hotkey("⌘\(key.character)", key: key, model: model, theme: theme)
            }
            // The terrain's own: they do nothing on the other views.
            if model.section == .terrain {
                Button("clouds") { model.showsClouds.toggle() }
                    .buttonStyle(KeyStyle(theme: theme, led: model.showsClouds))
                    .hotkey("⌘K", key: "k", model: model, theme: theme)
                    .disabled(model.map?.clouds.isEmpty ?? true)
                    .help(model.map?.clouds.isEmpty ?? true
                          ? "Searches float over the map once Google activity is imported and the map is updated."
                          : "Your searches as weather: where the season before the time shown searched more than usual.")
            }
        }
        .overlay(alignment: .topLeading) { staysOn("kinds") }
        if model.section == .terrain {
            Button("markers") { model.showsMarkers.toggle() }
                .buttonStyle(KeyStyle(theme: theme, led: model.showsMarkers))
                .hotkey("⌘J", key: "j", model: model, theme: theme)
                .help("Hidden, they show only around the pointer, so the terrain reads on its own.")
        }
        UpwardPicker(title: "Pictures in", options: ImageMode.allCases, selection: $model.imageMode,
                     label: \.label, theme: theme, opensDown: true)
            .help("How pictures show: ⌘L color, ⌘G gray, ⌘B 1-bit")
            .background {
                ForEach(ImageMode.allCases, id: \.self) { mode in
                    Button("") { model.imageMode = mode }
                        .keyboardShortcut(Self.imageKeys[mode] ?? "g", modifiers: .command)
                        .hidden()
                }
            }
    }

    private var platforms: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.platforms.enumerated()), id: \.element) { position, platform in
                Button(Format.platform(platform)) {
                    // Worked out here, on the press: a keyboard shortcut can keep calling
                    // the action it first had, and one holding the state from back then
                    // would only ever do the same thing.
                    if model.filter.hiddenPlatforms.contains(platform) {
                        model.filter.hiddenPlatforms.remove(platform)
                    } else {
                        model.filter.hiddenPlatforms.insert(platform)
                    }
                }
                .buttonStyle(KeyStyle(theme: theme, led: !model.filter.hiddenPlatforms.contains(platform)))
                // ⌥, since ⇧⌘3, ⇧⌘4 and ⇧⌘5 are the system's screenshots.
                .hotkey("⌥⌘\(position + 1)", key: KeyEquivalent(Character(String(position + 1))), modifiers: [.command, .option], model: model, theme: theme)
            }
        }
    }

    private var find: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                Button { findFocused = true } label: {
                    Text("find")
                        .font(PlexMono.font(.regular, size: 11))
                        .foregroundStyle(theme.secondary.color)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) { Rectangle().fill(theme.rule.color).frame(width: 1) }
                TextField("", text: $model.findQuery, prompt: Text(model.findsByMeaning ? "what it's about" : "words or @author").foregroundStyle(theme.secondary.color))
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.ink.color)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 120, maxWidth: 190)
            }
            .frame(height: 26)
            .background(theme.surface.color)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if model.findingByMeaning > 0 {
                    LoadingNote(text: "reading for meaning", theme: theme)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(theme.surface.color, in: Rectangle())
                        .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                        .offset(y: 24)
                        .allowsHitTesting(false)
                }
            }
            // On the whole field, or its outline draws over the label.
            .hotkey("⌘F", key: "f", placement: .belowLeft, model: model, theme: theme)
            Button("by meaning") { model.findsByMeaning.toggle() }
                .buttonStyle(KeyStyle(theme: theme, led: model.findsByMeaning))
                .hotkey("⌘Y", key: "y", model: model, theme: theme)
                .disabled(!model.canFindByMeaning)
                .help(model.canFindByMeaning
                      ? "Find what things are about, using the CLIP model on this Mac"
                      : "Needs the CLIP model on this Mac.")
        }
    }

    @ViewBuilder
    private func staysOn(_ pair: String) -> some View {
        if lastOff?.pair == pair {
            Text("one has to stay on")
                .font(PlexMono.font(.medium, size: 11))
                .foregroundStyle(theme.ground.color)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(theme.ink.color)
                .offset(y: 32)
                .allowsHitTesting(false)
        }
    }
}

private struct LastOff: Equatable {
    let pair: String
    let id = UUID()
}

private struct FindRequest: Equatable {
    let query: String
    let byMeaning: Bool
}

/// A key showing a choice, which opens a column of keys above it to change it, or below it
/// at the top of the window. A system menu can't be drawn in the app's style, and opens
/// wherever it likes.
struct UpwardPicker<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    let theme: Theme
    var opensDown = false
    @State private var open = false
    @State private var monitor: Any?

    /// As wide as the widest choice, so the key doesn't change size as the choice does.
    private func widest(_ shown: String, suffix: String = "") -> some View {
        ZStack(alignment: .leading) {
            ForEach(options, id: \.self) { Text(label($0) + suffix).hidden() }
            Text(shown)
        }
    }

    var body: some View {
        let arrow = open != opensDown ? "▾" : "▴"
        Button {
            open.toggle()
        } label: {
            widest("\(label(selection))  \(arrow)", suffix: "  \(arrow)")
        }
        .buttonStyle(KeyStyle(theme: theme, on: open))
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
        .overlay(alignment: opensDown ? .topTrailing : .bottomTrailing) {
            if open {
                VStack(spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection = option
                            open = false
                        } label: {
                            widest(label(option))
                        }
                        .buttonStyle(KeyStyle(theme: theme, led: option == selection))
                    }
                }
                .padding(4)
                .background(theme.ground.color, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.ink.color, lineWidth: 1))
                .fixedSize()
                .offset(y: opensDown ? 30 : -30)
            }
        }
        .zIndex(open ? 2 : 0)
        .onChange(of: open) { _, isOpen in isOpen ? startWatching() : stopWatching() }
        .onDisappear { stopWatching() }
    }

    /// A click anywhere closes it, after whatever it hit has had its turn, and so does esc.
    private func startWatching() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated { open = false }
                return nil
            }
            DispatchQueue.main.async { open = false }
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The time scrubber: items per month, a ruler, and a selection to drag.
struct TimeBar: View {
    let model: AppModel
    let theme: Theme
    @State private var drag: Drag?

    private enum Drag {
        case fresh(anchor: Int)
        case moving(offset: Int)
        case lowerEdge
        case upperEdge
        /// The clouds' season, taken hold of by its top.
        case clouds(offset: Int)
    }

    private let margin = 16.0
    private let barsHeight = 34.0
    private static let edgeReach = 6.0
    /// How far down from the top of the clouds' season it can be taken hold of.
    private static let cloudsReach = 8.0

    var body: some View {
        HStack(spacing: 12) {
            Button(model.isPlaying ? "■" : "▶") { model.togglePlay() }
                .buttonStyle(SquareKeyStyle(theme: theme))
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play through time")
                .hotkey("⌘P", key: "p", model: model, theme: theme)
            GeometryReader { geometry in
                ruler(width: geometry.size.width)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { changed($0, width: geometry.size.width) }
                        .onEnded { ended($0, width: geometry.size.width) })
                    .onContinuousHover { phase in
                        guard drag == nil else { return }
                        switch phase {
                        case .active(let point): setCursor(at: point, width: geometry.size.width)
                        case .ended: NSCursor.arrow.set()
                        }
                    }
            }
            .frame(height: 50)
            rangeLabel
                .frame(minWidth: 212, alignment: .trailing)
                // In width kept free for it, so it doesn't resize the ruler mid-drag.
                .overlay(alignment: .leading) {
                    if model.filter.range != nil {
                        Button("all time") {
                            model.stopPlaying()
                            model.clearStrataSelection()
                        }
                        .buttonStyle(KeyStyle(theme: theme))
                        .help("Show the entire timeline")
                        .hotkey("⌘T", key: "t", model: model, theme: theme)
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func x(_ time: Int, axis: MonthAxis, width: Double) -> Double {
        margin + axis.fraction(of: time) * (width - margin * 2)
    }

    /// When the clouds showing on the terrain come from: the season before the time shown, or
    /// where you've moved it.
    private var cloudSeason: ClosedRange<Int>? {
        guard model.section == .terrain, model.showsClouds, model.map?.clouds.isEmpty == false,
              let end = model.cloudsEnd ?? model.scene?.weatherEnd else { return nil }
        return (end - Clouds.season)...end
    }

    /// Whether a point is on the top of the clouds' season, where it can be taken hold of.
    private func isOnClouds(_ point: CGPoint, width: Double) -> Bool {
        guard let axis = model.axis, let season = cloudSeason, point.y < Self.cloudsReach else { return false }
        let left = x(max(season.lowerBound, axis.start), axis: axis, width: width)
        let right = max(x(min(season.upperBound, axis.end), axis: axis, width: width), left + 3)
        return point.x > left - 3 && point.x < right + 3
    }

    private func time(atX x: Double, axis: MonthAxis, width: Double) -> Int {
        axis.time(atFraction: (x - margin) / (width - margin * 2))
    }

    private func ruler(width: Double) -> some View {
        Canvas { context, size in
            guard let axis = model.axis, !model.monthCounts.isEmpty else { return }
            let high = Double(model.monthCounts.max() ?? 1)
            let barWidth = max(1, ((width - 8) / Double(axis.count)).rounded(.down) - 1)
            // The season the clouds over the terrain come from, as a dot screen behind the bars.
            if let season = cloudSeason {
                let left = x(max(season.lowerBound, axis.start), axis: axis, width: width).rounded()
                let right = max(x(min(season.upperBound, axis.end), axis: axis, width: width).rounded(), left + 3)
                var dots = Path()
                for row in stride(from: 1.0, to: barsHeight, by: 3) {
                    // Every other row offset, like the terrain's screens.
                    let shift = Int(row / 3) % 2 == 0 ? 0.0 : 1.5
                    for column in stride(from: left + shift, to: right, by: 3) { dots.addRect(CGRect(x: column, y: row, width: 1, height: 1)) }
                }
                context.fill(dots, with: .color(theme.secondary.color))
                context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: 1)), with: .color(theme.secondary.color))
            }
            for (month, count) in model.monthCounts.enumerated() where count > 0 {
                let left = x(axis.edges[month], axis: axis, width: width).rounded()
                let height = (barsHeight - 2) * Double(count) / high
                context.fill(Path(CGRect(x: left, y: barsHeight - height, width: barWidth, height: height)), with: .color(theme.ink.color))
            }
            // A ruler: a tick per month, a long tick and a label per year.
            for edge in axis.edges.dropLast() {
                let at = x(edge, axis: axis, width: width).rounded()
                context.fill(Path(CGRect(x: at, y: barsHeight + 1, width: 1, height: 2)), with: .color(theme.rule.color))
            }
            let years = axis.years()
            let every = width < 500 ? 4 : width < 900 ? 2 : 1
            for (position, year) in years.enumerated() where position % every == 0 {
                let at = x(year.time, axis: axis, width: width).rounded()
                context.fill(Path(CGRect(x: at, y: barsHeight + 1, width: 1, height: 5)), with: .color(theme.ink.color))
                context.draw(Text(String(year.year)).font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color),
                             at: CGPoint(x: at, y: barsHeight + 11))
            }
            if let range = model.filter.range {
                let rect = CGRect(x: x(range.lowerBound, axis: axis, width: width), y: 0,
                                  width: x(range.upperBound, axis: axis, width: width) - x(range.lowerBound, axis: axis, width: width),
                                  height: barsHeight)
                context.fill(Path(rect), with: .color(theme.ink.color.opacity(0.1)))
                context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(theme.ink.color), lineWidth: 1)
            }
        }
    }

    private var rangeLabel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let axis = model.axis {
                if let range = model.filter.range {
                    Text("\(Format.month(range.lowerBound)) — \(Format.month(range.upperBound))")
                    Text("\((model.scene?.visible.count ?? 0).formatted()) items in range")
                        .font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color)
                } else {
                    Text("\(axis.years().first.map { String($0.year) } ?? Format.month(axis.start)) — \(Format.month(axis.end - 86400).prefix(4))")
                    Text("all time")
                        .font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color)
                }
            }
        }
        .font(PlexMono.font(.medium, size: 12))
        .foregroundStyle(theme.ink.color)
    }

    /// Whether a position is close enough to one of the time window's edges to grab it.
    private func isOnEdge(_ position: Double, width: Double) -> Bool {
        guard let axis = model.axis, let range = model.filter.range else { return false }
        return abs(position - x(range.lowerBound, axis: axis, width: width)) < Self.edgeReach
            || abs(position - x(range.upperBound, axis: axis, width: width)) < Self.edgeReach
    }

    private func setCursor(at point: CGPoint, width: Double) {
        (isOnClouds(point, width: width) ? NSCursor.openHand : isOnEdge(point.x, width: width) ? NSCursor.resizeLeftRight : .arrow).set()
    }

    private func changed(_ value: DragGesture.Value, width: Double) {
        guard let axis = model.axis else { return }
        let now = time(atX: value.location.x, axis: axis, width: width)
        if drag == nil {
            model.stopPlaying()
            let start = time(atX: value.startLocation.x, axis: axis, width: width)
            if isOnClouds(value.startLocation, width: width), let season = cloudSeason {
                drag = .clouds(offset: start - season.upperBound)
                NSCursor.closedHand.set()
            } else if let range = model.filter.range {
                let lo = x(range.lowerBound, axis: axis, width: width), hi = x(range.upperBound, axis: axis, width: width)
                if abs(value.startLocation.x - lo) < Self.edgeReach {
                    drag = .lowerEdge
                    NSCursor.resizeLeftRight.set()
                } else if abs(value.startLocation.x - hi) < Self.edgeReach {
                    drag = .upperEdge
                    NSCursor.resizeLeftRight.set()
                } else if value.startLocation.x > lo, value.startLocation.x < hi {
                    drag = .moving(offset: start - range.lowerBound)
                } else {
                    drag = .fresh(anchor: start)
                }
            } else {
                drag = .fresh(anchor: start)
            }
        }
        // A click, without movement, is handled when it ends.
        guard abs(value.translation.width) >= 2 else { return }
        switch drag {
        case .fresh(let anchor):
            if model.section == .strata { model.holdStrata() }
            model.filter.range = min(anchor, now)...max(anchor, now)
        case .moving(let offset):
            guard let range = model.filter.range else { return }
            let span = range.upperBound - range.lowerBound
            let low = min(max(now - offset, axis.start), axis.end - span)
            model.filter.range = low...(low + span)
        case .lowerEdge:
            guard let range = model.filter.range else { return }
            model.filter.range = min(now, range.upperBound)...max(now, range.upperBound)
        case .upperEdge:
            guard let range = model.filter.range else { return }
            model.filter.range = min(now, range.lowerBound)...max(now, range.lowerBound)
        case .clouds(let offset):
            model.cloudsEnd = min(max(now - offset, axis.start + Clouds.season), axis.end)
        case nil:
            break
        }
    }

    private func ended(_ value: DragGesture.Value, width: Double) {
        if case .fresh = drag {
            if abs(value.translation.width) < 2 {
                model.clearStrataSelection()
            } else if model.section == .strata {
                model.fitStrataToNewSelection()
            }
        }
        drag = nil
        setCursor(at: value.location, width: width)
    }
}
