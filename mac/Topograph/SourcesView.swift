import AppKit
import SwiftUI
import TopographCore
import UniformTypeIdentifiers

/// Add your history: drop an export on the left, see where each source stands on the right.
struct SourcesScreen: View {
    let model: AppModel
    let theme: Theme
    /// The source whose steps for getting an archive are showing.
    @State private var showingGuide: String?
    @State private var targeted = false
    @State private var folderCheck: [URL]?
    @State private var connecting: String?
    @State private var account = ""
    @AppStorage("requestedSources") private var requested = ""
    @State private var wordsModelReady = MapRecipe.wordsModelIsDownloaded()

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 58) {
                addColumn.frame(width: 460)
                table.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 58)
            .padding(.top, 36)
            .padding(.bottom, 24)
        }
        .background(theme.ground.color)
        .task {
            while !Task.isCancelled {
                await model.refreshSources()
                await model.pipeline.checkHydrateElsewhere()
                wordsModelReady = MapRecipe.wordsModelIsDownloaded()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Adding

    private var addColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("add your history").font(PlexMono.font(.semibold, size: 18)).foregroundStyle(theme.ink.color)
            Text("Each platform will send you an archive of everything you’ve posted, liked and saved. Drop it here. Topograph reads it on this Mac and keeps a copy of the images; nothing is uploaded.")
                .font(PlexSans.font(size: 14))
                .lineSpacing(5)
                .foregroundStyle(theme.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            dropZone.padding(.top, 22)
            jobStatus.padding(.top, 12)
            mapChoice.padding(.top, 36)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            RingsGlyph(theme: theme).frame(width: 56, height: 40)
            Text("drop export zips or folders").font(PlexMono.font(.medium, size: 13)).foregroundStyle(theme.ink.color)
            Button("choose files…") { choose() }
                .buttonStyle(KeyStyle(theme: theme))
                .disabled(model.pipeline.running != nil)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .background(targeted ? theme.hair.color : theme.surface.color)
        .overlay(RoundedRectangle(cornerRadius: 3)
            .strokeBorder(theme.ink.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .overlay(alignment: .topLeading) {
            Text("IN").font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color).padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(".zip · folder").font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color).padding(10)
        }
        .dropDestination(for: URL.self) { urls, _ in
            take(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }

    /// What's running or just happened, with the choices that come with it.
    @ViewBuilder
    private var jobStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let job = model.pipeline.running {
                Text(job.title).font(PlexMono.font(.medium, size: 11)).foregroundStyle(theme.ink.color)
                Text(model.pipeline.line).font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.secondary.color).lineLimit(2)
                Button("❚❚ pause") { model.pipeline.pause() }.buttonStyle(KeyStyle(theme: theme))
            } else if let failure = model.pipeline.failure {
                Text(failure).font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let folders = folderCheck, model.pipeline.running == nil {
                Text("A first look at these folders, with nothing read yet:")
                    .font(PlexSans.font(size: 13)).foregroundStyle(theme.ink.color)
                ScrollView {
                    Text(model.pipeline.log.joined(separator: "\n"))
                        .font(PlexMono.font(.regular, size: 10))
                        .foregroundStyle(theme.secondary.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                HStack(spacing: 4) {
                    Button("read these folders") {
                        folderCheck = nil
                        start(title: "reading your files", ["files"] + folders.map(\.path))
                    }
                    .buttonStyle(KeyStyle(theme: theme, on: true))
                    Button("not now") { folderCheck = nil }.buttonStyle(KeyStyle(theme: theme))
                }
            }
            if let sources = model.sources, sources.unplaced > 0, model.pipeline.running == nil, folderCheck == nil {
                HStack(spacing: 8) {
                    Button("update the map") {
                        start(title: "updating the map", ["build"] + (sources.shownMap.map { ["--map", $0.rawValue] } ?? []))
                    }
                        .buttonStyle(KeyStyle(theme: theme))
                    Text("\(sources.unplaced.formatted()) items aren’t on it yet")
                        .font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.secondary.color)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.begin { response in
            if response == .OK { take(panel.urls) }
        }
    }

    private func take(_ urls: [URL]) {
        guard model.pipeline.running == nil else { return }
        let exports = urls.filter { DroppedSource.classify($0) == .export }
        let folders = urls.filter { DroppedSource.classify($0) == .folder }
        if !exports.isEmpty {
            start(title: "importing \(exports.count == 1 ? exports[0].lastPathComponent : "\(exports.count) exports")",
                  ["import"] + exports.map(\.path))
        } else if !folders.isEmpty {
            // Your own folders get a dry run first, so you see what would be taken.
            model.pipeline.run(.init(title: "looking through your folders", arguments: ["files"] + folders.map(\.path) + ["--dry-run"]),
                               library: model.libraryRoot) { _ in folderCheck = folders }
        }
    }

    private func start(title: String, _ arguments: [String]) {
        model.pipeline.run(.init(title: title, arguments: arguments), library: model.libraryRoot) { _ in
            Task { await model.refreshSources() }
            model.load()
        }
    }

    // MARK: The map

    private var mapChoice: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("how the map is made").font(PlexMono.font(.semibold, size: 18)).foregroundStyle(theme.ink.color)
            Text("The same items, arranged different ways. Build as many as you like and switch between them. All of it happens on this Mac.")
                .font(PlexSans.font(size: 14))
                .lineSpacing(5)
                .foregroundStyle(theme.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Rectangle().fill(theme.ink.color).frame(height: 1).padding(.top, 16)
            ForEach(Array(MapRecipe.allCases.enumerated()), id: \.element) { position, recipe in
                mapRow(recipe, position: position)
                Rectangle().fill(theme.rule.color).frame(height: 1)
            }
        }
    }

    private func mapRow(_ recipe: MapRecipe, position: Int) -> some View {
        let built = model.sources?.maps[recipe] != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(recipe.title) { model.showMap(recipe) }
                    .buttonStyle(KeyStyle(theme: theme, led: model.map?.recipe == recipe))
                    .disabled(!built || model.openingMap != nil)
                if recipe == .suggested {
                    Text("suggested").font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color)
                }
                Spacer(minLength: 8)
                mapStatus(recipe, position: position)
            }
            Text(recipe.summary)
                .font(PlexSans.font(size: 13))
                .foregroundStyle(theme.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if !built, recipe.readsWords, !wordsModelReady {
                Text(MapRecipe.wordsDownloadNote)
                    .font(PlexMono.font(.regular, size: 10))
                    .foregroundStyle(theme.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    /// How far along a map is, and the key that moves it on.
    @ViewBuilder
    private func mapStatus(_ recipe: MapRecipe, position: Int) -> some View {
        let number = PlexMono.font(.semibold, size: 13)
        let note = PlexMono.font(.regular, size: 11)
        let busy = model.pipeline.running != nil
        if model.pipeline.running?.arguments.contains(recipe.rawValue) == true {
            LoadingNote(text: "building", theme: theme)
        } else if model.openingMap == recipe {
            LoadingNote(text: "opening", theme: theme)
        } else if !model.sourcesAreKnown {
            LoadingNote(text: "checking", theme: theme, delay: Double(position) * 0.1)
        } else if let placed = model.sources?.maps[recipe] {
            let waiting = model.sources?.waiting(on: recipe) ?? 0
            if waiting > 0, model.map?.recipe != recipe {
                Text("\(waiting.formatted()) not on it").font(note).foregroundStyle(theme.secondary.color)
                Button("update") { build(recipe) }
                    .buttonStyle(KeyStyle(theme: theme, led: false))
                    .disabled(busy)
            }
            Text(placed.formatted()).font(number).foregroundStyle(theme.ink.color)
        } else {
            Text("not built").font(note).foregroundStyle(theme.secondary.color)
            Button("build") { build(recipe) }
                .buttonStyle(KeyStyle(theme: theme, led: false))
                .disabled(busy)
        }
    }

    private func build(_ recipe: MapRecipe) {
        model.pipeline.run(.init(title: "building the \(recipe.title) map", arguments: ["build", "--map", recipe.rawValue]),
                           library: model.libraryRoot) { succeeded in
            Task { await model.refreshSources() }
            if succeeded { model.showMap(recipe) }
        }
    }

    // MARK: The table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("ch").frame(width: 50, alignment: .leading)
                Text("source").frame(width: 196, alignment: .leading)
                Text("status")
                Spacer()
                // A refresh that's under way, once every row has something to show.
                if model.checkingSources, model.sourcesAreKnown {
                    LoadingNote(text: "checking", theme: theme).padding(.trailing, 12)
                }
                Text("items")
            }
            .font(PlexMono.font(.regular, size: 10))
            .foregroundStyle(theme.secondary.color)
            .padding(.bottom, 8)
            Rectangle().fill(theme.ink.color).frame(height: 1)
            ForEach(Array(Row.all.enumerated()), id: \.element.key) { position, row in
                rowView(row, position: position)
                Rectangle().fill(theme.rule.color).frame(height: 1)
            }
        }
    }

    private func platform(_ key: String) -> LibrarySources.Platform? {
        model.sources?.platforms.first { $0.platform == key && $0.items > 0 }
    }

    private func isRequested(_ key: String) -> Bool { requested.split(separator: ",").contains(Substring(key)) }

    private func toggleRequested(_ key: String) {
        var list = requested.split(separator: ",").map(String.init)
        if let at = list.firstIndex(of: key) { list.remove(at: at) } else { list.append(key) }
        requested = list.joined(separator: ",")
    }

    /// `position` is its place in the list, which sets where its lamp falls in the wave.
    private func rowView(_ row: Row, position: Int) -> some View {
        let found = row.platforms.compactMap(platform)
        let items = found.reduce(0) { $0 + $1.items }
        let added = items > 0
        let waitingForEmail = !added && isRequested(row.key)
        // Until the library's answered, nothing can be called missing.
        let known = model.sourcesAreKnown
        return HStack(alignment: .top, spacing: 0) {
            Channel(state: added ? .on : waitingForEmail || !known ? .waiting : .off, theme: theme)
                .frame(width: 50, alignment: .leading)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(PlexMono.font(.semibold, size: 13)).foregroundStyle(theme.ink.color)
                Text(subtitle(row, found: found, waiting: waitingForEmail))
                    .font(PlexMono.font(.regular, size: 10))
                    .foregroundStyle(theme.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 196, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(waitingForEmail ? "Waiting for the email. Drop the archive here when it arrives." : added ? row.added : row.description)
                    .font(PlexSans.font(size: 14))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if added, let note = row.note {
                    Text(note).font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color)
                }
                if row.canHydrate, let progress = hydrateProgress(found) { hydrateRow(progress, key: row.key) }
                if !added, row.isSync { notAddedActions(row) }
                if let guide = row.guide { guideActions(row, guide: guide, added: added) }
            }
            Spacer(minLength: 16)
            if added {
                Text(items.formatted()).font(PlexMono.font(.semibold, size: 15)).foregroundStyle(theme.ink.color)
            } else if !known {
                LoadingNote(text: "checking", theme: theme, delay: Double(position) * 0.1)
            } else if row.isSync {
                EmptyView()
            } else {
                Text(waitingForEmail ? "waiting" : "not added").font(PlexMono.font(.regular, size: 11)).foregroundStyle(theme.secondary.color)
            }
        }
        .padding(.vertical, 14)
    }

    /// How to get this source's archive, opened from its row. Worth having after it's added
    /// too, for bringing in a newer one.
    @ViewBuilder
    private func guideActions(_ row: Row, guide: Guide, added: Bool) -> some View {
        let open = showingGuide == row.key
        HStack(spacing: 12) {
            Button("how to get the archive \(open ? "▴" : "▾")") { showingGuide = open ? nil : row.key }
                .buttonStyle(.plain)
                .font(PlexMono.font(.regular, size: 10))
                .underline()
                .foregroundStyle(theme.ink.color)
            if !added {
                Button(isRequested(row.key) ? "not requested after all" : "i’ve requested it") { toggleRequested(row.key) }
                    .buttonStyle(.plain)
                    .font(PlexMono.font(.regular, size: 10))
                    .foregroundStyle(theme.secondary.color)
            }
        }
        if open {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { position, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(format: "%02d", position + 1)).font(PlexMono.font(.medium, size: 12)).foregroundStyle(theme.ink.color)
                        Text(step).font(PlexSans.font(size: 14)).foregroundStyle(theme.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("\(guide.linkTitle) ↗") { NSWorkspace.shared.open(guide.link) }
                    .buttonStyle(KeyStyle(theme: theme))
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }

    private func subtitle(_ row: Row, found: [LibrarySources.Platform], waiting: Bool) -> String {
        if waiting { return "requested" }
        if row.key == "files", let roots = model.sources?.fileRoots, !roots.isEmpty {
            return roots.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }.joined(separator: " · ")
        }
        if row.isSync, let account = row.platforms.compactMap({ model.sources?.syncAccounts[$0] }).first { return account }
        if let newest = found.compactMap(\.newest).max(), newest > 0 { return "through \(Format.date(newest))" }
        return row.subtitle
    }

    private func hydrateProgress(_ found: [LibrarySources.Platform]) -> (done: Int, total: Int)? {
        let waiting = found.reduce(0) { $0 + $1.waiting }, done = found.reduce(0) { $0 + $1.fetched }
        return waiting > 0 ? (done, done + waiting) : nil
    }

    @ViewBuilder
    private func hydrateRow(_ progress: (done: Int, total: Int), key: String) -> some View {
        let mine = model.pipeline.running?.arguments.first == "hydrate"
        let elsewhere = model.pipeline.hydrateElsewhere
        let checked = model.pipeline.hasCheckedHydrate
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(mine || elsewhere ? "hydrate · fetching images for kept posts" : "hydrate · images still to fetch")
                if !checked { LoadingNote(text: "checking", theme: theme) }
                Spacer()
                Text("\(progress.done.formatted()) / \(progress.total.formatted())")
            }
            .font(PlexMono.font(.regular, size: 10))
            .foregroundStyle(theme.secondary.color)
            ProgressTicks(fraction: Double(progress.done) / Double(max(progress.total, 1)), theme: theme).frame(height: 11)
            Text("gentle pace · deleted posts stay as links" + (elsewhere ? " · running in a terminal" : ""))
                .font(PlexMono.font(.regular, size: 10))
                .foregroundStyle(theme.secondary.color)
            if mine {
                Button("❚❚ pause") { model.pipeline.pause() }.buttonStyle(KeyStyle(theme: theme))
            } else if !elsewhere, checked {
                Button("▶ fetch") { start(title: "fetching images", ["hydrate"]) }
                    .buttonStyle(KeyStyle(theme: theme))
                    .disabled(model.pipeline.running != nil)
            }
        }
        .frame(maxWidth: 480)
    }

    @ViewBuilder
    private func notAddedActions(_ row: Row) -> some View {
        if row.isSync {
            if connecting == row.key {
                HStack(spacing: 4) {
                    TextField("", text: $account, prompt: Text(row.accountPrompt).foregroundStyle(theme.secondary.color))
                        .textFieldStyle(.plain)
                        .font(PlexMono.font(.regular, size: 11))
                        .padding(.horizontal, 8)
                        .frame(width: 180, height: 26)
                        .background(theme.surface.color)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.rule.color, lineWidth: 1))
                    Button("read") {
                        let name = account.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        connecting = nil
                        account = ""
                        start(title: "reading \(row.title)", ["sync", row.platforms[0], name])
                    }
                    .buttonStyle(KeyStyle(theme: theme))
                }
                Text("Reads only what’s already public on your account. No password, nothing posted.")
                    .font(PlexMono.font(.regular, size: 10)).foregroundStyle(theme.secondary.color)
            } else {
                Button("connect") { connecting = row.key }.buttonStyle(KeyStyle(theme: theme, led: false))
            }
        }
    }
}

private struct Channel: View {
    enum State { case on, waiting, off }
    let state: State
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size)
            switch state {
            case .on:
                context.fill(Path(box), with: .color(theme.ink.color))
            case .off:
                context.stroke(Path(box.insetBy(dx: 0.5, dy: 0.5)), with: .color(theme.ink.color), lineWidth: 1)
            case .waiting:
                // A 1-bit hatch: in progress, not there yet.
                var hatch = Path()
                for offset in stride(from: -size.height, to: size.width, by: 2.5) {
                    hatch.move(to: CGPoint(x: offset, y: size.height))
                    hatch.addLine(to: CGPoint(x: offset + size.height, y: 0))
                }
                context.clip(to: Path(box))
                context.stroke(hatch, with: .color(theme.ink.color), lineWidth: 0.8)
                context.stroke(Path(box.insetBy(dx: 0.5, dy: 0.5)), with: .color(theme.ink.color), lineWidth: 1)
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// Progress as a row of ticks in a thin frame.
private struct ProgressTicks: View {
    let fraction: Double
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size)
            context.stroke(Path(box.insetBy(dx: 0.5, dy: 0.5)), with: .color(theme.ink.color), lineWidth: 1)
            let end = (size.width - 4) * min(max(fraction, 0), 1)
            for x in stride(from: 2.0, to: 2 + end, by: 3) {
                context.fill(Path(CGRect(x: x, y: 2, width: 2, height: size.height - 4)), with: .color(theme.ink.color))
            }
        }
    }
}

private struct RingsGlyph: View {
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for (w, h) in [(size.width - 1, size.height - 1), (size.width * 0.62, size.height * 0.62), (size.width * 0.3, size.height * 0.3)] {
                context.stroke(Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)),
                               with: .color(theme.ink.color), lineWidth: 1)
            }
            context.fill(Path(CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(theme.ink.color))
        }
    }
}

struct Guide: Equatable {
    let title: String
    let steps: [String]
    let linkTitle: String
    let link: URL

    static let instagram = Guide(title: "instagram archive", steps: [
        "Open Accounts Center, then Your information and permissions.",
        "Choose Download your information, then Download or transfer information.",
        "Pick All time, format JSON, media quality High.",
        "Instagram emails you when it’s ready, usually within two days.",
    ], linkTitle: "open accounts center", link: URL(string: "https://accountscenter.instagram.com/info_and_permissions/")!)

    static let x = Guide(title: "x archive", steps: [
        "Open Settings, then Your account.",
        "Choose Download an archive of your data and confirm it’s you.",
        "X emails you when it’s ready, usually within a day or two.",
    ], linkTitle: "open x settings", link: URL(string: "https://x.com/settings/download_your_data")!)

    static let facebook = Guide(title: "facebook archive", steps: [
        "Open Accounts Center, then Your information and permissions.",
        "Choose Download your information and pick your Facebook account.",
        "Pick All time, format JSON, media quality High.",
        "Facebook emails you when it’s ready, usually within two days.",
    ], linkTitle: "open accounts center", link: URL(string: "https://accountscenter.facebook.com/info_and_permissions/")!)

    static let takeout = Guide(title: "google takeout", steps: [
        "Open Google Takeout and deselect everything.",
        "Select YouTube and YouTube Music and My Activity.",
        "For both, set the format to JSON rather than HTML.",
        "Google emails you a link when it’s ready.",
    ], linkTitle: "open google takeout", link: URL(string: "https://takeout.google.com/")!)
}

private struct Row {
    let key: String
    let title: String
    let platforms: [String]
    let subtitle: String
    let description: String
    let added: String
    var note: String?
    var guide: Guide?
    var canHydrate = false
    var isSync = false
    var accountPrompt = ""

    static let all: [Row] = [
        Row(key: "instagram", title: "instagram", platforms: ["instagram"], subtitle: "archive",
            description: "Your posts, likes, saves and comments.",
            added: "Imported your posts, likes, saves and comments.", guide: .instagram, canHydrate: true),
        Row(key: "x", title: "x", platforms: ["x"], subtitle: "archive",
            description: "Your posts, replies, reposts, likes and bookmarks.",
            added: "Imported your posts, replies, reposts, likes and bookmarks.",
            note: "likes carry no date in the archive · placed at the post’s date, marked ~", guide: .x, canHydrate: true),
        Row(key: "files", title: "your files", platforms: ["files"], subtitle: "folders on this mac",
            description: "Screenshots, downloads and working files. Drop a folder to see what would be read.",
            added: "Screenshots, downloads and working files you made or kept.",
            note: "sensitive folders skipped · .topographignore honored"),
        Row(key: "facebook", title: "facebook", platforms: ["facebook"], subtitle: "archive",
            description: "Your posts, photos, saved items and comments.",
            added: "Imported your posts, photos, saved items and comments.", guide: .facebook),
        Row(key: "youtube", title: "youtube", platforms: ["youtube"], subtitle: "google takeout",
            description: "Watch history, liked videos, your playlists.",
            added: "Imported your watch history, likes and playlists.", guide: .takeout, canHydrate: true),
        Row(key: "google", title: "google activity", platforms: ["google"], subtitle: "google takeout",
            description: "Searches and image searches. They show curiosity more than taste, so they start hidden on the terrain.",
            added: "Imported your searches. They start hidden on the terrain.",
            note: "sensitive searches skipped · sites you visited are left out", guide: .takeout),
        Row(key: "bluesky", title: "bluesky", platforms: ["bluesky"], subtitle: "live sync",
            description: "Connect once and read your posts and likes.",
            added: "Read your public posts, reposts and likes.", isSync: true, accountPrompt: "your.handle"),
        Row(key: "arena", title: "are.na", platforms: ["arena"], subtitle: "live sync",
            description: "Connect once and read the blocks in your channels.",
            added: "Read the blocks in your channels.", isSync: true, accountPrompt: "your-username"),
    ]
}
