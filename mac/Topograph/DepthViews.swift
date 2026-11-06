import AppKit
import SwiftUI
import TopographCore

/// Themes that came back after a long quiet, as then and now.
struct EchoesScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var echoes: [Echo]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Text("themes that came back")
                    .font(PlexMono.font(.semibold, size: 16))
                    .foregroundStyle(theme.ink.color)
                if let echoes, echoes.isEmpty {
                    Text("Nothing here has gone quiet for nine months and come back.")
                        .font(PlexSans.font(size: 13)).foregroundStyle(theme.secondary.color)
                }
                ForEach(echoes ?? []) { echo in
                    row(echo)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.ground.color)
        .task(id: model.scene?.id) {
            guard let scene = model.scene, let axis = model.axis else { return }
            echoes = await Task.detached(priority: .userInitiated) {
                Echoes.find(map: scene.map, visible: scene.visible, axis: axis)
            }.value
        }
    }

    @ViewBuilder
    private func row(_ echo: Echo) -> some View {
        if let map = model.map, let library = model.library, let axis = model.axis, let region = map.regions.regions[echo.region] {
            VStack(alignment: .leading, spacing: 8) {
                Button(region.label) { model.openRegion(echo.region) }
                    .buttonStyle(KeyStyle(theme: theme))
                strip(label: "then  \(Format.month(axis.edges[echo.then.lowerBound]))", items: echo.thenItems, map: map, library: library)
                HStack(spacing: 8) {
                    Rectangle().fill(theme.rule.color).frame(width: 24, height: 1)
                    Text("\(echo.silentMonths) months of near-silence")
                        .font(PlexMono.font(.regular, size: 11))
                        .foregroundStyle(theme.secondary.color)
                }
                strip(label: "now   \(Format.month(axis.edges[echo.now.lowerBound]))", items: echo.nowItems, map: map, library: library)
            }
        }
    }

    private func strip(label: String, items: [Int32], map: LibraryMap, library: Library) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(PlexMono.font(.medium, size: 11))
                .foregroundStyle(theme.ink.color)
                .frame(width: 104, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items, id: \.self) { index in
                        Button { model.openItem(index) } label: {
                            GridCell(item: map.items[Int(index)], library: library, mode: model.imageMode, theme: theme)
                                .frame(width: 88, height: 88)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Your visual taste with the subject stripped away: each picture's strongest color,
/// hue around the circle, lighter toward the middle.
struct PaletteScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var image: CGImage?
    @State private var dots: [(index: Int32, point: CGPoint)] = []
    @State private var hover: Hover?
    @State private var cardHeight: CGFloat = 0

    private struct Job: Equatable {
        let scene: UUID?
        let size: CGSize
        let dark: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 2)
                        .interpolation(.none)
                }
                PointerArea(onMove: { moved($0, size: geometry.size) },
                            onExit: { hover = nil },
                            onClick: { if let hover { model.openItem(hover.item) } })
                if let hover, let map = model.map, let library = model.library {
                    HoverCard(item: map.items[Int(hover.item)], library: library, theme: theme)
                        .frame(width: 260)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { cardHeight = $0 }
                        .offset(x: min(hover.location.x + 14, geometry.size.width - 270),
                                y: max(8, min(hover.location.y + 14, geometry.size.height - cardHeight - 8)))
                        .allowsHitTesting(false)
                }
            }
            .task(id: Job(scene: model.scene?.id, size: geometry.size, dark: theme.ink.red > 0.5)) {
                await draw(size: geometry.size)
            }
        }
        .background(theme.ground.color)
    }

    private func draw(size: CGSize) async {
        guard let scene = model.scene, size.width > 0 else { return }
        let ground = theme.ground.cg
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, [(index: Int32, point: CGPoint)]) in
            let scale = 2.0
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, []) }
            c.setFillColor(ground)
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let radius = min(size.width, size.height) / 2 - 24
            var dots: [(index: Int32, point: CGPoint)] = []
            for index in scene.visible {
                let item = scene.map.items[Int(index)]
                guard let rgb = item.color else { continue }
                let at = PaletteLayout.position(rgb: rgb, seed: Int(index))
                let point = CGPoint(x: size.width / 2 + at.x * radius, y: size.height / 2 + at.y * radius)
                dots.append((index, point))
                c.setFillColor(CGColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                                       blue: CGFloat(rgb & 0xff) / 255, alpha: 1))
                c.fill(CGRect(x: point.x * scale - 4, y: (size.height - point.y) * scale - 4, width: 8, height: 8))
            }
            return (c.makeImage(), dots)
        }.value
        image = result.0
        dots = result.1
    }

    private func moved(_ point: CGPoint, size: CGSize) {
        var best: Int32?
        var bestDistance: CGFloat = 64     // within 8 points
        for dot in dots {
            let dx = dot.point.x - point.x, dy = dot.point.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = dot.index
            }
        }
        hover = best.map { Hover(item: $0, location: point, mapSize: size) }
    }
}

/// Mouse movement and clicks for a SwiftUI view, in points, y down.
struct PointerArea: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void
    let onClick: () -> Void

    final class Area: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        var onClick: (() -> Void)?
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onExit?() }
        override func mouseUp(with event: NSEvent) { onClick?() }
    }

    func makeNSView(context: Context) -> Area { Area() }

    func updateNSView(_ view: Area, context: Context) {
        view.onMove = onMove
        view.onExit = onExit
        view.onClick = onClick
    }
}

/// Wander: start anywhere, see an item and its nearest neighbors, pick one, keep walking.
struct DriftScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var trail: [Int32] = []
    @State private var detail: ItemDetail?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let map = model.map, let library = model.library {
                            ForEach(Array(trail.enumerated()), id: \.offset) { position, index in
                                Button { trail = Array(trail.prefix(position + 1)) } label: {
                                    GridCell(item: map.items[Int(index)], library: library, mode: model.imageMode, theme: theme)
                                        .frame(width: 64, height: 64)
                                }
                                .buttonStyle(.plain)
                                .id(position)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: trail.count) { reader.scrollTo(trail.count - 1) }
            }
            .frame(width: 88)
            .overlay(alignment: .trailing) { Rectangle().fill(theme.rule.color).frame(width: 1) }
            VStack(alignment: .leading, spacing: 12) {
                if let current = trail.last, let map = model.map, let library = model.library {
                    let item = map.items[Int(current)]
                    HStack(alignment: .top, spacing: 16) {
                        if let thumb = detail?.media.first?.display ?? item.thumb {
                            LibraryPicture(url: library.file(thumb), longEdge: 1200, mode: model.imageMode, theme: theme)
                                .id(current)
                                .aspectRatio(CGFloat(item.aspect ?? 1), contentMode: .fit)
                                .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            if let text = item.text {
                                Text(text).font(PlexSans.font(size: 13)).foregroundStyle(theme.ink.color).textSelection(.enabled)
                            }
                            Text(Format.meta(item)).font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.secondary.color)
                            HStack(spacing: 4) {
                                Button("details") { model.openItem(current) }.buttonStyle(KeyStyle(theme: theme))
                                Button("somewhere else") { start() }.buttonStyle(KeyStyle(theme: theme))
                            }
                        }
                        .frame(width: 280, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    PanelHeading(text: "nearest in taste", theme: theme)
                    let neighbors = (detail?.neighbors ?? []).compactMap { map.indexOfID[$0] }
                    HStack(spacing: 4) {
                        ForEach(neighbors.prefix(10), id: \.self) { index in
                            Button { trail.append(index) } label: {
                                GridCell(item: map.items[Int(index)], library: library, mode: model.imageMode, theme: theme)
                                    .frame(width: 96, height: 96)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.ground.color)
        .onAppear { if trail.isEmpty { start() } }
        .task(id: trail.last) {
            guard let current = trail.last, let library = model.library, let id = model.map?.items[Int(current)].id else { return }
            detail = try? await Task.detached { try library.detail(of: id) }.value
        }
    }

    /// From what's selected, or else somewhere at random among your pictures.
    private func start() {
        if trail.isEmpty, case .item(let index) = model.selection {
            trail = [index]
        } else if let pick = model.scene?.pictures.randomElement() {
            trail.append(pick)
        }
    }
}

/// Versions of one piece, in order: the twelve screenshots of the same layout, poster-v1
/// to final. Opening one plays its evolution.
struct ProcessScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var sequences: [[Int32]]?
    @State private var open: [Int32]?
    @State private var frame = 0
    @State private var playing = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("\((sequences ?? []).count.formatted()) pieces, in versions")
                        .font(PlexMono.font(.semibold, size: 16))
                        .foregroundStyle(theme.ink.color)
                    if let map = model.map, let library = model.library {
                        ForEach(sequences ?? [], id: \.self) { sequence in
                            Button {
                                open = sequence
                                frame = 0
                                playing = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(sequence.count)")
                                        .font(PlexMono.font(.medium, size: 11))
                                        .foregroundStyle(theme.ink.color)
                                        .frame(width: 28, alignment: .leading)
                                    ForEach(sequence.prefix(6), id: \.self) { index in
                                        GridCell(item: map.items[Int(index)], library: library, mode: model.imageMode, theme: theme)
                                            .frame(width: 56, height: 56)
                                    }
                                }
                                .padding(4)
                                .overlay(Rectangle().strokeBorder(open == sequence ? theme.ink.color : Color.clear, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .frame(width: 430)
            .overlay(alignment: .trailing) { Rectangle().fill(theme.rule.color).frame(width: 1) }
            player.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.ground.color)
        .task(id: model.map?.items.count) {
            guard let map = model.map else { return }
            sequences = await Task.detached(priority: .userInitiated) { ProcessSequences.find(items: map.items) }.value
        }
        .task(id: playing) {
            while playing, let open, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(420))
                guard playing else { return }
                if frame + 1 < open.count { frame += 1 } else { playing = false }
            }
        }
    }

    @ViewBuilder
    private var player: some View {
        if let open, let map = model.map, let library = model.library, frame < open.count {
            let item = map.items[Int(open[frame])]
            VStack(spacing: 12) {
                if let thumb = item.thumb {
                    LibraryPicture(url: library.file(thumb), longEdge: 640, mode: model.imageMode, theme: theme)
                        .aspectRatio(CGFloat(item.aspect ?? 1), contentMode: .fit)
                        .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                        .frame(maxHeight: .infinity)
                }
                HStack(spacing: 8) {
                    Button(playing ? "■" : "▶") {
                        if !playing && frame + 1 >= open.count { frame = 0 }
                        playing.toggle()
                    }
                    .buttonStyle(SquareKeyStyle(theme: theme))
                    Button("‹") { playing = false; frame = max(0, frame - 1) }.buttonStyle(SquareKeyStyle(theme: theme))
                    Button("›") { playing = false; frame = min(open.count - 1, frame + 1) }.buttonStyle(SquareKeyStyle(theme: theme))
                    Text("\(frame + 1) / \(open.count)   \(item.time.map(Format.date) ?? "")")
                        .font(PlexMono.font(.regular, size: 11))
                        .foregroundStyle(theme.secondary.color)
                    Spacer()
                    Button("details") { model.openItem(open[frame]) }.buttonStyle(KeyStyle(theme: theme))
                }
            }
            .padding(20)
        } else {
            Text("Pick a piece to watch it change.")
                .font(PlexSans.font(size: 13))
                .foregroundStyle(theme.secondary.color)
        }
    }
}
