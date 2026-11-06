import AppKit
import QuartzCore
import SwiftUI
import TopographCore

enum Section: String, CaseIterable, Sendable {
    case terrain, strata, echoes, palette, drift, process, sources

    /// The views that follow the filters and the time scrubber.
    var isFiltered: Bool { self == .terrain || self == .strata || self == .palette || self == .echoes }
}

enum Selection: Equatable {
    case item(Int32)
    case region(Int)
    /// What a search by meaning found, best first.
    case found(String)
    /// The pictures in one band of color.
    case colorBand(Int)
}

/// The palette's three ways of looking: two across color, and one through time.
enum PaletteViewKind: Sendable {
    case wheel, cylinder, time
}

/// Loads the library off the main thread and keeps what's showing.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase = Phase.loading
    private(set) var library: Library?
    private(set) var map: LibraryMap?
    private(set) var scene: TerrainScene?
    private(set) var whereYouAre: [Int] = []
    /// What the map is showing, kept here for the minimap alone.
    var viewport: MapViewport?
    private(set) var axis: MonthAxis?
    /// Items per month, whatever's filtered, for the time scrubber's bars.
    private(set) var monthCounts: [Int] = []
    private(set) var platforms: [String] = []
    private(set) var isPlaying = false
    var section = Section.terrain
    /// ⌘ is down, so every key shows its shortcut.
    private(set) var commandHeld = false
    var selection: Selection?
    var hover: Hover?
    /// How pictures show on the map and in most views. Gray unless you've changed it.
    private(set) var mapImageMode: ImageMode {
        didSet { UserDefaults.standard.set(mapImageMode.rawValue, forKey: "imageMode") }
    }
    /// Palette keeps its own, in color unless you've changed it, since color is its subject.
    private var paletteImageMode: ImageMode {
        didSet { UserDefaults.standard.set(paletteImageMode.rawValue, forKey: "paletteImageMode") }
    }
    /// How pictures show in the view you're looking at.
    var imageMode: ImageMode {
        get { section == .palette ? paletteImageMode : mapImageMode }
        set {
            if section == .palette { paletteImageMode = newValue } else { mapImageMode = newValue }
        }
    }
    var filter: MapFilter = {
        var filter = MapFilter()
        // Searches show curiosity more than taste, so they start hidden.
        filter.hiddenPlatforms = ["google"]
        return filter
    }() {
        didSet { if filter != oldValue { applyFilter() } }
    }
    let controller = TerrainController()
    let palette = PaletteController()
    /// Kept here so the palette is as you left it when you come back to it.
    var paletteCamera = PaletteCamera()
    var paletteSize = CGSize.zero
    var paletteView = PaletteViewKind.wheel {
        didSet { if paletteView != oldValue, paletteView == .time { applyFilter() } }
    }
    /// Whether color through time shows each color's part of the month, or how much of it.
    var paletteShowsShare = true {
        didSet { if paletteShowsShare != oldValue { applyFilter() } }
    }
    let pipeline = PipelineRunner()
    /// Read fresh from the file every few seconds while the Sources page is showing.
    var sources: LibrarySources?
    var sourcesSummary: String? {
        guard let sources else { return nil }
        let active = sources.platforms.filter { $0.items > 0 }.count
        return "\(sources.platforms.reduce(0) { $0 + $1.items }.formatted()) items · \(active) sources"
    }
    var libraryRoot: URL { library?.root ?? Library.defaultRoot }

    func refreshSources() async {
        let root = libraryRoot
        checkingSources = true
        defer { checkingSources = false }
        let shown = map?.recipe ?? chosenMap
        sources = await Task.detached(priority: .utility) { try? Library(root: root).sources(showing: shown) }.value
        sourcesAreKnown = true
    }

    /// The map you picked. Kept by this app, so the library stays read-only. With no pick,
    /// or one that isn't built, the library says which it built last.
    private(set) var chosenMap = UserDefaults.standard.string(forKey: "mapRecipe").flatMap(MapRecipe.init)
    /// The map on its way in, while the one before it stays on screen.
    private(set) var openingMap: MapRecipe?

    func showMap(_ recipe: MapRecipe) {
        chosenMap = recipe
        UserDefaults.standard.set(recipe.rawValue, forKey: "mapRecipe")
        guard map?.recipe != recipe else {
            Task { await refreshSources() }
            return
        }
        openingMap = recipe
        load()
    }

    /// Whether the library's been asked yet. Until then, no source can be said to be missing.
    private(set) var sourcesAreKnown = false
    /// Whether the library's being asked right now.
    private(set) var checkingSources = false

    private var search: SearchIndex?
    private var fullPeak = 0.0
    private var updating = false
    private var updateAgain = false
    private var lastUpdate: CFTimeInterval = 0
    /// Terrain, Strata and Palette are cheap to redraw and worth seeing at full speed. Echoes
    /// does more work per update, so it follows more slowly.
    private var updateStep: CFTimeInterval {
        switch section {
        case .terrain, .strata, .palette: 0
        default: 0.14
        }
    }
    /// Goes up with each newly loaded map, so work on an older one isn't shown.
    private var mapGeneration = 0
    /// The current filter's items by time. Its times also make the timeline's bars.
    private var slicer: TimeSlicer?
    private var player: Timer?
    private var lastPlayStep: CFTimeInterval = 0
    /// Seconds of the timeline per second of playing: about seven months.
    private static let playSpeed = 30.0 * 86400 / 0.14
    private var embeddingsTask: Task<EmbeddingStore?, Never>?
    private var encoderTask: Task<CLIPEncoder?, Never>?

    init() {
        mapImageMode = UserDefaults.standard.string(forKey: "imageMode").flatMap(ImageMode.init) ?? .gray
        paletteImageMode = UserDefaults.standard.string(forKey: "paletteImageMode").flatMap(ImageMode.init) ?? .color
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated { self?.commandHeld = held }
            return event
        }
        // While it's playing, space pauses. It's for moving the map the rest of the time.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49, !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            let playing = MainActor.assumeIsolated { self?.isPlaying ?? false }
            guard playing else { return event }
            MainActor.assumeIsolated { self?.stopPlaying() }
            return nil
        }
        // A key released in another app never reaches this one.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.commandHeld = false }
        }
    }

    func load() {
        // Ranks are positions in the map being replaced.
        filter.nearest = nil
        Task {
            do {
                let filter = self.filter
                let chosen = chosenMap
                defer { openingMap = nil }
                let (library, loaded, search, peak, scene, slicer) = try await Task.detached(priority: .userInitiated) {
                    let library = try Library()
                    let map = try library.map(chosen)
                    let search = SearchIndex(items: map.items)
                    // Contour heights come from what shows by default, not what starts hidden.
                    let shown = map.items.indices.filter { map.items[$0].platform != "google" }.map(Int32.init)
                    let peak = DensityField(items: map.items, visible: shown).peak
                    let scene = TerrainScene(map: map, visible: filter.visible(in: map.items, search: search), fullPeak: peak)
                    return (library, map, search, peak, scene, TimeSlicer(filter: filter, items: map.items, search: search))
                }.value
                self.library = library
                let map = loaded.withRegions(loaded.regions.renamed(regionNames(on: loaded.recipe)))
                // Places mean nothing from one map to the next, so don't stay zoomed in on one.
                if let before = self.map, before.recipe != map.recipe { controller.fit() }
                self.map = map
                embeddingsTask = nil
                let times = map.items.compactMap(\.time)
                axis = MonthAxis(times: times + map.waitingTimes)
                monthCounts = axis?.counts(of: slicer.times) ?? []
                self.slicer = slicer
                strataOrder = nil
                mapGeneration += 1
                // Largest first, like the viewer's chips in the order they turn up.
                let tally = map.items.reduce(into: [String: Int]()) { $0[$1.platform, default: 0] += 1 }
                platforms = tally.keys.sorted { tally[$0]! > tally[$1]! }
                self.search = search
                fullPeak = peak
                self.scene = TerrainScene(map: map, visible: scene.visible, fullPeak: peak)
                selection = nil
                phase = .ready
                Task { await refreshSources() }
            } catch {
                phase = .failed(error.localizedDescription)
                // With no library yet, the way forward is adding your history.
                if case LibraryError.notFound = error { section = .sources }
            }
        }
    }

    func fail(_ message: String) { phase = .failed(message) }

    // MARK: Your names for regions

    /// Kept by this app, not in the library, so the library stays read-only. They're matched
    /// by region number, so a new layout, which renumbers regions, clears them. Each map
    /// numbers its regions separately, so each keeps its own names.
    private func regionNames(on recipe: MapRecipe) -> [Int: String] {
        let stored = UserDefaults.standard.dictionary(forKey: Self.regionNamesKey(recipe)) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    private static func regionNamesKey(_ recipe: MapRecipe) -> String {
        recipe == .pictures ? "regionNames" : "regionNames.\(recipe.rawValue)"
    }

    func rename(region id: Int, to name: String) {
        guard let map else { return }
        var names = regionNames(on: map.recipe)
        names[id] = name
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }),
                                  forKey: Self.regionNamesKey(map.recipe))
        adopt(map.withRegions(map.regions.renamed([id: name])))
    }

    private func adopt(_ next: LibraryMap) {
        map = next
        applyFilter()
    }

    /// Every item's vector, read the first time something needs one. About 100 MB.
    func embeddings() async -> EmbeddingStore? {
        guard let library, let map else { return nil }
        if let embeddingsTask { return await embeddingsTask.value }
        let task = Task.detached(priority: .userInitiated) { try? library.embeddings(map: map) }
        embeddingsTask = task
        return await task.value
    }

    // MARK: Find

    /// Whether find looks for what things are about, not the words in them.
    var findsByMeaning = false
    private var lastMeaningQuery: String?
    private var bandToReturnTo: Int?
    /// The model is about 600 MB, so it's set up separately (mac/tools/convert_clip.py).
    let canFindByMeaning = CLIPEncoder.isInstalled()

    /// Searches by meaning under way. The first has to load a model, which takes a moment.
    private(set) var findingByMeaning = 0

    func find(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard findsByMeaning, !text.isEmpty, let map, let store = await embeddings() else {
            filter.nearest = nil
            filter.query = text.lowercased()
            if case .found = selection { selection = nil }
            return
        }
        findingByMeaning += 1
        defer { findingByMeaning -= 1 }
        if encoderTask == nil {
            // Loads faster on the CPU, which is quick enough for one query at a time.
            encoderTask = Task.detached(priority: .userInitiated) { try? CLIPEncoder(computeUnits: .cpuOnly) }
        }
        guard let encoder = await encoderTask?.value else { return }
        let ranked = await Task.detached(priority: .userInitiated) { () -> [Int32]? in
            guard let vector = try? encoder.embed(text: text) else { return nil }
            // More than show, so filters can still leave a full set.
            return store.nearest(to: vector, items: map.items, count: MapFilter.nearestLimit * 20)
        }.value
        // Typing on has started a newer search.
        guard !Task.isCancelled, let ranked else { return }
        filter.query = ""
        filter.nearest = ranked
        lastMeaningQuery = text
        selection = .found(text)
    }

    /// The best of what's showing from a search by meaning, in order.
    func foundItems(count: Int) -> [Int32] {
        guard let map, let nearest = filter.nearest else { return [] }
        return Array(nearest.lazy.filter { self.filter.matches(map.items[Int($0)]) }.prefix(count))
    }

    /// Closing an item goes back to the search results it came from.
    func closePanel() {
        if case .item = selection, let bandToReturnTo {
            selection = .colorBand(bandToReturnTo)
        } else if case .item = selection, let query = lastMeaningQuery, filter.nearest != nil {
            selection = .found(query)
        } else {
            selection = nil
        }
        if case .colorBand = selection {} else { bandToReturnTo = nil }
    }

    func openColorBand(_ band: Int) {
        bandToReturnTo = nil
        selection = .colorBand(band)
    }

    func setWhere(_ path: [Int]) { whereYouAre = path }

    // MARK: Zoom, for whichever view can

    func zoomIn() { section == .palette ? palette.zoomIn() : controller.zoomIn() }
    func zoomOut() { section == .palette ? palette.zoomOut() : controller.zoomOut() }
    func fit() { section == .palette ? palette.fit() : controller.fit() }

    func openItem(_ index: Int32, pan: Bool = false) {
        // Closing it goes back to the band it was picked from.
        if case .colorBand(let band) = selection { bandToReturnTo = band }
        selection = .item(index)
        if pan, section == .terrain, let item = map?.items[Int(index)] { controller.fly(toItem: item) }
    }

    func openRegion(_ id: Int) {
        selection = .region(id)
        if section == .terrain, let region = map?.regions.regions[id] { controller.fly(to: region) }
    }

    // MARK: Time

    /// Slide a window (the current selection, or two years) through time at an even pace.
    func togglePlay() {
        if isPlaying {
            stopPlaying()
            return
        }
        guard let axis else { return }
        let twoYears = 2 * 365 * 86400
        var range = filter.range ?? axis.start...min(axis.start + twoYears, axis.end)
        let span = range.upperBound - range.lowerBound
        if range.upperBound >= axis.end { range = axis.start...(axis.start + span) }
        filter.range = range
        isPlaying = true
        lastPlayStep = CACurrentMediaTime()
        // Steps come as fast as the display, and each moves by the time that's passed.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepPlay() }
        }
        RunLoop.main.add(timer, forMode: .common)
        player = timer
    }

    private func stepPlay() {
        guard let axis, let range = filter.range else { return stopPlaying() }
        let now = CACurrentMediaTime()
        // Moving the range redraws whatever's showing, so wait for what it can keep up with.
        guard now - lastPlayStep >= updateStep else { return }
        let seconds = Int((now - lastPlayStep) * Self.playSpeed)
        lastPlayStep = now
        let next = (range.lowerBound + seconds)...(range.upperBound + seconds)
        if next.upperBound > axis.end { return stopPlaying() }
        filter.range = next
    }

    func stopPlaying() {
        player?.invalidate()
        player = nil
        isPlaying = false
    }

    /// One update at a time. Whatever changed meanwhile goes into the next, so a slow machine
    /// shows fewer steps rather than none: finished work is never thrown away for being late.
    private func applyFilter() {
        guard map != nil, search != nil else { return }
        guard !updating else {
            updateAgain = true
            return
        }
        let wait = updateStep - (CACurrentMediaTime() - lastUpdate)
        updating = true
        Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await update()
            updating = false
            lastUpdate = CACurrentMediaTime()
            if updateAgain {
                updateAgain = false
                applyFilter()
            }
        }
    }

    private func update() async {
        guard let map, let search else { return }
        let (filter, peak, generation) = (self.filter, fullPeak, mapGeneration)
        let current = slicer?.filter == filter.ignoringTime ? slicer : nil
        let (axis, order, wantsStrata) = (self.axis, current == nil ? nil : strataOrder, section == .strata)
        let wantsColors = section == .palette && paletteView == .time
        let share = paletteShowsShare
        let (scene, newSlicer, newOrder, counts) = await Task.detached(priority: .userInitiated) { () -> (TerrainScene, TimeSlicer, [Int]?, [Int]?) in
            let slicer = current ?? TimeSlicer(filter: filter, items: map.items, search: search)
            let counts = current == nil ? axis?.counts(of: slicer.times) : nil
            // A search by meaning keeps the best of what's in range, not a slice of its best.
            let visible = filter.nearest == nil ? slicer.visible(in: filter.range) : filter.visible(in: map.items, search: search)
            let order = order ?? axis.map { StrataModel.stackingOrder(map: map, visible: slicer.all, axis: $0) }
            let strata = wantsStrata ? axis.map { StrataModel(map: map, visible: visible, axis: $0, order: order) } : nil
            let colors = wantsColors ? axis.map { StrataModel(colorsOf: map, visible: visible, axis: $0, share: share) } : nil
            return (TerrainScene(map: map, visible: visible, fullPeak: peak, strata: strata, colorStrata: colors, range: filter.range), slicer, order, counts)
        }.value
        guard generation == mapGeneration else { return }
        self.scene = scene
        slicer = newSlicer
        strataOrder = newOrder
        if let counts { monthCounts = counts }
    }

    /// The order of Strata's layers for the current filter, whatever the time range.
    private(set) var strataOrder: [Int]?
}
