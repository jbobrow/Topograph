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

    public init(id: String = "", x: Float, y: Float, resonance: Float, mine: Bool = false, groups: ActionGroups = [],
                platform: String = "x", kind: String = "text", author: String? = nil, text: String? = nil,
                region: Int? = nil, time: Int? = nil, thumb: String? = nil, aspect: Float? = nil) {
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

    public init(items: [MapItem], regions: RegionTree, waitingTimes: [Int] = [], waiting: Int = 0) {
        self.items = items
        self.regions = regions
        self.waitingTimes = waitingTimes
        self.waiting = waiting
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
        case .notFound(let path): "No library at \(path). Run `topograph build` first."
        case .noMap: "This library has no map yet. Run `topograph build` first."
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
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        self.root = root
        self.db = try DatabaseQueue(path: file.path, configuration: config)
    }

    /// A path stored in the library, as a file on disk.
    public func file(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    public func map() throws -> LibraryMap {
        try db.read { db in
            guard let model = try String.fetchOne(db, sql: "select value from meta where key = 'embedding_model'") else {
                throw LibraryError.noMap
            }

            // What you did with each item.
            var engaged: [String: Engagement] = [:]
            let interactions = try Row.fetchCursor(db, sql: "select item_id, type, at, at_estimated from interaction")
            while let row = try interactions.next() {
                engaged[row[0] as String, default: Engagement()].add(type: row[1], at: row[2], estimated: row[3])
            }

            // The first picture of each item.
            var pictures: [String: (thumb: String?, aspect: Float?)] = [:]
            let media = try Row.fetchCursor(db, sql: """
                select item_id, thumb_path, width, height from media where status = 'ok' order by item_id, ord
                """)
            while let row = try media.next() {
                let id: String = row[0]
                guard pictures[id] == nil else { continue }
                let width: Double? = row[2], height: Double? = row[3]
                var aspect: Float?
                if let width, let height, width > 0, height > 0 { aspect = Float(width / height) }
                pictures[id] = (row[1], aspect)
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
                    thumb: picture?.thumb, aspect: picture?.aspect))
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
                              waitingTimes: waitingTimes, waiting: waiting)
        }
    }

    public func detail(of id: String) throws -> ItemDetail {
        try db.read { db in
            let item = try Row.fetchOne(db, sql: "select url, created_at from item where id = ?", arguments: [id])
            let interactions = try Row.fetchAll(db, sql: """
                select type, at, at_estimated, collection from interaction where item_id = ? order by at
                """, arguments: [id]).map {
                Interaction(type: $0[0], at: $0[1], estimated: ($0[2] as Int) != 0, collection: $0[3])
            }
            let media = try Row.fetchAll(db, sql: """
                select kind, local_path, thumb_path, original_url from media
                where item_id = ? and status = 'ok' order by ord
                """, arguments: [id]).map {
                MediaFile(kind: $0[0], display: $0[1], thumb: $0[2], originalURL: $0[3])
            }
            let model = try String.fetchOne(db, sql: "select value from meta where key = 'embedding_model'")
            let neighbors = try String.fetchOne(db, sql: "select neighbors from layout where item_id = ? and model = ?",
                                                arguments: [id, model])
            return ItemDetail(url: item?[0], createdAt: item?[1], interactions: interactions, media: media,
                              neighbors: neighbors.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
        }
    }

    // `GONE_SQL` in db.py: unreachable, with no text and no picture. Gone items stay
    // in the file but are left off the map and out of counts.
    private static let goneSQL = """
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
