import AppKit
import ImageIO
import SwiftUI
import TopographCore
import UniformTypeIdentifiers

/// An item's picture as large as the window allows, opened from the side panel: the picture,
/// and under it what the panel says about it. The panel's drawer grows from where
/// it is to fill the window while what was in it fades, and the picture flies from the panel,
/// its frame moving and growing together so each corner goes straight to its place. Closing
/// runs it back. Esc, ×, or a click outside the picture closes it; ← and → step through an
/// item's pictures. Laid out over the whole window from the start, so the picture knows where
/// it's going.
struct LargePicture: View {
    let model: AppModel
    let library: Library
    let map: LibraryMap
    let theme: Theme
    let enlarged: Enlarged
    @State private var detail: ItemDetail?
    /// Where the picture has room, in the window.
    @State private var room: CGRect?
    /// Your own file itself, when it's a picture this Mac can read and is still there: the
    /// library keeps only a copy 1600 pixels long.
    @State private var original: URL?

    private var index: Int32 { enlarged.index }
    private var hero: Int { enlarged.hero }
    private var item: MapItem { map.items[Int(index)] }
    private var media: [MediaFile] { detail?.media ?? [] }

    private func show(_ next: Int) {
        guard !media.isEmpty else { return }
        model.enlarged = Enlarged(index: index, hero: (next + media.count) % media.count, from: enlarged.from, copy: nil)
    }

    private func close() {
        model.closeLargePicture()
    }

    static let opening = Animation.easeInOut(duration: 0.32)
    static let closing = Animation.easeInOut(duration: 0.26)

    private var opened: Bool { model.pictureOpen }

    private var aspect: Double { hero == 0 ? Double(item.aspect ?? 1) : 1 }

    /// The picture's place once open: as large as fits, with a margin, clear of the window's
    /// buttons and the × along the top.
    private var target: CGRect? {
        guard let room else { return nil }
        let space = CGRect(x: room.minX + 24, y: room.minY + 48, width: room.width - 48, height: room.height - 72)
        guard space.width > 0, space.height > 0 else { return nil }
        let size = space.width / space.height > aspect
            ? CGSize(width: space.height * aspect, height: space.height)
            : CGSize(width: space.width, height: space.width / aspect)
        return CGRect(x: space.midX - size.width / 2, y: space.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// What's shown: your own file when it can be, else the library's copy, which the panel
    /// already had in hand so there's something to fly at once.
    private var url: URL? {
        if !media.isEmpty {
            let shown = media[min(hero, media.count - 1)]
            let copy = (shown.display ?? shown.thumb).map(library.file)
            return hero == 0 ? original ?? copy : copy
        }
        return enlarged.copy
    }

    var body: some View {
        GeometryReader { window in
            let origin = window.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                // The drawer, grown from the panel to the whole window.
                // Open, its rule is just past the window's left edge, out of sight.
                let whole = window.frame(in: .global)
                let drawer = (opened || model.drawerFrame.isEmpty ? CGRect(x: whole.minX - 2, y: whole.minY, width: whole.width + 2, height: whole.height)
                              : model.drawerFrame)
                    .offsetBy(dx: -origin.x, dy: -origin.y)
                theme.ground.color
                    .overlay(alignment: .leading) { Rectangle().fill(theme.ink.color).frame(width: 1) }
                    .frame(width: drawer.width, height: drawer.height)
                    .position(x: drawer.midX, y: drawer.midY)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { space in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                            .onAppear {
                                room = space.frame(in: .global)
                                // A frame later, so the picture is drawn in the panel's place first and
                                // has somewhere to grow from: started in the same update, it would jump.
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(16))
                                    // Unless something else was chosen in the meantime.
                                    guard model.enlarged?.index == enlarged.index else { return }
                                    withAnimation(LargePicture.opening) { model.pictureOpen = true }
                                }
                            }
                            .onChange(of: space.frame(in: .global)) { room = $1 }
                    }
                    if media.count > 1 { strip }
                    Rectangle().fill(theme.ink.color).frame(height: 1)
                    details
                }
                .overlay(alignment: .topTrailing) {
                    // Esc is `AppModel.escape`.
                    Button("×") { close() }
                        .buttonStyle(SquareKeyStyle(theme: theme))
                        .accessibilityLabel("Close")
                        .hotkey("esc", model: model, theme: theme)
                        .padding(.top, 10)
                        .padding(.trailing, 16)
                }
                .opacity(opened ? 1 : 0)

                if let url, let place = opened ? target : enlarged.from.isEmpty ? target : enlarged.from {
                    let local = place.offsetBy(dx: -origin.x, dy: -origin.y)
                    LibraryPicture(url: url, longEdge: url == original ? 3200 : 1520, mode: .color, theme: theme)
                        .overlay(Rectangle().strokeBorder(theme.rule.color, lineWidth: 1))
                        .frame(width: local.width, height: local.height)
                        // Clicks on the picture itself don't close it.
                        .onTapGesture {}
                        .position(x: local.midX, y: local.midY)
                }
            }
        }
        .background {
            // ← and → step through the pictures.
            Button("") { show(hero - 1) }.keyboardShortcut(.leftArrow, modifiers: []).hidden()
            Button("") { show(hero + 1) }.keyboardShortcut(.rightArrow, modifiers: []).hidden()
        }
        .task(id: index) {
            let (library, id, recipe) = (library, item.id, model.map?.recipe)
            detail = try? await Task.detached { try library.detail(of: id, in: recipe) }.value
            guard item.platform == "files", let link = detail?.url, link.hasPrefix("file://"), let file = URL(string: link) else { return }
            original = await Task.detached(priority: .userInitiated) { Self.readable(file) ? file : nil }.value
        }
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let text = item.text {
                    Text(text)
                        .font(PlexSans.font(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text([item.author.map { "@\($0)" }, Format.platform(item.platform),
                      detail?.createdAt.map { "published \(Format.date($0))" }].compactMap { $0 }.joined(separator: "  "))
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.secondary.color)
                if let id = item.region, let path = map.regions.regions[id]?.path {
                    // Opening the region closes this, as any other selection does.
                    RegionPath(path: path, map: map, theme: theme) { model.openRegion($0) }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ItemActions(item: item, detail: detail, theme: theme)
        }
        .padding(16)
    }

    private var strip: some View {
        HStack(spacing: 4) {
            ForEach(media.indices, id: \.self) { i in
                if let path = media[i].thumb {
                    Button { show(i) } label: {
                        LibraryPicture(url: library.file(path), longEdge: 208, mode: .color, theme: theme)
                            .frame(width: 52, height: 52)
                            .overlay(Rectangle().strokeBorder(i == hero ? theme.ink.color : theme.rule.color, lineWidth: i == hero ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    /// A picture ImageIO can open, not a document it only previews.
    nonisolated static func readable(_ file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .pdf)
    }
}

/// Which picture is showing large, and of which item.
struct Enlarged: Equatable {
    let index: Int32
    let hero: Int
    /// Where the picture was in the panel, in the window, to fly from and back to.
    let from: CGRect
    /// The picture the panel was showing.
    let copy: URL?
}

/// What you can do with an item outside the app: open it where it came from, or find the file.
struct ItemActions: View {
    let item: MapItem
    let detail: ItemDetail?
    let theme: Theme
    @State private var fileMissing = false

    var body: some View {
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
