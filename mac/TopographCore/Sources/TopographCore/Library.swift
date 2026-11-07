import Foundation
import GRDB

/// Everything the map needs to know about one placed item.
public struct MapItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var x: Float
    public var y: Float
    public var resonance: Float
    /// Made or posted, rather than kept. Drawn as a square rather than a circle.
    public var mine: Bool
    public var groups: ActionGroups
    public var platform: String
    public var kind: String
    public var author: String?
    public var text: String?
    /// The finest region it belongs to.
    public var region: Int?
    /// When you engaged with it, or failing that when it was published. Unix seconds.
    public var time: Int?
    /// The thumbnail of its first picture, relative to the library root.
    public var thumb: String?
    /// Width over height of that picture.
    public var aspect: Float?
    /// Its strongest color, as 0xRRGGBB.
    public var color: UInt32?
    /// Its perceptual hash, for finding near-duplicates.
    public var phash: UInt64?

    public init(id: String = "", x: Float, y: Float, resonance: Float, mine: Bool = false, groups: ActionGroups = [],
                platform: String = "x", kind: String = "text", author: String? = nil, text: String? = nil,
                region: Int? = nil, time: Int? = nil, thumb: String? = nil, aspect: Float? = nil,
                color: UInt32? = nil, phash: UInt64? = nil) {
        self.id = id
        self.x = x
        self.y = y
        self.resonance = resonance
        self.mine = mine
        self.groups = groups
        self.platform = platform
        self.kind = kind
        self.author = author
        self.text = text
        self.region = region
        self.time = time
        self.thumb = thumb
        self.aspect = aspect
        self.color = color
        self.phash = phash
    }
}

/// The whole map, read from one consistent snapshot of the file.
public struct LibraryMap: Sendable {
    public let items: [MapItem]
    public let regions: RegionTree
    /// When you engaged with items that aren't placed yet (links waiting for their
    /// images). They count in Strata. Gone items don't.
    public let waitingTimes: [Int]
    public let waiting: Int
    /// Which arrangement of the library this is.
    public let recipe: MapRecipe
    /// Where each item id sits in `items`.
    public let indexOfID: [String: Int32]

    public func withRegions(_ regions: RegionTree) -> LibraryMap {
        LibraryMap(items: items, regions: regions, waitingTimes: waitingTimes, waiting: waiting, recipe: recipe)
    }

    public init(items: [MapItem], regions: RegionTree, waitingTimes: [Int] = [], waiting: Int = 0, recipe: MapRecipe = .pictures) {
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(items.count)
        for index in items.indices { ids[items[index].id] = Int32(index) }
        indexOfID = ids
        self.items = items
        self.regions = regions
        self.waitingTimes = waitingTimes
        self.waiting = waiting
        self.recipe = recipe
    }
}

public struct Interaction: Sendable, Equatable {
    public let type: String
    public let at: Int
    public let estimated: Bool
    public let collection: String?
}

public struct MediaFile: Sendable, Equatable {
    public let kind: String
    public let display: String?
    public let thumb: String?
    public let originalURL: String?
    /// Dominant colors, strongest first, each as a hex string and a share.
    public let palette: [PaletteColor]
}

public struct PaletteColor: Sendable, Equatable {
    public let hex: String
    public let share: Double

    /// `[["#262825", 0.291], ...]` as media.py stores it.
    static func parse(_ json: String?) -> [PaletteColor] {
        guard let json, let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count == 2, let hex = row[0] as? String, let share = row[1] as? Double else { return nil }
            return PaletteColor(hex: hex, share: share)
        }
    }

    public var rgb: UInt32? { UInt32(hex.drop(while: { $0 == "#" }), radix: 16) }
}

/// What the detail panel shows beyond what the map already holds.
public struct ItemDetail: Sendable, Equatable {
    public let url: String?
    public let createdAt: Int?
    public let interactions: [Interaction]
    public let media: [MediaFile]
    /// Ids, nearest first.
    public let neighbors: [String]
}

public enum LibraryError: LocalizedError, Equatable {
    case notFound(path: String)
    case noMap

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "No library at \(path) yet. Add your history in Sources."
        case .noMap: "This library has no map yet. Add your history in Sources, then update the map."
        }
    }
}

/// The library the Python prototype built, opened read-only.
///
/// `pipeline/topograph/db.py` is the reference for the schema. The file is in WAL
/// mode and the Python tools may be writing to it at the same time, so reads stay
/// short and no transaction stays open between them.
public struct Library: Sendable {
    public let root: URL
    let db: DatabaseQueue
    /// Holds the file's WAL side files in place when nothing else is. Never used to read or write.
    private let sideFiles: DatabaseQueue?

    /// Same rule as `config.default_library()`.
    public static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["TOPOGRAPH_LIBRARY"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "Topograph", directoryHint: .isDirectory)
    }

    public init(root: URL = Library.defaultRoot) throws {
        let file = root.appending(path: "topograph.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw LibraryError.notFound(path: root.path)
        }
        self.root = root
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        if let queue = try Self.openIfSideFilesExist(file, config) {
            sideFiles = nil
            db = queue
        } else {
            // A read-only connection can't open a WAL file once the last writer has closed
            // and its -wal and -shm files are gone. An ordinary connection, which is never
            // asked to write, brings them back and is kept open so they stay. All reading
            // still goes through the read-only connection, so SQLite itself refuses writes.
            var ordinary = Configuration()
            ordinary.busyMode = .timeout(5)
            sideFiles = try DatabaseQueue(path: file.path, configuration: ordinary)
            db = try DatabaseQueue(path: file.path, configuration: config)
        }
    }

    /// nil when SQLite can't open it read-only because the WAL side files are missing.
    private static func openIfSideFilesExist(_ file: URL, _ config: Configuration) throws -> DatabaseQueue? {
        do {
            return try DatabaseQueue(path: file.path, configuration: config)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            return nil
        }
    }

    /// A path stored in the library, as a file on disk.
    public func file(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    /// The map you asked for if it's been built, or else the one built last.
    public func map(_ asked: MapRecipe? = nil) throws -> LibraryMap {
        try db.read { db in
            guard let (recipe, model) = try Self.resolve(asked, db) else {
                throw LibraryError.noMap
            }

            // What you did with each item.
            var engaged: [String: Engagement] = [:]
            let interactions = try Row.fetchCursor(db, sql: "select item_id, type, at, at_estimated from interaction")
            while let row = try interactions.next() {
                engaged[row[0] as String, default: Engagement()].add(type: row[1], at: row[2], estimated: row[3])
            }

            // The first picture of each item.
            var pictures: [String: (thumb: String?, aspect: Float?, color: UInt32?, phash: UInt64?)] = [:]
            let media = try Row.fetchCursor(db, sql: """
                select item_id, thumb_path, width, height, palette, phash from media where status = 'ok' order by item_id, ord
                """)
            while let row = try media.next() {
                let id: String = row[0]
                guard pictures[id] == nil else { continue }
                let width: Double? = row[2], height: Double? = row[3]
                var aspect: Float?
                if let width, let height, width > 0, height > 0 { aspect = Float(width / height) }
                // The strongest color comes first; no need to parse the whole list here.
                var color: UInt32?
                if let palette = row[4] as String?, let hash = palette.firstIndex(of: "#"),
                   let end = palette.index(hash, offsetBy: 7, limitedBy: palette.endIndex) {
                    color = UInt32(palette[palette.index(after: hash)..<end], radix: 16)
                }
                pictures[id] = (row[1], aspect, color, (row[5] as String?).flatMap { UInt64($0, radix: 16) })
            }

            var items: [MapItem] = []
            let placed = try Row.fetchCursor(db, sql: Self.placedSQL, arguments: [model])
            while let row = try placed.next() {
                let id: String = row[0]
                let engagement = engaged[id] ?? Engagement()
                let picture = pictures[id]
                let text: String? = row[6]
                items.append(MapItem(
                    id: id, x: Float(row[1] as Double), y: Float(row[2] as Double),
                    resonance: Interactions.resonance(engagement.types),
                    mine: engagement.types.contains(where: Interactions.mine.contains),
                    groups: ActionGroups(types: engagement.types),
                    platform: row[4], kind: row[5], author: row[7],
                    text: text?.isEmpty == false ? text : nil,
                    region: row[3],
                    time: engagement.time ?? row[8],
                    thumb: picture?.thumb, aspect: picture?.aspect,
                    color: picture?.color, phash: picture?.phash))
            }
            guard !items.isEmpty else { throw LibraryError.noMap }

            var waitingTimes: [Int] = []
            var waiting = 0
            let unplaced = try Row.fetchCursor(db, sql: Self.waitingSQL, arguments: [model])
            while let row = try unplaced.next() {
                waiting += 1
                if let time = engaged[row[0] as String]?.time ?? (row[1] as Int?) { waitingTimes.append(time) }
            }

            let rows = try Row.fetchAll(db, sql: "select id, label, terms, parent, depth, x, y, r from cluster where model = ?",
                                        arguments: [model])
            let regions = rows.map { row -> RegionTree.Record in
                let terms: String? = row[2]
                let words = terms.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
                return RegionTree.Record(id: row[0], label: row[1] ?? "", terms: words, parent: row[3],
                                         x: row[5], y: row[6], r: row[7])
            }
            return LibraryMap(items: items, regions: RegionTree(records: regions, items: items),
                              waitingTimes: waitingTimes, waiting: waiting, recipe: recipe)
        }
    }

    /// Which map to read, and the name it's stored under. nil when nothing has been embedded.
    private static func resolve(_ asked: MapRecipe?, _ db: Database) throws -> (MapRecipe, String)? {
        guard let base = try String.fetchOne(db, sql: "select value from meta where key = 'embedding_model'") else {
            return nil
        }
        let last = try String.fetchOne(db, sql: "select value from meta where key = 'map'").flatMap(MapRecipe.init)
        for recipe in [asked, last, .pictures].compactMap({ $0 }) + MapRecipe.allCases {
            let model = recipe.layoutModel(base: base)
            if try Bool.fetchOne(db, sql: "select exists(select 1 from layout where model = ?)", arguments: [model]) == true {
                return (recipe, model)
            }
        }
        return (asked ?? last ?? .pictures, (asked ?? last ?? .pictures).layoutModel(base: base))
    }

    public func detail(of id: String, in recipe: MapRecipe? = nil) throws -> ItemDetail {
        try db.read { db in
            let item = try Row.fetchOne(db, sql: "select url, created_at from item where id = ?", arguments: [id])
            let interactions = try Row.fetchAll(db, sql: """
                select type, at, at_estimated, collection from interaction where item_id = ? order by at
                """, arguments: [id]).map {
                Interaction(type: $0[0], at: $0[1], estimated: ($0[2] as Int) != 0, collection: $0[3])
            }
            let media = try Row.fetchAll(db, sql: """
                select kind, local_path, thumb_path, original_url, palette from media
                where item_id = ? and status = 'ok' order by ord
                """, arguments: [id]).map {
                MediaFile(kind: $0[0], display: $0[1], thumb: $0[2], originalURL: $0[3], palette: PaletteColor.parse($0[4]))
            }
            let model = try Self.resolve(recipe, db)?.1
            let neighbors = try String.fetchOne(db, sql: "select neighbors from layout where item_id = ? and model = ?",
                                                arguments: [id, model])
            return ItemDetail(url: item?[0], createdAt: item?[1], interactions: interactions, media: media,
                              neighbors: neighbors.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
        }
    }

    // `GONE_SQL` in db.py: unreachable, with no text and no picture. Gone items stay
    // in the file but are left off the map and out of counts.
    fileprivate static let goneSQL = """
        item.hydrated = -1 and coalesce(item.text, '') = '' and not exists
        (select 1 from media m where m.item_id = item.id and m.status = 'ok')
        """
    private static let placedSQL = """
        select item.id, layout.x, layout.y, layout.cluster, item.platform, item.kind, item.text, item.author,
               item.created_at
        from layout join item on item.id = layout.item_id
        where layout.model = ? and not (\(goneSQL))
        """
    private static let waitingSQL = """
        select item.id, item.created_at from item
        where not (\(goneSQL))
          and not exists (select 1 from layout where layout.item_id = item.id and layout.model = ?)
        """
}

/// `taste_time` in export.py: the first time you really engaged with an item. X likes
/// carry no time of their own, so an estimated time only counts when there's no other.
private struct Engagement {
    var types: Set<String> = []
    private var real: Int?
    private var estimated: Int?

    mutating func add(type: String, at: Int, estimated isEstimated: Int) {
        types.insert(type)
        guard at != 0 else { return }
        if isEstimated == 0 { real = min(real ?? at, at) }
        estimated = min(estimated ?? at, at)
    }

    var time: Int? { real ?? estimated }
}

/// `INTERACTION_WEIGHTS` in config.py and `MINE` in viewer/app.js.
public enum Interactions {
    public static let weights: [String: Float] = [
        "bookmark": 3.0, "save": 3.0, "post": 2.5, "repost": 2.0, "reply": 1.5, "comment": 1.5,
        "made": 2.5, "capture": 1.5, "like": 1.0, "download": 1.0, "open": 0.5, "react": 0.5,
        "view": 0.3, "search": 0.2,
    ]
    public static let mine: Set<String> = ["post", "repost", "reply", "comment", "made", "capture"]

    /// The sum of the weights of an item's distinct interaction types. A type with
    /// no weight counts 1, as it does in export.py.
    public static func resonance(_ types: some Sequence<String>) -> Float {
        Set(types).reduce(0) { $0 + (weights[$1] ?? 1) }
    }

    /// `VERBS` in viewer/app.js.
    public static func verb(_ type: String) -> String {
        switch type {
        case "post": "Posted"
        case "repost": "Reposted"
        case "reply": "Replied"
        case "comment": "Commented"
        case "like": "Liked"
        case "save": "Saved"
        case "bookmark": "Bookmarked"
        case "view": "Watched"
        case "search": "Searched"
        case "made": "Made"
        case "capture": "Took this screenshot"
        case "download": "Downloaded"
        case "open": "Opened"
        case "react": "Reacted"
        default: type
        }
    }
}

/// What each source has brought in so far, for the Sources page.
public struct LibrarySources: Sendable, Equatable {
    public struct Platform: Sendable, Equatable {
        public let platform: String
        public let items: Int
        /// Arrived as links with something still to fetch.
        public let waiting: Int
        /// Have been fetched, or came complete.
        public let fetched: Int
        /// The newest thing you did there.
        public let newest: Int?
        /// Given up on: tried a few times, or marked gone. A signed-in look might still find them.
        public var unreachable = 0
    }

    public let platforms: [Platform]
    public let fileRoots: [String]
    /// Accounts set up for live sync, by source.
    public let syncAccounts: [String: String]
    /// Not placed on the map being shown yet: they need the map updated.
    public let unplaced: Int
    /// How many items each built map has.
    public let maps: [MapRecipe: Int]
    /// The map `unplaced` is about.
    public let shownMap: MapRecipe?

    /// Items missing from a map. Exact for the map being shown. For others it's the difference
    /// in counts, which is enough to say a map has fallen behind.
    public func waiting(on recipe: MapRecipe) -> Int {
        if recipe == shownMap { return unplaced }
        return max(0, platforms.reduce(0) { $0 + $1.items } - (maps[recipe] ?? 0))
    }
}

extension Library {
    /// `showing` is the map you've asked for, which decides what counts as not on it yet.
    public func sources(showing: MapRecipe? = nil) throws -> LibrarySources {
        try db.read { db in
            let newest = try Row.fetchAll(db, sql: """
                select item.platform, max(interaction.at) from interaction join item on item.id = interaction.item_id
                group by item.platform
                """).reduce(into: [String: Int]()) { $0[$1[0] as String] = $1[1] as Int? }
            let unreachable = try Row.fetchAll(db, sql: "select platform, count(*) from item where hydrated = -1 group by platform")
                .reduce(into: [String: Int]()) { $0[$1[0] as String] = $1[1] as Int }
            let platforms = try Row.fetchAll(db, sql: """
                select platform, count(*), sum(hydrated = 0 and hydrate_attempts < 3), sum(hydrated = 1) from item
                where not (\(Self.goneSQL)) group by platform
                """).map {
                LibrarySources.Platform(platform: $0[0], items: $0[1], waiting: $0[2] ?? 0, fetched: $0[3] ?? 0, newest: newest[$0[0] as String],
                                        unreachable: unreachable[$0[0] as String] ?? 0)
            }
            let meta = try Row.fetchAll(db, sql: "select key, value from meta").reduce(into: [String: String]()) { $0[$1[0] as String] = $1[1] as String? }
            let roots = meta["files_roots"].flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            var accounts: [String: String] = [:]
            for (key, value) in meta where key.hasPrefix("sync_") { accounts[String(key.dropFirst(5))] = value }
            let shown = try Self.resolve(showing, db)
            let unplaced = try Int.fetchOne(db, sql: """
                select count(*) from item where not (\(Self.goneSQL))
                and not exists (select 1 from layout where layout.item_id = item.id and layout.model = ?)
                """, arguments: [shown?.1 ?? ""]) ?? 0
            let counts = try Row.fetchAll(db, sql: "select model, count(*) from layout group by model")
                .reduce(into: [String: Int]()) { $0[$1[0] as String] = $1[1] as Int }
            var maps: [MapRecipe: Int] = [:]
            if let base = meta["embedding_model"] {
                for recipe in MapRecipe.allCases {
                    if let count = counts[recipe.layoutModel(base: base)] { maps[recipe] = count }
                }
            }
            return LibrarySources(platforms: platforms, fileRoots: roots, syncAccounts: accounts, unplaced: unplaced,
                                  maps: maps, shownMap: shown?.0)
        }
    }
}

/// How something dropped on the Sources page gets read.
public enum DroppedSource: Equatable, Sendable {
    /// A platform's export: `topograph import`.
    case export
    /// A folder of your own files: `topograph files`, which skips what's sensitive.
    case folder
    case unknown

    public static func classify(_ url: URL) -> DroppedSource {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .unknown }
        guard isDirectory.boolValue else { return url.pathExtension.lowercased() == "zip" ? .export : .unknown }
        let markers = ["data/tweets.js", "data/like.js", "data/account.js", "your_instagram_activity", "personal_information",
                       "your_facebook_activity", "Takeout", "YouTube and YouTube Music", "My Activity"]
        let looksLikeExport = markers.contains { FileManager.default.fileExists(atPath: url.appending(path: $0).path) }
        return looksLikeExport ? .export : .folder
    }
}
