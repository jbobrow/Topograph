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
    private(set) var axis: MonthAxis?
    /// Items per month, whatever's filtered, for the time scrubber's bars.
    private(set) var monthCounts: [Int] = []
    private(set) var platforms: [String] = []
    private(set) var isPlaying = false
    var section = Section.terrain
    var selection: Selection?
    var hover: Hover?
    var imageMode: ImageMode {
        didSet { UserDefaults.standard.set(imageMode.rawValue, forKey: "imageMode") }
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
        sources = await Task.detached(priority: .utility) { try? Library(root: root).sources() }.value
    }

    private var search: SearchIndex?
    private var fullPeak = 0.0
    private var filtering = 0
    private var player: Timer?
    private var embeddingsTask: Task<EmbeddingStore?, Never>?

    init() {
        imageMode = UserDefaults.standard.string(forKey: "imageMode").flatMap(ImageMode.init) ?? .gray
    }

    func load() {
        Task {
            do {
                let filter = self.filter
                let (library, loaded, search, peak, scene) = try await Task.detached(priority: .userInitiated) {
                    let library = try Library()
                    let map = try library.map()
                    let search = SearchIndex(items: map.items)
                    // Contour heights come from what shows by default, not what starts hidden.
                    let shown = map.items.indices.filter { map.items[$0].platform != "google" }.map(Int32.init)
                    let peak = DensityField(items: map.items, visible: shown).peak
                    let scene = TerrainScene(map: map, visible: filter.visible(in: map.items, search: search), fullPeak: peak)
                    return (library, map, search, peak, scene)
                }.value
                self.library = library
                let map = loaded.withRegions(loaded.regions.renamed(regionNames))
                self.map = map
                embeddingsTask = nil
                let times = map.items.compactMap(\.time)
                axis = MonthAxis(times: times + map.waitingTimes)
                monthCounts = axis?.counts(of: times) ?? []
                // Largest first, like the viewer's chips in the order they turn up.
                let tally = map.items.reduce(into: [String: Int]()) { $0[$1.platform, default: 0] += 1 }
                platforms = tally.keys.sorted { tally[$0]! > tally[$1]! }
                self.search = search
                fullPeak = peak
                self.scene = TerrainScene(map: map, visible: scene.visible, fullPeak: peak)
                selection = nil
                phase = .ready
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
    /// by region number, so a new layout, which renumbers regions, clears them.
    private var regionNames: [Int: String] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: "regionNames") as? [String: String] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
        }
        set {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) }), forKey: "regionNames")
        }
    }

    func rename(region id: Int, to name: String) {
        regionNames[id] = name
        guard let map else { return }
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

    func setWhere(_ path: [Int]) { whereYouAre = path }

    func openItem(_ index: Int32, pan: Bool = false) {
        selection = .item(index)
        if pan, section == .terrain, let item = map?.items[Int(index)] { controller.fly(toItem: item) }
    }

    func openRegion(_ id: Int) {
        selection = .region(id)
        if section == .terrain, let region = map?.regions.regions[id] { controller.fly(to: region) }
    }

    // MARK: Time

    /// Slide a window (the current selection, or two years) through time, a month at a step.
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
        let timer = Timer(timeInterval: 0.14, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepPlay() }
        }
        RunLoop.main.add(timer, forMode: .common)
        player = timer
    }

    private func stepPlay() {
        guard let axis, let range = filter.range else { return stopPlaying() }
        let month = 30 * 86400
        let next = (range.lowerBound + month)...(range.upperBound + month)
        if next.upperBound > axis.end { return stopPlaying() }
        filter.range = next
    }

    func stopPlaying() {
        player?.invalidate()
        player = nil
        isPlaying = false
    }

    /// The latest filter wins; one that's been overtaken is dropped.
    private func applyFilter() {
        guard let map, let search else { return }
        filtering += 1
        let ticket = filtering
        let (filter, peak) = (self.filter, fullPeak)
        Task {
            let scene = await Task.detached(priority: .userInitiated) {
                TerrainScene(map: map, visible: filter.visible(in: map.items, search: search), fullPeak: peak)
            }.value
            if ticket == filtering { self.scene = scene }
        }
    }
}
