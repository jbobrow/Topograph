import AppKit
import SwiftUI
import TopographCore

/// The side panel: one item, one region, or what a search found.
struct DetailPanel: View {
    static let width = 380.0

    let model: AppModel
    let library: Library
    let map: LibraryMap
    let theme: Theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.selection {
                    case .item(let index):
                        ItemPanel(model: model, library: library, map: map, theme: theme, index: index).id(index)
                    case .region(let id):
                        RegionPanel(model: model, library: library, map: map, theme: theme, id: id).id(id)
                    case .colorBand(let band):
                        ColorBandPanel(model: model, library: library, map: map, theme: theme, band: band).id(band)
                    case .cloud(let x, let y):
                        CloudPanel(model: model, library: library, map: map, theme: theme, x: x, y: y).id(SIMD2(x, y))
                    case .found(let query):
                        Text(query)
                            .font(PlexMono.font(.medium, size: 13))
                            .foregroundStyle(theme.ink.color)
                            .padding(.trailing, 36)
                        PanelHeading(text: "closest in meaning", theme: theme)
                        ItemGrid(items: model.foundItems(count: 90), map: map, library: library, mode: .color, theme: theme) {
                            model.openItem($0, pan: true)
                        }
                    case nil:
                        EmptyView()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // With an always-visible scrollbar taking up width, some items sent layout into a
            // loop, which AppKit ends by crashing the app ("more Update Constraints in Window
            // passes than there are views in the window").
            .scrollIndicators(.never)
            Button("×") { model.closePanel() }
                .buttonStyle(SquareKeyStyle(theme: theme))
                // Esc is `AppModel.escape`, which closes a large picture first.
                .accessibilityLabel("Close")
                .hotkey("esc", model: model, theme: theme)
                .padding(16)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // What's in the drawer gives way to the picture, as the drawer grows over the window.
        .opacity(model.showsLargePicture ? 0 : 1)
        .allowsHitTesting(!model.showsLargePicture)
        .background(theme.ground.color)
        .overlay(alignment: .leading) { Rectangle().fill(theme.ink.color).frame(width: 1) }
        // Where the drawer is, for it to grow from when a picture opens large.
        .background {
            GeometryReader { drawer in
                Color.clear
                    .onAppear { model.drawerFrame = drawer.frame(in: .global) }
                    .onChange(of: drawer.frame(in: .global)) { model.drawerFrame = $1 }
            }
        }
    }
}

struct PanelHeading: View {
    let text: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(PlexMono.font(.medium, size: 11)).foregroundStyle(theme.secondary.color)
            Rectangle().fill(theme.rule.color).frame(height: 1)
        }
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

private struct ItemPanel: View {
    let model: AppModel
    let library: Library
    let map: LibraryMap
    let theme: Theme
    let index: Int32
    @State private var detail: ItemDetail?
    @State private var hero = 0
    /// Where the picture is in the window, for it to fly from when it opens large.
    @State private var heroFrame = CGRect.zero
    @State private var tributaries: [Int32] = []
    @State private var findingTributaries = false

    private var item: MapItem { map.items[Int(index)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let media = detail?.media, !media.isEmpty {
                let picture = media[min(hero, media.count - 1)]
                if let path = picture.display ?? picture.thumb {
                    Button { model.enlarged = Enlarged(index: index, hero: hero, from: heroFrame, copy: library.file(path)) } label: {
                        LibraryPicture(url: library.file(path), longEdge: 1520, mode: .color, theme: theme)
                            .aspectRatio(CGFloat(hero == 0 ? (item.aspect ?? 1) : 1), contentMode: .fit)
                            .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                            .background { GeometryReader { g in Color.clear.onAppear { heroFrame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { heroFrame = $1 } } }
                    }
                    .buttonStyle(.plain)
                    .help("See it large")
                    .padding(.trailing, 32)
                }
                if media.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(media.indices, id: \.self) { i in
                                if let path = media[i].thumb {
                                    Button { hero = i } label: {
                                        LibraryPicture(url: library.file(path), longEdge: 208, mode: .color, theme: theme)
                                            .frame(width: 52, height: 52)
                                            .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                if !picture.palette.isEmpty {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(picture.palette, id: \.hex) { color in
                                Rectangle().fill(Color(rgb: color.rgb ?? 0))
                                    .frame(width: geometry.size.width * color.share / max(picture.palette.reduce(0) { $0 + $1.share }, 0.001))
                            }
                        }
                    }
                    .frame(height: 8)
                    .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                    .padding(.top, 6)
                    .accessibilityLabel("Dominant colors")
                }
            }
            if let text = item.text {
                Text(text)
                    .font(PlexSans.font(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(theme.ink.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .padding(.trailing, detail?.media.isEmpty == false ? 0 : 32)
            }
            Text([item.author.map { "@\($0)" }, Format.platform(item.platform),
                  detail?.createdAt.map { "published \(Format.date($0))" }].compactMap { $0 }.joined(separator: "  "))
                .font(PlexMono.font(.regular, size: 11))
                .foregroundStyle(theme.secondary.color)
                .padding(.top, 6)
            ItemActions(item: item, detail: detail, theme: theme).padding(.top, 12)

            if let same = detail?.same, !same.isEmpty {
                PanelHeading(text: "also in", theme: theme)
                ForEach(same, id: \.id) { SameSourceRow(source: $0, theme: theme) }
            }

            PanelHeading(text: "history", theme: theme)
            ForEach(Array((detail?.interactions ?? []).enumerated()), id: \.offset) { _, interaction in
                HStack(spacing: 8) {
                    Text(Interactions.verb(interaction.type).lowercased() + (interaction.collection.map { " to “\($0)”" } ?? ""))
                        .foregroundStyle(theme.ink.color)
                    // Which place, when the picture is in more than one.
                    if let source = interaction.source {
                        Text(Format.platform(source)).foregroundStyle(theme.secondary.color)
                    }
                    Spacer(minLength: 12)
                    Text(when(interaction)).foregroundStyle(theme.secondary.color)
                }
                .font(PlexMono.font(.regular, size: 11))
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.hair.color).frame(height: 1) }
            }

            if let id = item.region, let path = map.regions.regions[id]?.path {
                PanelHeading(text: "region", theme: theme)
                RegionPath(path: path, map: map, theme: theme) { model.openRegion($0) }
            }
            if findingTributaries {
                PanelHeading(text: "tributaries: kept in the months before", theme: theme)
                LoadingNote(text: "looking through what you kept", theme: theme)
            } else if !tributaries.isEmpty {
                PanelHeading(text: "tributaries: kept in the months before", theme: theme)
                ItemGrid(items: tributaries, map: map, library: library, mode: .color, theme: theme) {
                    model.openItem($0, pan: true)
                }
            }
            let neighbors = (detail?.neighbors ?? []).compactMap { map.indexOfID[$0] }
            if !neighbors.isEmpty {
                PanelHeading(text: "nearest in taste", theme: theme)
                ItemGrid(items: neighbors, map: map, library: library, mode: .color, theme: theme) {
                    model.openItem($0, pan: true)
                }
            }
        }
        .task(id: index) {
            let (library, id, recipe) = (library, item.id, model.map?.recipe)
            detail = try? await Task.detached { try library.detail(of: id, in: recipe) }.value
            guard item.mine else { return }
            findingTributaries = true
            defer { findingTributaries = false }
            guard let store = await model.embeddings() else { return }
            let (index, map) = (index, map)
            tributaries = await Task.detached { Tributaries.find(of: index, map: map, embeddings: store) }.value
        }
    }

    private func when(_ interaction: Interaction) -> String {
        guard interaction.at != 0 else { return "" }
        return interaction.estimated ? "~" + Format.month(interaction.at) : Format.date(interaction.at)
    }
}

/// Another place the same picture came from, with a way to go there.
private struct SameSourceRow: View {
    let source: SameSource
    let theme: Theme
    @State private var fileMissing = false

    private var file: URL? {
        guard let url = source.url, url.hasPrefix("file://") else { return nil }
        return URL(string: url)
    }

    /// A file by its name and folder; a post by where, who and when.
    private var label: String {
        if let file {
            return "\(file.lastPathComponent), in \(file.deletingLastPathComponent().lastPathComponent)"
        }
        return [Format.platform(source.platform), source.author.map { "@\($0)" },
                source.createdAt.map { Format.date($0) }].compactMap { $0 }.joined(separator: "  ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(PlexMono.font(.regular, size: 11))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let file {
                Button(fileMissing ? "not found" : "show in finder") {
                    if FileManager.default.fileExists(atPath: file.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } else {
                        fileMissing = true
                    }
                }
                .buttonStyle(KeyStyle(theme: theme))
            } else if let link = source.url, let url = URL(string: link) {
                Button("open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(KeyStyle(theme: theme))
            }
        }
        .padding(.vertical, 3)
    }
}

/// The pictures in one band of color, among what's showing.
private struct ColorBandPanel: View {
    let model: AppModel
    let library: Library
    let map: LibraryMap
    let theme: Theme
    let band: Int
    @State private var items: [Int32]?
    @State private var swatch: Color?

    private static let shown = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(swatch ?? theme.surface.color)
                    .frame(width: 26, height: 26)
                    .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                Text(ColorBands.names[band])
                    .font(PlexMono.font(.semibold, size: 16))
                    .foregroundStyle(theme.ink.color)
            }
            .padding(.trailing, 36)
            if let items {
                Text("\(items.count.formatted()) pictures" + (items.count > Self.shown ? ", the \(Self.shown) most resonant here" : ""))
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.secondary.color)
                    .padding(.top, 8)
                if let axis = model.axis {
                    let times = items.compactMap { map.items[Int($0)].time }
                    if times.count > 1 {
                        PanelHeading(text: "when it was on your mind", theme: theme)
                        QuarterBars(times: times, axis: axis, theme: theme)
                    }
                }
                PanelHeading(text: "most resonant", theme: theme)
                ItemGrid(items: Array(items.prefix(Self.shown)), map: map, library: library, mode: .color, theme: theme) {
                    model.openItem($0)
                }
            } else {
                LoadingNote(text: "gathering \(ColorBands.names[band])", theme: theme)
                    .padding(.top, 12)
            }
        }
        .task(id: model.scene?.id) {
            guard let scene = model.scene else { return }
            let (map, band) = (map, band)
            let found = await Task.detached(priority: .userInitiated) { ColorBands.items(in: band, map: map, visible: scene.visible) }.value
            guard !Task.isCancelled else { return }
            items = found
            if swatch == nil {
                let mean = await Task.detached(priority: .userInitiated) { ColorBands.colors(of: map.items)[band] }.value
                swatch = Color(.sRGB, red: Double(mean.x), green: Double(mean.y), blue: Double(mean.z))
            }
        }
    }
}

private struct RegionPanel: View {
    let model: AppModel
    let library: Library
    let map: LibraryMap
    let theme: Theme
    let id: Int
    @State private var mostResonant: [Int32] = []
    @State private var exporting = false

    /// Ask where it goes first: nothing is written anywhere you didn't choose.
    private func exportMoodboard(_ region: Region) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(region.label.prefix(60)).png"
        let (map, library, id, title) = (map, library, region.id, region.label)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            exporting = true
            Task {
                let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                    let files = Moodboard.picks(region: id, map: map).compactMap { map.items[Int($0)].thumb }.map(library.file)
                    return Moodboard.render(title: title, files: files)
                }.value
                try? data?.write(to: destination, options: .atomic)
                exporting = false
            }
        }
    }

    var body: some View {
        if let region = map.regions.regions[id] {
            VStack(alignment: .leading, spacing: 0) {
                if region.path.count > 1 {
                    RegionPath(path: Array(region.path.dropLast()), map: map, theme: theme) { model.openRegion($0) }
                        .padding(.trailing, 36)
                        .padding(.bottom, 10)
                }
                Text(region.label.lowercased())
                    .font(PlexMono.font(.semibold, size: 16))
                    .foregroundStyle(theme.ink.color)
                    .padding(.trailing, 36)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(region.count.formatted()) items" + (region.terms.isEmpty ? "" : "   words: \(region.terms.prefix(5).joined(separator: ", "))"))
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.secondary.color)
                    .padding(.top, 6)
                RegionNaming(model: model, library: library, map: map, theme: theme, region: region).padding(.top, 10)
                if !region.children.isEmpty {
                    PanelHeading(text: "inside", theme: theme)
                    FlowKeys(ids: region.children, map: map, theme: theme) { model.openRegion($0) }
                }
                if let axis = model.axis {
                    let times = map.regions.members(of: id).compactMap { map.items[Int($0)].time }
                    if times.count > 1 {
                        PanelHeading(text: "when it was on your mind", theme: theme)
                        QuarterBars(times: times, axis: axis, theme: theme)
                    }
                }
                Button(exporting ? "exporting…" : "export moodboard") { exportMoodboard(region) }
                    .buttonStyle(KeyStyle(theme: theme))
                    .disabled(exporting)
                    .padding(.top, 14)
                PanelHeading(text: "most resonant", theme: theme)
                ItemGrid(items: mostResonant, map: map, library: library, mode: .color, theme: theme) {
                    model.openItem($0, pan: true)
                }
            }
            .task(id: id) {
                let members = map.regions.members(of: id)
                let items = map.items
                mostResonant = await Task.detached {
                    Array(members.sorted {
                        let a = items[Int($0)], b = items[Int($1)]
                        return a.resonance != b.resonance ? a.resonance > b.resonance : (a.time ?? 0) > (b.time ?? 0)
                    }.prefix(150))
                }.value
            }
        }
    }
}

/// A cloud: the searches of one season that float in one patch of weather. First their themes,
/// for the gist, then every one, newest first. Each is a key that looks for what it was about
/// in the library.
private struct CloudPanel: View {
    let model: AppModel
    let library: Library
    let map: LibraryMap
    let theme: Theme
    let x: Double
    let y: Double
    /// nil while it's worked out; a cloud with no searches is clear sky.
    @State private var cloud: Clouds.Cloud?
    @State private var looked = false
    @State private var themes: [CloudTheme] = []
    @State private var others = 0
    @State private var open: String?
    /// The text model's vectors for searches seen so far, kept as the weather moves.
    @State private var vectors: [String: [Float]] = [:]

    private static let shown = 400

    /// The same search on the same day, once, with how many times.
    private struct Line: Identifiable {
        let id: Int
        let text: String
        let times: Int
    }

    private var days: [(day: String, lines: [Line])] {
        var days: [(day: String, lines: [Line])] = []
        var seen: [String: Int] = [:]
        var id = 0
        for search in cloud?.searches.prefix(Self.shown) ?? [] {
            let day = Format.date(search.time)
            if days.last?.day != day {
                days.append((day, []))
                seen = [:]
            }
            let text = search.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = text.lowercased()
            if let at = seen[key] {
                let line = days[days.count - 1].lines[at]
                days[days.count - 1].lines[at] = Line(id: line.id, text: line.text, times: line.times + 1)
            } else {
                seen[key] = days[days.count - 1].lines.count
                days[days.count - 1].lines.append(Line(id: id, text: text, times: 1))
                id += 1
            }
        }
        return days
    }

    /// The region most of its searches float over.
    private var region: String? {
        var counts: [Int: Int] = [:]
        for search in cloud?.searches ?? [] where search.region >= 0 { counts[search.region, default: 0] += 1 }
        return counts.max { $0.value < $1.value }.flatMap { map.regions.regions[$0.key]?.label.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(region.map { "cloud over \($0)" } ?? "cloud")
                .font(PlexMono.font(.semibold, size: 16))
                .foregroundStyle(theme.ink.color)
                .padding(.trailing, 36)
                .fixedSize(horizontal: false, vertical: true)
            if let cloud, !cloud.searches.isEmpty {
                Text("\(cloud.searches.count.formatted()) searches   \(Format.date(cloud.season.lowerBound)) – \(Format.date(cloud.season.upperBound))")
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.secondary.color)
                    .padding(.top, 6)
                PanelHeading(text: "by week", theme: theme)
                WeekBars(times: cloud.searches.map(\.time), season: cloud.season, theme: theme)
                if !themes.isEmpty {
                    PanelHeading(text: "themes", theme: theme)
                    ForEach(themes, id: \.name) { item in
                        ThemeRow(item: item, total: cloud.searches.count, isOpen: open == item.name, theme: theme,
                                 toggle: { open = open == item.name ? nil : item.name },
                                 find: { model.findSearch($0) })
                    }
                    if others > 0 {
                        Text("and \(others.formatted()) searches on their own")
                            .font(PlexMono.font(.regular, size: 11))
                            .foregroundStyle(theme.secondary.color)
                            .padding(.top, 8)
                    }
                }
                PanelHeading(text: "every search", theme: theme)
                ForEach(days, id: \.day) { day in
                    Text(day.day)
                        .font(PlexMono.font(.regular, size: 10))
                        .foregroundStyle(theme.secondary.color)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    ForEach(day.lines) { line in
                        SearchLine(text: line.text, times: line.times, theme: theme) { model.findSearch(line.text) }
                    }
                }
                if cloud.searches.count > Self.shown {
                    Text("and \((cloud.searches.count - Self.shown).formatted()) older")
                        .font(PlexMono.font(.regular, size: 11))
                        .foregroundStyle(theme.secondary.color)
                        .padding(.top, 12)
                }
            } else if looked {
                Text("clear sky here now. it comes back with the weather, as you move through time.")
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.secondary.color)
                    .padding(.top, 8)
                    .padding(.trailing, 36)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LoadingNote(text: "gathering the searches", theme: theme).padding(.top, 12)
            }
        }
        // Follows the weather here as time moves.
        .task(id: model.scene?.id) {
            guard let scene = model.scene else { return }
            let (map, x, y) = (map, x, y)
            let found = await Task.detached(priority: .userInitiated) { () -> Clouds.Cloud? in
                guard let weather = scene.weather, let end = scene.weatherEnd else { return nil }
                return map.clouds.cloud(at: x, y, weather: weather, endingAt: end)
            }.value
            guard !Task.isCancelled else { return }
            cloud = found
            looked = true
            guard let searches = found?.searches, !searches.isEmpty else { return themes = [] }
            let (library, known) = (library, vectors)
            let missing = searches.map(\.id).filter { known[$0] == nil }
            let (gist, fetched) = await Task.detached(priority: .userInitiated) { () -> ((themes: [CloudTheme], rest: [Clouds.Search]), [String: [Float]]) in
                let fetched = missing.isEmpty ? [:] : (try? library.textVectors(of: missing)) ?? [:]
                return (CloudThemes.find(searches, vectors: known.merging(fetched) { a, _ in a }), fetched)
            }.value
            vectors.merge(fetched) { a, _ in a }
            guard !Task.isCancelled else { return }
            themes = gist.themes
            others = gist.rest.count
        }
    }
}

/// One theme of a cloud: its name, its share of the cloud, and its most typical searches, or
/// all of them once it's open.
private struct ThemeRow: View {
    let item: CloudTheme
    let total: Int
    let isOpen: Bool
    let theme: Theme
    let toggle: () -> Void
    let find: (String) -> Void

    private static let examples = 3

    /// Each different search once, most typical first.
    private var lines: [(text: String, times: Int)] {
        var order: [String] = []
        var counts: [String: (text: String, times: Int)] = [:]
        for search in item.searches {
            let text = search.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = text.lowercased()
            if counts[key] == nil { order.append(key) }
            counts[key] = (counts[key]?.text ?? text, (counts[key]?.times ?? 0) + 1)
        }
        return order.map { counts[$0]! }
    }

    var body: some View {
        let lines = lines
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(isOpen ? "▾" : "▸").font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color)
                        Text(item.name)
                            .font(PlexMono.font(.medium, size: 12))
                            .foregroundStyle(theme.ink.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.searches.count.formatted())
                            .font(PlexMono.font(.regular, size: 10))
                            .foregroundStyle(theme.secondary.color)
                    }
                    GeometryReader { geometry in
                        Rectangle().fill(theme.ink.color)
                            .frame(width: max(2, geometry.size.width * Double(item.searches.count) / Double(max(total, 1))))
                    }
                    .frame(height: 3)
                    .padding(.leading, 16)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Show only the most typical" : "Show every search in this theme")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(isOpen ? lines.count : Self.examples).enumerated()), id: \.offset) { _, line in
                    SearchLine(text: line.text, times: line.times, theme: theme) { find(line.text) }
                }
                if !isOpen, lines.count > Self.examples {
                    Button("\((lines.count - Self.examples).formatted()) more", action: toggle)
                        .buttonStyle(.plain)
                        .font(PlexMono.font(.regular, size: 10))
                        .foregroundStyle(theme.secondary.color)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }
            }
            .padding(.leading, 10)
            .padding(.top, 4)
        }
        .padding(.top, 10)
    }
}

/// One search in a cloud: press it to find what it was about.
private struct SearchLine: View {
    let text: String
    let times: Int
    let theme: Theme
    let find: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: find) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(PlexSans.font(size: 13))
                    .foregroundStyle(hovering ? theme.ground.color : theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if times > 1 {
                    Text("×\(times)")
                        .font(PlexMono.font(.regular, size: 10))
                        .foregroundStyle(hovering ? theme.ground.color : theme.secondary.color)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovering ? theme.ink.color : .clear, in: Rectangle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Find what this was about in your library")
    }
}

/// How many searches a cloud gathered each week of its season.
private struct WeekBars: View {
    let times: [Int]
    let season: ClosedRange<Int>
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let week = 7 * 86_400
            let count = max(1, (season.upperBound - season.lowerBound + week - 1) / week)
            var bins = [Int](repeating: 0, count: count)
            for time in times where season.contains(time) {
                bins[min((time - season.lowerBound) / week, count - 1)] += 1
            }
            let high = Double(bins.max() ?? 1), step = size.width / Double(count)
            for (i, n) in bins.enumerated() where n > 0 {
                let height = size.height * Double(n) / max(high, 1)
                context.fill(Path(CGRect(x: Double(i) * step, y: size.height - height, width: max(1, step - 2), height: height)),
                             with: .color(theme.ink.color))
            }
        }
        .frame(height: 32)
        .accessibilityLabel("Searches per week")
    }
}

/// How many times a region was touched, per three months.
private struct QuarterBars: View {
    let times: [Int]
    let axis: MonthAxis
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let months = axis.counts(of: times)
            let bins = stride(from: 0, to: months.count, by: 3).map { start in
                months[start..<min(start + 3, months.count)].reduce(0, +)
            }
            let high = Double(bins.max() ?? 1), step = size.width / Double(max(bins.count, 1))
            let barsHeight = size.height - 14
            for (i, count) in bins.enumerated() where count > 0 {
                let height = barsHeight * Double(count) / max(high, 1)
                context.fill(Path(CGRect(x: Double(i) * step, y: barsHeight - height, width: max(1, step - 1), height: height)),
                             with: .color(theme.ink.color))
            }
            let years = axis.years()
            let every = max(1, years.count / 5)
            for (position, year) in years.enumerated() where position % every == 0 {
                let x = axis.fraction(of: year.time) * size.width
                context.draw(Text(String(year.year)).font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color),
                             at: CGPoint(x: min(x + 12, size.width - 14), y: size.height - 6))
            }
        }
        .frame(height: 56)
        .accessibilityLabel("When you engaged with this region")
    }
}

struct RegionPath: View {
    let path: [Int]
    let map: LibraryMap
    let theme: Theme
    let pick: (Int) -> Void

    var body: some View {
        WrappingStack(spacing: 4) {
            ForEach(Array(path.enumerated()), id: \.element) { position, id in
                if position > 0 {
                    Text("›").font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.secondary.color)
                }
                Button(map.regions.regions[id]?.label ?? "") { pick(id) }
                    .buttonStyle(KeyStyle(theme: theme))
            }
        }
    }
}

private struct FlowKeys: View {
    let ids: [Int]
    let map: LibraryMap
    let theme: Theme
    let pick: (Int) -> Void

    var body: some View {
        WrappingStack(spacing: 4) {
            ForEach(ids, id: \.self) { id in
                if let region = map.regions.regions[id] {
                    Button { pick(id) } label: {
                        HStack(spacing: 6) {
                            Text(region.label)
                            Text(region.count.formatted()).font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color)
                        }
                    }
                    .buttonStyle(KeyStyle(theme: theme))
                }
            }
        }
    }
}

/// Keys that wrap onto new lines, each no wider than the panel.
struct WrappingStack: Layout {
    var spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        return CGSize(width: width, height: rows(subviews, width: width).last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(subviews, width: bounds.width) {
            for placed in row.items {
                subviews[placed.index].place(at: CGPoint(x: bounds.minX + placed.x, y: bounds.minY + row.y + (row.height - placed.size.height) / 2),
                                             proposal: ProposedViewSize(placed.size))
            }
        }
    }

    private struct Row {
        var y = 0.0
        var height = 0.0
        var items: [(index: Int, x: Double, size: CGSize)] = []
    }

    private func rows(_ subviews: Subviews, width: Double) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x = 0.0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(row)
                row = Row(y: y)
                x = 0
            }
            row.items.append((index, x, size))
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A grid of items: pictures where there are any, words where there aren't.
struct ItemGrid: View {
    let items: [Int32]
    let map: LibraryMap
    let library: Library
    let mode: ImageMode
    let theme: Theme
    let pick: (Int32) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], spacing: 4) {
            ForEach(items, id: \.self) { index in
                let item = map.items[Int(index)]
                Button { pick(index) } label: {
                    GridCell(item: item, library: library, mode: mode, theme: theme)
                }
                .buttonStyle(.plain)
                .help(item.text ?? "")
            }
        }
    }
}

struct GridCell: View {
    let item: MapItem
    let library: Library
    let mode: ImageMode
    let theme: Theme
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(theme.surface.color)
            if let thumb = item.thumb {
                GeometryReader { geometry in
                    LibraryPicture(url: library.file(thumb), longEdge: 320, mode: mode, theme: theme)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            } else {
                Text(String((item.text ?? "").prefix(90)))
                    .font(PlexSans.font(size: 10))
                    .foregroundStyle(theme.secondary.color)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(Rectangle().strokeBorder(hovering ? theme.ink.color : theme.rule.color, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }
}
