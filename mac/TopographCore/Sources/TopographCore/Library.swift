import Foundation
import GRDB

/// One placed item, as much of it as the terrain needs.
public struct MapItem: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var resonance: Float
    /// Made or posted, rather than kept. Drawn as a square rather than a circle.
    public var mine: Bool

    public init(x: Float, y: Float, resonance: Float, mine: Bool) {
        self.x = x
        self.y = y
        self.resonance = resonance
        self.mine = mine
    }
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
/// short and never hold a transaction open.
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

    /// Everything on the map, from one consistent snapshot of the file.
    public func mapItems() throws -> [MapItem] {
        try db.read { db in
            guard let model = try String.fetchOne(db, sql: "select value from meta where key = 'embedding_model'") else {
                throw LibraryError.noMap
            }
            let rows = try Row.fetchCursor(db, sql: Self.mapSQL, arguments: [model])
            var items: [MapItem] = []
            while let row = try rows.next() {
                let types = (row[2] as String?)?.split(separator: ",").map(String.init) ?? []
                items.append(MapItem(x: Float(row[0] as Double),
                                     y: Float(row[1] as Double),
                                     resonance: Interactions.resonance(types),
                                     mine: types.contains(where: Interactions.mine.contains)))
            }
            guard !items.isEmpty else { throw LibraryError.noMap }
            return items
        }
    }

    // `GONE_SQL` in db.py: unreachable, with no text and no picture. Gone items stay
    // in the file but are left off the map.
    private static let mapSQL = """
        select layout.x, layout.y, group_concat(distinct interaction.type)
        from layout
        join item on item.id = layout.item_id
        left join interaction on interaction.item_id = layout.item_id
        where layout.model = ?
          and not (item.hydrated = -1 and coalesce(item.text, '') = '' and not exists
                   (select 1 from media m where m.item_id = item.id and m.status = 'ok'))
        group by layout.item_id
        """
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
}
