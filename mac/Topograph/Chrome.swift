import SwiftUI
import TopographCore

/// Platforms, what you did, how pictures show, and find.
struct FilterBar: View {
    @Bindable var model: AppModel
    let theme: Theme
    @State private var query = ""

    private static let groups: [(ActionGroups, String)] = [(.creation, "creation"), (.consumption, "consumption"), (.all, "creation + consumption")]

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(model.platforms, id: \.self) { platform in
                    let on = !model.filter.hiddenPlatforms.contains(platform)
                    Button(Format.platform(platform)) {
                        if on { model.filter.hiddenPlatforms.insert(platform) } else { model.filter.hiddenPlatforms.remove(platform) }
                    }
                    .buttonStyle(KeyStyle(theme: theme, led: on))
                }
            }
            HStack(spacing: 4) {
                ForEach(Self.groups, id: \.1) { group, label in
                    Button(label) { model.filter.groups = group }
                        .buttonStyle(KeyStyle(theme: theme, led: model.filter.groups == group))
                }
            }
            HStack(spacing: 4) {
                ForEach(ImageMode.allCases, id: \.self) { mode in
                    Button(mode.label) { model.imageMode = mode }
                        .buttonStyle(KeyStyle(theme: theme, led: model.imageMode == mode))
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                HStack(spacing: 0) {
                    Text("find")
                        .font(PlexMono.font(.regular, size: 11))
                        .foregroundStyle(theme.secondary.color)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .overlay(alignment: .trailing) { Rectangle().fill(theme.rule.color).frame(width: 1) }
                    TextField("", text: $query, prompt: Text(model.findsByMeaning ? "what it's about" : "words or @author").foregroundStyle(theme.secondary.color))
                        .textFieldStyle(.plain)
                        .font(PlexMono.font(.regular, size: 11))
                        .foregroundStyle(theme.ink.color)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 120, maxWidth: 190)
                }
                .frame(height: 26)
                .background(theme.surface.color)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
                Button("by meaning") { model.findsByMeaning.toggle() }
                    .buttonStyle(KeyStyle(theme: theme, led: model.findsByMeaning))
                    .disabled(!model.canFindByMeaning)
                    .help(model.canFindByMeaning
                          ? "Find what things are about, using the CLIP model on this Mac"
                          : "Needs the CLIP model on this Mac. Run mac/tools/convert_clip.py to make it.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .task(id: FindRequest(query: query, byMeaning: model.findsByMeaning)) {
            // Wait for a pause in the typing.
            try? await Task.sleep(for: .milliseconds(model.findsByMeaning ? 300 : 150))
            guard !Task.isCancelled else { return }
            await model.find(query)
        }
    }
}

private struct FindRequest: Equatable {
    let query: String
    let byMeaning: Bool
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
    }

    private let margin = 16.0
    private let barsHeight = 34.0

    var body: some View {
        HStack(spacing: 12) {
            Button(model.isPlaying ? "■" : "▶") { model.togglePlay() }
                .buttonStyle(SquareKeyStyle(theme: theme))
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play through time")
            GeometryReader { geometry in
                ruler(width: geometry.size.width)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { changed($0, width: geometry.size.width) }
                        .onEnded { ended($0, width: geometry.size.width) })
            }
            .frame(height: 50)
            rangeLabel.frame(minWidth: 168, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func x(_ time: Int, axis: MonthAxis, width: Double) -> Double {
        margin + axis.fraction(of: time) * (width - margin * 2)
    }

    private func time(atX x: Double, axis: MonthAxis, width: Double) -> Int {
        axis.time(atFraction: (x - margin) / (width - margin * 2))
    }

    private func ruler(width: Double) -> some View {
        Canvas { context, size in
            guard let axis = model.axis, !model.monthCounts.isEmpty else { return }
            let high = Double(model.monthCounts.max() ?? 1)
            let barWidth = max(1, ((width - 8) / Double(axis.count)).rounded(.down) - 1)
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

    private func changed(_ value: DragGesture.Value, width: Double) {
        guard let axis = model.axis else { return }
        let now = time(atX: value.location.x, axis: axis, width: width)
        if drag == nil {
            model.stopPlaying()
            let start = time(atX: value.startLocation.x, axis: axis, width: width)
            if let range = model.filter.range {
                let lo = x(range.lowerBound, axis: axis, width: width), hi = x(range.upperBound, axis: axis, width: width)
                if abs(value.startLocation.x - lo) < 6 {
                    drag = .lowerEdge
                } else if abs(value.startLocation.x - hi) < 6 {
                    drag = .upperEdge
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
        case nil:
            break
        }
    }

    private func ended(_ value: DragGesture.Value, width: Double) {
        if abs(value.translation.width) < 2, case .fresh = drag { model.filter.range = nil }
        drag = nil
    }
}
