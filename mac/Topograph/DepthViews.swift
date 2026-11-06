import AppKit
import SwiftUI
import TopographCore

/// Themes that came back after a long quiet, as then and now.
struct EchoesScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var echoes: [Echo]?
    /// The scene `echoes` were found in. A newer one means they're being looked for again.
    @State private var foundIn: UUID?
    @State private var width = 900.0
    /// The region whose echo is showing in color.
    @State private var colored: Int?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("themes that came back")
                    .font(PlexMono.font(.semibold, size: 16))
                    .foregroundStyle(theme.ink.color)
                    .padding(.bottom, 20)
                if foundIn != model.scene?.id {
                    LoadingNote(text: "looking for themes that came back", theme: theme)
                        .padding(.bottom, 20)
                } else if let echoes, echoes.isEmpty {
                    Text("Nothing here has gone quiet for nine months and come back.")
                        .font(PlexSans.font(size: 13)).foregroundStyle(theme.secondary.color)
                }
                ForEach(echoes ?? []) { echo in
                    row(echo)
                }
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The rows stay clear of the side panel.
            .padding(.trailing, model.selection == nil ? 0 : DetailPanel.width)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .background(theme.ground.color)
        .task(id: model.scene?.id) {
            guard let scene = model.scene, let axis = model.axis else { return }
            echoes = await Task.detached(priority: .userInitiated) {
                Echoes.find(map: scene.map, visible: scene.visible, axis: axis)
            }.value
            guard !Task.isCancelled else { return }
            foundIn = scene.id
        }
    }

    @ViewBuilder
    private func row(_ echo: Echo) -> some View {
        if let map = model.map, let library = model.library, let axis = model.axis, let region = map.regions.regions[echo.region] {
            HStack(alignment: .top, spacing: Self.gutter) {
                // Each side is only as wide as its pictures, and the middle takes what's left. That
                // keeps the silence halfway between the images on either side of it.
                VStack(alignment: .leading, spacing: Self.titleSpacing) {
                    Button(region.label) { model.openRegion(echo.region) }
                        .buttonStyle(KeyStyle(theme: theme))
                        .onHover { colored = $0 ? echo.region : nil }
                    side(label: "then  \(Format.month(axis.edges[echo.then.lowerBound]))", items: echo.thenItems,
                         width: picturesWidth(min(echo.thenItems.count, columns)), mode: mode(of: echo), map: map, library: library)
                }
                .frame(width: picturesWidth(min(echo.thenItems.count, columns)), alignment: .leading)
                silence(echo)
                VStack(alignment: .leading, spacing: Self.titleSpacing) {
                    Color.clear.frame(height: Self.titleHeight)
                    side(label: "now  \(Format.month(axis.edges[echo.now.lowerBound]))", items: echo.nowItems,
                         width: picturesWidth(columns), mode: mode(of: echo), map: map, library: library)
                }
            }
            // So the middle's line can run the height of the taller side.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 24)
            .overlay(alignment: .top) { Rectangle().fill(theme.rule.color).frame(height: 1) }
        }
    }

    /// How long it went quiet, with a line down to an arrow between then and now. The arrow
    /// lands in the gap between the two rows of pictures, or level with a lone row's middle.
    private func silence(_ echo: Echo) -> some View {
        let twoRows = max(echo.thenItems.count, echo.nowItems.count) > columns
        return VStack(spacing: 0) {
            // Level with the theme's name, in the key beside it.
            Text(Echoes.duration(months: echo.silentMonths))
                .font(PlexMono.font(.medium, size: 11))
                .foregroundStyle(theme.ink.color)
                .frame(height: Self.titleHeight)
            Text("of near-silence")
                .font(PlexMono.font(.regular, size: 10))
                .foregroundStyle(theme.secondary.color)
            SilenceArrow()
                .stroke(theme.ink.color, lineWidth: 1)
                .frame(maxHeight: .infinity)
                .padding(.top, 5)
            Color.clear.frame(height: twoRows ? Self.cell + Self.spacing / 2 : Self.cell / 2)
        }
        .frame(maxWidth: .infinity)
    }

    /// In color while the pointer's on the echo's name.
    private func mode(of echo: Echo) -> ImageMode {
        colored == echo.region ? .color : model.imageMode
    }

    private func picturesWidth(_ count: Int) -> Double {
        Double(count) * (Self.cell + Self.spacing) - Self.spacing
    }

    /// One side of an echo, two rows of pictures at most.
    private func side(label: String, items: [Int32], width: Double, mode: ImageMode, map: LibraryMap, library: Library) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(PlexMono.font(.medium, size: 11))
                .foregroundStyle(theme.ink.color)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.spacing), count: columns), alignment: .leading, spacing: Self.spacing) {
                ForEach(items.prefix(columns * 2), id: \.self) { index in
                    Button { model.openItem(index) } label: {
                        GridCell(item: map.items[Int(index)], library: library, mode: mode, theme: theme)
                            .frame(width: Self.cell, height: Self.cell)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: picturesWidth(columns), alignment: .leading)
            .frame(width: width, alignment: .leading)
        }
    }

    private static let cell = 84.0
    private static let spacing = 4.0
    /// The column between the sides, and the space either side of it.
    private static let middle = 132.0
    private static let gutter = 12.0
    /// A key's height, and the space under the row of the theme's name.
    private static let titleHeight = 26.0
    private static let titleSpacing = 12.0
    private static let padding = 24.0

    /// How many pictures fit across one side.
    private var columns: Int {
        let open = width - (model.selection == nil ? 0 : DetailPanel.width)
        let side = (open - Self.padding * 2 - Self.middle - Self.gutter * 2) / 2
        return max(2, Int((side + Self.spacing) / (Self.cell + Self.spacing)))
    }
}

/// A line down from the top to a line across the bottom, which has a head at each end.
private struct SilenceArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let middle = rect.midX.rounded() + 0.5, bottom = rect.maxY.rounded() + 0.5, head = 4.5
        path.move(to: CGPoint(x: middle, y: rect.minY))
        path.addLine(to: CGPoint(x: middle, y: bottom))
        path.move(to: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom))
        path.move(to: CGPoint(x: rect.minX + head, y: bottom - head))
        path.addLine(to: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX + head, y: bottom + head))
        path.move(to: CGPoint(x: rect.maxX - head, y: bottom - head))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom))
        path.addLine(to: CGPoint(x: rect.maxX - head, y: bottom + head))
        return path
    }
}

/// Your visual taste with the subject stripped away: each picture's strongest color. On
/// the wheel, hue goes around and lighter is toward the middle. As a cylinder, hue goes
/// around, more colorful is farther out, and light rises to the top. Through time, it's
/// Strata's chart with bands of color for layers.
struct PaletteScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var hover: Hover?
    @State private var cardHeight: CGFloat = 0
    @State private var space: PaletteSpace?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if model.paletteView == .time {
                    ColorStrataCanvas(model: model, theme: theme)
                } else {
                    PaletteCanvas(space: space, scene: model.scene, root: model.library?.root, controller: model.palette,
                                  camera: model.paletteCamera, selected: selectedItem, imageMode: model.imageMode,
                                  onCamera: { camera, size in
                                      model.paletteCamera = camera
                                      model.paletteSize = size
                                  },
                                  onHover: { hover = $0 },
                                  onPick: { model.openItem($0) })
                }
                PaletteChrome(model: model, theme: theme, space: space)
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
        }
        .background(theme.ground.color)
        .task(id: model.map?.items.count) {
            guard let map = model.map else { return }
            space = await Task.detached(priority: .userInitiated) { PaletteSpace(items: map.items) }.value
        }
    }

    private var selectedItem: Int32? {
        if case .item(let index) = model.selection { return index }
        return nil
    }
}

/// Color through time, on Strata's chart.
private struct ColorStrataCanvas: View {
    let model: AppModel
    let theme: Theme
    @State private var fallback: StrataModel?
    @State private var colors: [Int: CGColor]?
    @State private var tip: StrataTip?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let chart = model.scene?.colorStrata ?? fallback, let colors {
                StrataCanvas(model: chart, labels: { ColorBands.names.indices.contains($0) ? ColorBands.names[$0] : nil },
                             patterns: [:], colors: colors, range: model.scene?.range, marked: markedItem, theme: theme,
                             onTip: { tip = $0 }, onPick: { model.openColorBand($0) })
                    .padding(.top, 34)
                    .padding(.trailing, model.selection == nil ? 0 : DetailPanel.width)
            } else {
                LoadingNote(text: "sorting colors by time", theme: theme)
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
                    .offset(x: tip.x, y: tip.y + 34)
                    .allowsHitTesting(false)
            }
        }
        // For a scene made while another view was showing, and for the bands' own colors.
        .task(id: model.scene?.id) {
            guard let scene = model.scene, let axis = model.axis else { return }
            if colors == nil {
                let means = await Task.detached(priority: .userInitiated) { ColorBands.colors(of: scene.map.items) }.value
                colors = Dictionary(uniqueKeysWithValues: means.enumerated().map { band, mean in
                    (band, CGColor(srgbRed: CGFloat(mean.x), green: CGFloat(mean.y), blue: CGFloat(mean.z), alpha: 1))
                })
            }
            guard scene.colorStrata == nil else { return }
            let share = model.paletteShowsShare
            fallback = await Task.detached(priority: .userInitiated) {
                StrataModel(colorsOf: scene.map, visible: scene.visible, axis: axis, share: share)
            }.value
        }
    }

    private var markedItem: MapItem? {
        if case .item(let index) = model.selection, let map = model.map { return map.items[Int(index)] }
        return nil
    }
}

/// What floats over the palette: how it's standing, where you are, the zoom keys.
private struct PaletteChrome: View {
    let model: AppModel
    let theme: Theme
    let space: PaletteSpace?

    private static let kinds: [(PaletteViewKind, String, KeyEquivalent)] = [
        (.wheel, "wheel", "e"), (.cylinder, "cylinder", "d"), (.time, "through time", "j"),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.paletteView != .time { axisLabels }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Self.kinds, id: \.1) { kind, label, key in
                        Button(label) { choose(kind) }
                            .buttonStyle(KeyStyle(theme: theme, led: model.paletteView == kind))
                            .hotkey("⌘\(String(key.character).uppercased())", key: key, model: model, theme: theme)
                    }
                    if model.paletteView == .time {
                        Button("stacked (percent)") { model.paletteShowsShare.toggle() }
                            .buttonStyle(KeyStyle(theme: theme, led: model.paletteShowsShare))
                            .help("On, each month fills the height, showing its mix of colors. Off, thickness shows how much there was.")
                            .padding(.leading, 10)
                    }
                }
                Spacer()
                if model.paletteView == .wheel {
                    PaletteMinimap(model: model, theme: theme, space: space)
                }
                // Through time, the chart's years are along the bottom here.
                if model.paletteView != .time, let scene = model.scene, let map = model.map {
                    Readout(visible: scene.visible.count, total: map.items.count, waiting: map.waiting, theme: theme)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if model.paletteView != .time {
                VStack(spacing: 4) {
                    Spacer()
                    // Their shortcuts are in the Map menu.
                    Button("+", action: model.palette.zoomIn).accessibilityLabel("Zoom in")
                        .hotkey("⌘+", placement: .beside, model: model, theme: theme)
                    Button("−", action: model.palette.zoomOut).accessibilityLabel("Zoom out")
                        .hotkey("⌘-", placement: .beside, model: model, theme: theme)
                    Button("fit", action: model.palette.fit).accessibilityLabel("Show everything")
                        .hotkey("⌘0", placement: .beside, model: model, theme: theme)
                }
                .buttonStyle(SquareKeyStyle(theme: theme))
                .padding(.trailing, 16 + (model.selection == nil ? 0 : DetailPanel.width))
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    private func choose(_ kind: PaletteViewKind) {
        model.paletteView = kind
        // The canvas may be just coming back, so this waits a turn for it to be there.
        if kind != .time {
            DispatchQueue.main.async { model.palette.setCylinder(kind == .cylinder) }
        }
    }

    /// Which way is which, once it's standing up.
    @ViewBuilder
    private var axisLabels: some View {
        let camera = model.paletteCamera
        if camera.solid > 0.5, camera.pitch > 0.3, model.paletteSize.width > 0 {
            let height = PaletteCamera.cylinderHeight * camera.solid
            axisLabel("light", at: camera.project(x: 0, y: 0, z: height, size: model.paletteSize).point)
            axisLabel("dark", at: camera.project(x: 0, y: 0, z: -height, size: model.paletteSize).point)
        }
    }

    private func axisLabel(_ text: String, at point: CGPoint) -> some View {
        Text(text)
            .font(PlexMono.font(.medium, size: 10))
            .foregroundStyle(theme.ink.color)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(theme.surface.color, in: Rectangle())
            .position(x: point.x, y: point.y)
            .allowsHitTesting(false)
    }
}

/// The whole wheel with what's showing marked, while zoomed in.
private struct PaletteMinimap: View {
    let model: AppModel
    let theme: Theme
    let space: PaletteSpace?
    @State private var picture: CGImage?
    @State private var drawing = false
    @Environment(\.displayScale) private var displayScale

    private let side = 168.0
    /// Units from the middle shown either way, which takes in the guide ring.
    private let reach = 1.1

    var body: some View {
        if model.paletteCamera.isZoomedIn, let scene = model.scene, model.paletteSize.width > 0 {
            let shown = model.paletteCamera.shownOnWheel(size: model.paletteSize)
            let perUnit = side / (reach * 2)
            MinimapDial(picture: picture, side: side,
                        frame: CGRect(x: (shown.minX + reach) * perUnit, y: (shown.minY + reach) * perUnit,
                                      width: shown.width * perUnit, height: shown.height * perUnit),
                        theme: theme, tinted: false,
                        onMove: { model.palette.center(x: $0.x / perUnit - reach, y: $0.y / perUnit - reach) },
                        onPointer: { model.palette.pointerIsOnMinimap = $0 })
                .task(id: scene.id) { await drawLatest(perUnit: perUnit) }
        }
    }

    /// One at a time, going on to whatever's newest.
    private func drawLatest(perUnit: Double) async {
        guard !drawing, let space else { return }
        drawing = true
        defer { drawing = false }
        let (scale, side, reach, ground) = (displayScale, side, reach, theme.surface.cg)
        var drawn: UUID?
        while let scene = model.scene, scene.id != drawn {
            drawn = scene.id
            picture = await Task.detached(priority: .utility) { () -> CGImage? in
                let pixels = Int(side * scale)
                guard let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                c.setFillColor(ground)
                c.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
                let toPixels = Double(pixels) / (reach * 2)
                for place in space.showing(scene.visible).reversed() {
                    let p = space.places[Int(place)]
                    c.setFillColor(CGColor(srgbRed: CGFloat(p.color.x), green: CGFloat(p.color.y), blue: CGFloat(p.color.z), alpha: 1))
                    c.fill(CGRect(x: (Double(p.wheel.x) + reach) * toPixels - scale, y: Double(pixels) - (Double(p.wheel.y) + reach) * toPixels - scale,
                                  width: scale * 2, height: scale * 2))
                }
                return c.makeImage()
            }.value
        }
    }
}

/// Wander: start anywhere, see an item and its nearest neighbors, pick one, keep walking.
struct DriftScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var trail: [Int32] = []
    @State private var detail: ItemDetail?
    @State private var detailOf: Int32?

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
                    if detailOf != current {
                        LoadingNote(text: "finding what's nearby", theme: theme)
                    }
                    let neighbors = (detailOf == current ? detail?.neighbors ?? [] : []).compactMap { map.indexOfID[$0] }
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
            if !Task.isCancelled { detailOf = current }
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
                    if let sequences {
                        Text("\(sequences.count.formatted()) pieces, in versions")
                            .font(PlexMono.font(.semibold, size: 16))
                            .foregroundStyle(theme.ink.color)
                    } else {
                        LoadingNote(text: "looking for versions of your work", theme: theme)
                    }
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
