import SwiftUI
import TopographCore

struct ContentView: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.of(scheme)
        VStack(spacing: 0) {
            TopBar(model: model, theme: theme)
                // Shortcut labels reach a little way into the row below.
                .zIndex(2)
            if model.section.isFiltered {
                FilterBar(model: model, theme: theme)
                    // Its message hangs down over the map.
                    .zIndex(1)
            }
            Rectangle().fill(theme.ink.color).frame(height: 1)
            ZStack(alignment: .topTrailing) {
                // The map stays alive under other views so it keeps your place.
                TerrainView(scene: model.scene, root: model.library?.root, controller: model.controller,
                            imageMode: model.mapImageMode, selected: selectedItem, isActive: model.section == .terrain,
                            isPlaying: model.isPlaying, relief: model.showsRelief,
                            onFailure: { model.fail($0) },
                            onHover: { model.hover = $0 },
                            onPickItem: { model.openItem($0) },
                            onPickRegion: { model.openRegion($0) },
                            onPickCloud: { model.openCloud(at: $0) },
                            onWhere: { model.setWhere($0) },
                            onViewport: { model.viewport = $0 })
                    .opacity(model.section == .terrain ? 1 : 0)
                    .allowsHitTesting(model.section == .terrain)
                if model.section == .terrain {
                    MapChrome(model: model, theme: theme)
                }
                switch model.section {
                case .terrain: EmptyView()
                case .strata: StrataScreen(model: model, theme: theme)
                case .echoes: EchoesScreen(model: model, theme: theme)
                case .palette: PaletteScreen(model: model, theme: theme)
                case .drift: DriftScreen(model: model, theme: theme)
                case .process: ProcessScreen(model: model, theme: theme)
                case .sources: SourcesScreen(model: model, theme: theme)
                }
                if model.section != .sources { status(theme) }
                if model.selection != nil, let library = model.library, let map = model.map {
                    DetailPanel(model: model, library: library, map: map, theme: theme)
                }
            }
            if model.section.isFiltered {
                Rectangle().fill(theme.ink.color).frame(height: 1)
                TimeBar(model: model, theme: theme)
            }
        }
        .overlay {
            if let enlarged = model.enlarged, let library = model.library, let map = model.map {
                LargePicture(model: model, library: library, map: map, theme: theme, enlarged: enlarged)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(theme.ground.color)
        .frame(minWidth: 760, minHeight: 480)
    }

    private var selectedItem: Int32? {
        if case .item(let index) = model.selection { return index }
        return nil
    }

    @ViewBuilder
    private func status(_ theme: Theme) -> some View {
        switch model.phase {
        case .ready:
            EmptyView()
        case .loading:
            Message(text: "Reading the library…", theme: theme)
        case .failed(let text):
            Message(text: text, theme: theme)
        }
    }
}

private struct Message: View {
    let text: String
    let theme: Theme

    var body: some View {
        Text(text)
            .font(PlexMono.font(.regular, size: 12))
            .foregroundStyle(theme.ink.color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surface.color)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.ink.color, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TopBar: View {
    let model: AppModel
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            Text("topograph").font(PlexMono.font(.semibold, size: 15)).foregroundStyle(theme.ink.color)
                .padding(.trailing, 12)
            ForEach(Array(Section.allCases.enumerated()), id: \.element) { position, section in
                Button(section.rawValue) { model.section = section }
                    .buttonStyle(KeyStyle(theme: theme, on: model.section == section))
                    .hotkey("⌘\(position + 1)", key: KeyEquivalent(Character(String(position + 1))), model: model, theme: theme)
            }
            Spacer()
            if model.section == .sources, let summary = model.sourcesSummary {
                Text(summary).font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.ink.color)
            }
            Lamp(text: "on this mac only", theme: theme)
        }
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 38)
    }
}

/// A key that isn't pressed: its LED states a fact.
struct Lamp: View {
    let text: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(theme.ink.color).frame(width: 7, height: 7)
            Text(text).font(PlexMono.font(.medium, size: 11)).foregroundStyle(theme.ink.color)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        // Given a shape, it stays inside the key. A plain color fills on up into the title bar.
        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
    }
}

/// What floats over the map: where you are, the readout, zoom keys, the hover card.
private struct MapChrome: View {
    let model: AppModel
    let theme: Theme
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                WhereBar(model: model, theme: theme)
                Spacer()
                MinimapPanel(model: model, theme: theme)
                if let scene = model.scene, let map = model.map {
                    Readout(visible: scene.visible.count, total: map.items.count, waiting: map.waiting, theme: theme)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Spacer()
                // It names the view it switches to.
                Button(model.showsRelief ? "2D" : "3D") { model.showsRelief.toggle() }
                    .accessibilityLabel(model.showsRelief ? "Lay the terrain flat" : "Terrain in 3D")
                    .help(model.showsRelief ? "Lay the terrain flat again."
                          : "Stand the terrain up in 3D. Drag to turn it, space and drag to move.")
                    .hotkey("⌘D", placement: .beside, model: model, theme: theme)
                    .padding(.bottom, 4)
                // Their shortcuts are in the Map menu. Stacked this closely, labels go to the side.
                Button("+", action: model.controller.zoomIn).accessibilityLabel("Zoom in")
                    .hotkey("⌘+", placement: .beside, model: model, theme: theme)
                Button("−", action: model.controller.zoomOut).accessibilityLabel("Zoom out")
                    .hotkey("⌘-", placement: .beside, model: model, theme: theme)
                Button("fit", action: model.controller.fit).accessibilityLabel("Show everything")
                    .hotkey("⌘0", placement: .beside, model: model, theme: theme)
            }
            .buttonStyle(SquareKeyStyle(theme: theme))
            // Beside the side panel when it's open, not behind it.
            .padding(.trailing, 16 + (model.selection == nil ? 0 : DetailPanel.width))
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .trailing)

            if let hover = model.hover, let map = model.map, let library = model.library {
                HoverCard(item: map.items[Int(hover.item)], library: library, theme: theme)
                    .frame(width: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { cardHeight = $0 }
                    .offset(x: min(hover.location.x + 14, hover.mapSize.width - 270),
                            y: max(8, min(hover.location.y + 14, hover.mapSize.height - cardHeight - 8)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The whole map with what's showing marked, while zoomed in. Press or drag to move.
private struct MinimapPanel: View {
    let model: AppModel
    let theme: Theme
    @State private var picture: CGImage?
    @State private var drawing = false
    @Environment(\.displayScale) private var displayScale

    private let side = 168.0
    private var perMapUnit: Double { side / DensityField.mapSize }

    var body: some View {
        if let viewport = model.viewport, viewport.transform.isZoomedIn(viewSize: viewport.size), let scene = model.scene {
            let shown = viewport.transform.visibleRect(viewSize: viewport.size)
            MinimapDial(picture: picture, side: side,
                        frame: CGRect(x: shown.minX * perMapUnit, y: shown.minY * perMapUnit,
                                      width: shown.width * perMapUnit, height: shown.height * perMapUnit),
                        theme: theme, tinted: true,
                        onMove: { point in
                            model.controller.center(x: min(max(point.x / perMapUnit, 0), DensityField.mapSize),
                                                    y: min(max(point.y / perMapUnit, 0), DensityField.mapSize))
                        },
                        onPointer: { model.controller.pointerIsOnMinimap = $0 })
                .task(id: scene.id) { await drawLatest() }
        }
    }

    /// One at a time, always going on to whatever's newest, since scenes can change faster
    /// than this draws them while the timeline plays.
    private func drawLatest() async {
        guard !drawing else { return }
        drawing = true
        defer { drawing = false }
        let pixels = Int(side * displayScale)
        let dot = max(Int(displayScale), 1)
        var drawn: UUID?
        while let scene = model.scene, scene.id != drawn {
            drawn = scene.id
            picture = await Task.detached(priority: .utility) {
                Minimap.image(mask: Minimap.mask(field: scene.field, side: pixels, dot: dot), side: pixels)
            }.value
        }
    }
}

/// A small picture of the whole with the part showing outlined. Press or drag to move:
/// taking hold of the outline moves it from there, and anywhere else jumps to that spot.
struct MinimapDial: View {
    let picture: CGImage?
    let side: Double
    /// What's showing, in this view's points.
    let frame: CGRect
    let theme: Theme
    /// Whether the picture is a mask for the theme's ink, not a picture in its own colors.
    let tinted: Bool
    let onMove: (CGPoint) -> Void
    let onPointer: (Bool) -> Void
    @State private var grab: CGSize?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Never too small to see or to take hold of.
        let width = max(frame.width, 6), height = max(frame.height, 6)
        let held = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        let shown = held.intersection(CGRect(x: 0, y: 0, width: side, height: side))
        ZStack(alignment: .topLeading) {
            theme.surface.color
            if let picture {
                if tinted {
                    Image(decorative: picture, scale: displayScale)
                        .renderingMode(.template)
                        .foregroundStyle(theme.ink.color)
                } else {
                    Image(decorative: picture, scale: displayScale)
                }
            }
            // Its edge stays visible where it runs past the map's.
            Rectangle()
                .strokeBorder(theme.ink.color, lineWidth: 1.5)
                .frame(width: max(shown.width, 6), height: max(shown.height, 6))
                .offset(x: shown.minX, y: shown.minY)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.ink.color, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grab == nil {
                    grab = held.contains(value.startLocation)
                        ? CGSize(width: value.startLocation.x - held.midX, height: value.startLocation.y - held.midY)
                        : .zero
                    NSCursor.closedHand.set()
                }
                onMove(CGPoint(x: value.location.x - (grab?.width ?? 0), y: value.location.y - (grab?.height ?? 0)))
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
            }
        }
        .onDisappear { onPointer(false) }
        .accessibilityLabel("Minimap")
    }
}

/// The regions you've zoomed inside, as keys that take you back out.
private struct WhereBar: View {
    let model: AppModel
    let theme: Theme

    var body: some View {
        if !model.whereYouAre.isEmpty, let map = model.map {
            HStack(spacing: 4) {
                Button("all", action: model.controller.fit).buttonStyle(KeyStyle(theme: theme))
                ForEach(model.whereYouAre, id: \.self) { id in
                    if let region = map.regions.regions[id] {
                        Text("›").font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.secondary.color)
                        Button(region.label) { model.controller.fly(inside: region) }
                        .buttonStyle(KeyStyle(theme: theme, on: id == model.whereYouAre.last))
                    }
                }
            }
        }
    }
}

struct Readout: View {
    let visible: Int
    let total: Int
    let waiting: Int
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            Text(visible.formatted()).font(PlexMono.font(.semibold, size: 11))
            Text(" / \(total.formatted()) mapped")
            Rectangle().fill(theme.ink.color).frame(width: 7, height: 7).padding(.leading, 10).padding(.trailing, 4)
            Text("made")
            Circle().strokeBorder(theme.ink.color, lineWidth: 1).frame(width: 7, height: 7).padding(.leading, 10).padding(.trailing, 4)
            Text("kept")
            if waiting > 0 { Text("   \(waiting.formatted()) waiting") }
        }
        .font(PlexMono.font(.regular, size: 11))
        .foregroundStyle(theme.ink.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surface.color)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
    }
}

/// What the pointer is over: always in full color.
struct HoverCard: View {
    let item: MapItem
    let library: Library
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let thumb = item.thumb {
                LibraryPicture(url: library.file(thumb), longEdge: 512, mode: .color, theme: theme)
                    .aspectRatio(CGFloat(item.aspect ?? 1), contentMode: .fit)
            }
            if let text = item.text {
                Text(text.count > 140 ? text.prefix(140) + "…" : text)
                    .font(PlexSans.font(size: 12))
                    .foregroundStyle(theme.ink.color)
            }
            Text(Format.meta(item))
                .font(PlexMono.font(.regular, size: 11))
                .foregroundStyle(theme.secondary.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.ink.color, lineWidth: 1))
    }
}

enum Format {
    static func platform(_ key: String) -> String {
        switch key {
        case "x": "x"
        case "files": "your files"
        default: key
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

    static func month(_ time: Int) -> String { stamp.string(from: Date(timeIntervalSince1970: TimeInterval(time))) }
    static func date(_ time: Int) -> String { day.string(from: Date(timeIntervalSince1970: TimeInterval(time))) }

    static func meta(_ item: MapItem) -> String {
        [item.author.map { "@\($0)" }, platform(item.platform), item.time.map(month)]
            .compactMap { $0 }.joined(separator: "  ")
    }
}

/// A picture from the library, decoded off the main thread and remembered.
struct LibraryPicture: View {
    let url: URL
    let longEdge: Int
    let mode: ImageMode
    let theme: Theme
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(mode == .dither && !hovering ? .none : .high)
                    .saturation(mode == .color || hovering ? 1 : 0)
                    .contrast(mode == .color || hovering ? 1 : 1.05)
            } else {
                Rectangle().fill(theme.surface.color)
            }
        }
        .onHover { hovering = $0 }
        .task(id: url) {
            image = await PictureCache.shared.image(url: url, longEdge: longEdge)
        }
    }
}

@MainActor
final class PictureCache {
    static let shared = PictureCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 600
    }

    func image(url: URL, longEdge: Int) async -> NSImage? {
        let key = "\(longEdge)|\(url.path)" as NSString
        if let known = cache.object(forKey: key) { return known }
        let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let image = PictureFile.image(at: url, longEdge: longEdge) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
        if let decoded { cache.setObject(decoded, forKey: key) }
        return decoded
    }
}

struct KeyStyle: ButtonStyle {
    let theme: Theme
    var on = false
    var led: Bool? = nil

    func makeBody(configuration: Configuration) -> some View {
        Key(configuration: configuration, theme: theme, on: on, led: led)
    }

    private struct Key: View {
        let configuration: Configuration
        let theme: Theme
        let on: Bool
        let led: Bool?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            HStack(spacing: 6) {
                if let led {
                    Rectangle()
                        .fill(led ? (on ? theme.ground.color : theme.ink.color) : Color.clear)
                        .overlay(Rectangle().strokeBorder(on ? theme.ground.color : enabled ? theme.ink.color : theme.rule.color, lineWidth: 1))
                        .frame(width: 7, height: 7)
                }
                configuration.label
                    .lineLimit(1)
                    .font(PlexMono.font(.medium, size: 11))
                    .foregroundStyle(on ? theme.ground.color : enabled ? theme.ink.color : theme.secondary.color)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(on ? theme.ink.color : theme.surface.color)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(on || (hovering && enabled) ? theme.ink.color : theme.rule.color, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .offset(y: configuration.isPressed ? 1 : 0)
            .onHover { hovering = $0 }
        }
    }
}

struct SquareKeyStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        Key(configuration: configuration, theme: theme)
    }

    private struct Key: View {
        let configuration: Configuration
        let theme: Theme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(PlexMono.font(.medium, size: 11))
                .foregroundStyle(theme.ink.color)
                .frame(width: 28, height: 28)
                .background(theme.surface.color)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(hovering ? theme.ink.color : theme.rule.color, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .offset(y: configuration.isPressed ? 1 : 0)
                .onHover { hovering = $0 }
        }
    }
}
