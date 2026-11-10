import Foundation
import GRDB

/// One item plus what you did with it, as an importer finds it. See `Record` in db.py.
public struct ImportRecord: Sendable {
    public var id: String
    public var platform: String
    public var kind = "link"
    public var url: String?
    public var author: String?
    public var text: String?
    public var createdAt: Int?
    public var createdEstimated = false
    public var hydrated = 0
    public var interactions: [ImportInteraction] = []
    public var media: [ImportMedia] = []
    /// Ids this same thing was stored under before the importer knew better, like an X repost
    /// under its own id rather than the post's. They're folded into this one (`absorb`).
    public var replaces: [String] = []

    public init(id: String, platform: String, kind: String = "link", url: String? = nil, author: String? = nil, text: String? = nil,
                createdAt: Int? = nil, createdEstimated: Bool = false, hydrated: Int = 0,
                interactions: [ImportInteraction] = [], media: [ImportMedia] = [], replaces: [String] = []) {
        self.id = id
        self.platform = platform
        self.kind = kind
        self.url = url
        self.author = author
        self.text = text
        self.createdAt = createdAt
        self.createdEstimated = createdEstimated
        self.hydrated = hydrated
        self.interactions = interactions
        self.media = media
        self.replaces = replaces
    }
}

public struct ImportInteraction: Sendable {
    public var type: String
    public var at: Int
    public var estimated: Bool
    public var collection: String?
    public var source: String?

    public init(type: String, at: Int?, estimated: Bool = false, collection: String? = nil, source: String? = nil) {
        self.type = type
        self.at = at ?? 0
        self.estimated = estimated
        self.collection = collection
        self.source = source
    }
}

public struct ImportMedia: Sendable {
    public var ord: Int
    public var kind = "image"
    public var url: String?
    public var name: String?
    /// The bytes are already the picture standing for a video.
    public var isPoster = false
    /// The picture's bytes, read only if it isn't in the library yet.
    public var data: (@Sendable () throws -> Data)?

    public init(ord: Int, kind: String = "image", url: String? = nil, name: String? = nil, isPoster: Bool = false, data: (@Sendable () throws -> Data)? = nil) {
        self.ord = ord
        self.kind = kind
        self.url = url
        self.name = name
        self.isPoster = isPoster
        self.data = data
    }
}

/// The one way the app writes to a library. `Library` stays read-only for everything else.
/// The file is shared with the Python tools while they last, so one waits its turn.
public final class LibraryWriter: @unchecked Sendable {
    public let root: URL
    public let mediaFolder: URL
    let db: DatabaseQueue

    /// An item that can't be reached and has nothing of its own: left off the map, kept so
    /// it isn't imported or fetched again.
    public static let goneSQL = "item.hydrated = -1 and coalesce(item.text, '') = '' and not exists (select 1 from media m where m.item_id = item.id and m.status = 'ok')"
    /// Items you only searched for. They're clouds over the map, not land.
    public static let searchOnlySQL = "select item_id from interaction group by item_id having sum(type != 'search') = 0"

    public init(root: URL = Library.defaultRoot) throws {
        self.root = root
        mediaFolder = root.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(120)
        config.prepareDatabase { db in try db.execute(sql: "pragma synchronous = normal") }
        db = try DatabaseQueue(path: root.appending(path: "topograph.sqlite").path, configuration: config)
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "pragma journal_mode = wal")
            try db.execute(sql: LibrarySchema.sql)
            let have = Set(try Row.fetchAll(db, sql: "pragma table_info(cluster)").map { $0["name"] as String })
            for (column, declaration) in [("parent", "integer"), ("depth", "integer not null default 0"), ("x", "real"), ("y", "real"), ("r", "real")]
            where !have.contains(column) {
                try db.execute(sql: "alter table cluster add column \(column) \(declaration)")
            }
        }
    }

    public func meta(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "select value from meta where key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.write { db in
            try db.execute(sql: "insert into meta(key, value) values(?, ?) on conflict(key) do update set value = excluded.value",
                           arguments: [key, value])
        }
    }

    /// Insert or merge a record, never replacing richer data with poorer. True when the item is new.
    /// Pictures are prepared first, so a slow one never holds the database.
    @discardableResult
    public func upsert(_ record: ImportRecord, video: VideoPosters = .standard) throws -> Bool {
        let finished = try db.read { db in
            Set(try Int.fetchAll(db, sql: "select ord from media where item_id = ? and status = 'ok'", arguments: [record.id]))
        }
        var prepared: [Int: PreparedMedia] = [:]
        for media in record.media where !finished.contains(media.ord) {
            guard let data = media.data else { continue }
            prepared[media.ord] = MediaIngest.prepare(try data(), kind: media.kind, name: media.name, isPoster: media.isPoster, library: self, video: video)
        }
        return try db.write { db in
            let existing = try Row.fetchOne(db, sql: "select kind, created_at, created_estimated from item where id = ?", arguments: [record.id])
            if let existing {
                // A like says "text" for a post whose pictures were fetched since: still pictures.
                let had = existing["kind"] as String
                let kind = Self.kindRank(record.kind) >= Self.kindRank(had) ? record.kind : had
                var created = existing["created_at"] as Int?
                var estimated = existing["created_estimated"] as Int
                if let new = record.createdAt, new != 0, created == nil || (estimated != 0 && !record.createdEstimated) {
                    created = new
                    estimated = record.createdEstimated ? 1 : 0
                }
                try db.execute(sql: """
                    update item set kind = ?, url = coalesce(url, ?), author = coalesce(author, ?), text = coalesce(text, ?),
                    created_at = ?, created_estimated = ?, hydrated = max(hydrated, ?) where id = ?
                    """, arguments: [kind, record.url, record.author, record.text, created, estimated, record.hydrated, record.id])
            } else {
                try db.execute(sql: """
                    insert into item(id, platform, kind, url, author, text, created_at, created_estimated, hydrated)
                    values (?,?,?,?,?,?,?,?,?)
                    """, arguments: [record.id, record.platform, record.kind, record.url, record.author, record.text,
                                     record.createdAt, record.createdEstimated ? 1 : 0, record.hydrated])
            }
            for interaction in record.interactions {
                try db.execute(sql: """
                    insert or ignore into interaction(item_id, type, at, at_estimated, collection, source_file) values (?,?,?,?,?,?)
                    """, arguments: [record.id, interaction.type, interaction.at, interaction.estimated ? 1 : 0, interaction.collection, interaction.source])
            }
            for media in record.media where !finished.contains(media.ord) {
                try db.execute(sql: "insert or replace into media(item_id, ord, kind, original_url, status) values (?,?,?,?, 'pending')",
                               arguments: [record.id, media.ord, media.kind, media.url])
                if let ready = prepared[media.ord] { try Self.record(ready, itemID: record.id, ord: media.ord, db) }
            }
            for old in record.replaces { try Self.absorb(old, into: record.id, db) }
            return existing == nil
        }
    }

    /// How much an item's kind says it has. Merging never moves down.
    static func kindRank(_ kind: String) -> Int {
        switch kind {
        case "image", "video": 2
        case "text": 1
        default: 0
        }
    }

    /// Folds the item stored as `old` into `new`, the same thing under its right id. What you
    /// did with it moves over. So do its pictures, vectors and place on the map when `new` has
    /// none, so a repost that was fetched isn't fetched again and the item keeps its place until
    /// the map is next built. Then `old` goes. Same as `absorb` in db.py.
    @discardableResult
    static func absorb(_ old: String, into new: String, _ db: Database) throws -> Bool {
        guard old != new, let was = try Row.fetchOne(db, sql: "select kind, author, text, hydrated from item where id = ?", arguments: [old]) else {
            return false
        }
        let kind: String = was["kind"]
        try db.execute(sql: """
            update item set kind = case when kind in ('link', 'text') and ? in ('image', 'video') then ? else kind end,
            author = coalesce(author, ?), text = coalesce(text, ?), hydrated = max(hydrated, ?) where id = ?
            """, arguments: [kind, kind, was["author"] as String?, was["text"] as String?, was["hydrated"] as Int, new])
        try db.execute(sql: """
            insert or ignore into interaction(item_id, type, at, at_estimated, collection, source_file)
            select ?, type, at, at_estimated, collection, source_file from interaction where item_id = ?
            """, arguments: [new, old])
        let pictures = "select 1 from media where item_id = ? and status = 'ok'"
        if try Bool.fetchOne(db, sql: pictures, arguments: [new]) == nil, try Bool.fetchOne(db, sql: pictures, arguments: [old]) != nil {
            try db.execute(sql: "delete from media where item_id = ?", arguments: [new])
            try db.execute(sql: "update media set item_id = ? where item_id = ?", arguments: [new, old])
        }
        // Per model: a row `new` already has for a model stays, and `old`'s is dropped.
        for table in ["embedding", "layout", "cloud"] {
            try db.execute(sql: "update or ignore \(table) set item_id = ? where item_id = ?", arguments: [new, old])
        }
        for table in ["interaction", "media", "embedding", "layout", "cloud"] {
            try db.execute(sql: "delete from \(table) where item_id = ?", arguments: [old])
        }
        try db.execute(sql: "delete from item where id = ?", arguments: [old])
        return true
    }

    /// Bytes fetched for a media row that's already there.
    public func store(_ prepared: PreparedMedia, itemID: String, ord: Int) throws {
        try db.write { try Self.record(prepared, itemID: itemID, ord: ord, $0) }
    }

    static func record(_ prepared: PreparedMedia, itemID: String, ord: Int, _ db: Database) throws {
        switch prepared {
        case .failed:
            try db.execute(sql: "update media set status = 'failed' where item_id = ? and ord = ?", arguments: [itemID, ord])
        case .ready(let media):
            try db.execute(sql: """
                update media set content_hash = ?, local_path = ?, thumb_path = ?, width = ?, height = ?, phash = ?, palette = ?,
                status = 'ok', kind = ? where item_id = ? and ord = ?
                """, arguments: [media.contentHash, media.displayPath, media.thumbPath, media.width, media.height,
                                 media.phash, media.palette, media.kind, itemID, ord])
        }
    }
}

extension LibraryWriter {
    /// Files with a preview already, so an interrupted import picks up where it stopped.
    public func finishedFiles() throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(db, sql: "select i.id from item i join media m on m.item_id = i.id where i.platform = 'files' and m.status = 'ok'"))
        }
    }
}
