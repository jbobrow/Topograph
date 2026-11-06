import SwiftUI
import TopographCore

struct ContentView: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.of(scheme)
        VStack(spacing: 0) {
            TopBar(model: model, theme: theme)
            if model.section.isFiltered {
                FilterBar(model: model, theme: theme)
            }
            Rectangle().fill(theme.ink.color).frame(height: 1)
            ZStack(alignment: .topTrailing) {
                // The map stays alive under other views so it keeps your place.
                TerrainView(scene: model.scene, root: model.library?.root, controller: model.controller,
                            imageMode: model.imageMode, selected: selectedItem,
                            onFailure: { model.fail($0) },
                            onHover: { model.hover = $0 },
                            onPickItem: { model.openItem($0) },
                            onPickRegion: { model.openRegion($0) },
                            onWhere: { model.setWhere($0) })
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
            ForEach(Section.allCases, id: \.self) { section in
                Button(section.rawValue) { model.section = section }
                    .buttonStyle(KeyStyle(theme: theme, on: model.section == section, led: model.section == section))
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
        .background(theme.surface.color)
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
                if let scene = model.scene, let map = model.map {
                    Readout(visible: scene.visible.count, total: map.items.count, waiting: map.waiting, theme: theme)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                Spacer()
                Button("+", action: model.controller.zoomIn).accessibilityLabel("Zoom in")
                Button("−", action: model.controller.zoomOut).accessibilityLabel("Zoom out")
                Button("fit", action: model.controller.fit).accessibilityLabel("Show everything")
            }
            .buttonStyle(SquareKeyStyle(theme: theme))
            .padding(.trailing, 16)
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

private struct Readout: View {
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

        var body: some View {
            HStack(spacing: 6) {
                if let led {
                    Rectangle()
                        .fill(led ? (on ? theme.ground.color : theme.ink.color) : Color.clear)
                        .overlay(Rectangle().strokeBorder(on ? theme.ground.color : theme.ink.color, lineWidth: 1))
                        .frame(width: 7, height: 7)
                }
                configuration.label
                    .lineLimit(1)
                    .font(PlexMono.font(.medium, size: 11))
                    .foregroundStyle(on ? theme.ground.color : theme.ink.color)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(on ? theme.ink.color : theme.surface.color)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(on || hovering ? theme.ink.color : theme.rule.color, lineWidth: 1))
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
