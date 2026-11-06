import SwiftUI
import TopographCore

enum Section: String, CaseIterable, Sendable {
    case terrain, strata
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
    var section = Section.terrain
    var selection: Selection?
    var hover: Hover?
    var imageMode: ImageMode {
        didSet { UserDefaults.standard.set(imageMode.rawValue, forKey: "imageMode") }
    }
    var filter = MapFilter() {
        didSet { if filter != oldValue { applyFilter() } }
    }
    let controller = TerrainController()

    private var search: SearchIndex?
    private var fullPeak = 0.0
    private var filtering = 0

    init() {
        imageMode = UserDefaults.standard.string(forKey: "imageMode").flatMap(ImageMode.init) ?? .gray
    }

    func load() {
        Task {
            do {
                let filter = self.filter
                let (library, map, search, peak, scene) = try await Task.detached(priority: .userInitiated) {
                    let library = try Library()
                    let map = try library.map()
                    let search = SearchIndex(items: map.items)
                    let peak = DensityField(items: map.items).peak
                    let scene = TerrainScene(map: map, visible: filter.visible(in: map.items, search: search), fullPeak: peak)
                    return (library, map, search, peak, scene)
                }.value
                self.library = library
                self.map = map
                self.search = search
                fullPeak = peak
                self.scene = scene
                selection = nil
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func fail(_ message: String) { phase = .failed(message) }

    func setWhere(_ path: [Int]) { whereYouAre = path }

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
