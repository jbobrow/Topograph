import AppKit
import SwiftUI
import TopographCore

/// The side panel: one item, or one region.
struct DetailPanel: View {
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
                    case nil:
                        EmptyView()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("×") { model.selection = nil }
                .buttonStyle(SquareKeyStyle(theme: theme))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
                .padding(16)
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(theme.ground.color)
        .overlay(alignment: .leading) { Rectangle().fill(theme.ink.color).frame(width: 1) }
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
    @State private var fileMissing = false
    @State private var tributaries: [Int32] = []

    private var item: MapItem { map.items[Int(index)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let media = detail?.media, !media.isEmpty {
                let picture = media[min(hero, media.count - 1)]
                if let path = picture.display ?? picture.thumb {
                    LibraryPicture(url: library.file(path), longEdge: 1520, mode: model.imageMode, theme: theme)
                        .aspectRatio(CGFloat(hero == 0 ? (item.aspect ?? 1) : 1), contentMode: .fit)
                        .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                        .padding(.trailing, 32)
                }
                if media.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(media.indices, id: \.self) { i in
                                if let path = media[i].thumb {
                                    Button { hero = i } label: {
                                        LibraryPicture(url: library.file(path), longEdge: 208, mode: model.imageMode, theme: theme)
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
                if model.imageMode == .color, !picture.palette.isEmpty {
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
            actions.padding(.top, 12)

            PanelHeading(text: "history", theme: theme)
            ForEach(Array((detail?.interactions ?? []).enumerated()), id: \.offset) { _, interaction in
                HStack {
                    Text(Interactions.verb(interaction.type).lowercased() + (interaction.collection.map { " to “\($0)”" } ?? ""))
                        .foregroundStyle(theme.ink.color)
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
            if !tributaries.isEmpty {
                PanelHeading(text: "tributaries: kept in the months before", theme: theme)
                ItemGrid(items: tributaries, map: map, library: library, mode: model.imageMode, theme: theme) {
                    model.openItem($0, pan: true)
                }
            }
            let neighbors = (detail?.neighbors ?? []).compactMap { map.indexOfID[$0] }
            if !neighbors.isEmpty {
                PanelHeading(text: "nearest in taste", theme: theme)
                ItemGrid(items: neighbors, map: map, library: library, mode: model.imageMode, theme: theme) {
                    model.openItem($0, pan: true)
                }
            }
        }
        .task(id: index) {
            let (library, id) = (library, item.id)
            detail = try? await Task.detached { try library.detail(of: id) }.value
            guard item.mine, let store = await model.embeddings() else { return }
            let (index, map) = (index, map)
            tributaries = await Task.detached { Tributaries.find(of: index, map: map, embeddings: store) }.value
        }
    }

    private func when(_ interaction: Interaction) -> String {
        guard interaction.at != 0 else { return "" }
        return interaction.estimated ? "~" + Format.month(interaction.at) : Format.date(interaction.at)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if item.platform == "files" {
                if let file = fileURL {
                    Button(fileMissing ? "file not found: it may have moved" : "show in finder") {
                        if FileManager.default.fileExists(atPath: file.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        } else {
                            fileMissing = true
                        }
                    }
                    .buttonStyle(KeyStyle(theme: theme))
                }
                if let source = detail?.media.first?.originalURL, let url = URL(string: source), let host = url.host {
                    Button("source: \(host)") { NSWorkspace.shared.open(url) }.buttonStyle(KeyStyle(theme: theme))
                }
            } else if let link = detail?.url, let url = URL(string: link) {
                Button("open on \(Format.platform(item.platform))") { NSWorkspace.shared.open(url) }
                    .buttonStyle(KeyStyle(theme: theme))
            }
        }
    }

    private var fileURL: URL? {
        guard let link = detail?.url, link.hasPrefix("file://") else { return nil }
        return URL(string: link)
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
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        let (map, library, id, title) = (map, library, region.id, region.label)
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                let files = Moodboard.picks(region: id, map: map).compactMap { map.items[Int($0)].thumb }.map(library.file)
                return Moodboard.render(title: title, files: files)
            }.value
            try? data?.write(to: destination, options: .atomic)
            exporting = false
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
                ItemGrid(items: mostResonant, map: map, library: library, mode: model.imageMode, theme: theme) {
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
