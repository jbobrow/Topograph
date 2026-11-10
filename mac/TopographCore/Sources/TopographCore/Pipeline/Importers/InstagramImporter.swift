import Foundation

/// Instagram's "Download your information" (JSON). The export's shape has changed several
/// times, so this doesn't trust one schema: it walks every record for a post link and a time.
/// Direct messages are never read; `Archive` doesn't even list them.
public enum InstagramImporter: ArchiveImporter {
    public static let name = "instagram"
    public static let title = "Instagram"

    public static func detect(_ archive: Archive) -> Bool {
        !archive.find(#"(your_instagram_activity/|liked_posts\.json$|saved_posts\.json$|(^|/)content/posts_\d+\.json$)"#).isEmpty
    }

    static func load(_ archive: Archive, _ name: String) -> JSONValue? {
        (try? archive.readJSON(name))?.withRepairedText
    }

    /// The top-level records, whether the file is a list or `{key: [list]}`.
    static func mainList(_ value: JSONValue) -> [JSONValue] {
        if let list = value.array { return list }
        let lists = value.pairs.compactMap(\.value.array)
        return lists.count == 1 ? lists[0] : lists.flatMap { $0 }
    }

    struct Flattened {
        var urls: [String] = []
        var stamps: [Int] = []
        var author: String?
        var name: String?
        var text: String?
    }

    /// Links, times, author and a name out of one record, any shape.
    static func flatten(_ record: JSONValue) -> Flattened {
        var out = Flattened()
        var author: String?, name: String?, text: String?
        record.walk { object in
            for (key, value) in object.pairs {
                if let string = value.string, string.hasPrefix("http") {
                    out.urls.append(string)
                } else if key.lowercased().contains("timestamp"), let stamp = PipelineText.plausibleTime(value) {
                    out.stamps.append(stamp)
                }
            }
            let label = (object.text("label") ?? "").lowercased()
            let value = object["value"]?.string
            if ["username", "owner", "author"].contains(label), let value { author = truthy(author) ?? value }
            if label == "name", let value { name = truthy(name) ?? value }
            if ["caption", "comment", "text"].contains(label), let value { text = truthy(text) ?? value }
            for (key, inner) in object["string_map_data"]?.pairs ?? [] where inner.isObject {
                let lower = key.lowercased()
                guard let value = inner.text("value") else { continue }
                if lower == "name" { name = truthy(name) ?? value }
                if lower == "comment" || lower == "text" { text = truthy(text) ?? value }
                if ["media owner", "owner", "username"].contains(lower) { author = truthy(author) ?? value }
            }
        }
        if truthy(author) == nil, let title = record.text("title") { author = title }
        out.author = PipelineText.clean(author)
        out.name = PipelineText.clean(name)
        out.text = PipelineText.clean(text)
        return out
    }

    private static func truthy(_ text: String?) -> String? {
        text?.isEmpty == false ? text : nil
    }

    struct Labels {
        var url: String?
        var caption: String?
        var author: String?
        var hashtags: [String] = []
        var name: String?
        var items: [JSONValue] = []
    }

    /// A 2025-style record: label_values with URL, Caption, Hashtags and Owner. Nil for older shapes.
    static func labels(_ record: JSONValue) -> Labels? {
        guard record.isObject, let values = record["label_values"]?.array else { return nil }
        var out = Labels()
        for entry in values {
            let label = (entry.text("label") ?? "").lowercased()
            let title = (entry.text("title") ?? "").lowercased()
            let nested = entry["dict"]?.array ?? []
            if label == "url", let value = entry["value"]?.string {
                out.url = entry.text("href") ?? value
            } else if label == "caption" {
                out.caption = PipelineText.clean(entry["value"]?.string)
            } else if label == "name" {
                out.name = PipelineText.clean(entry["value"]?.string)
            } else if title == "hashtags" {
                out.hashtags = nested.flatMap { $0["dict"]?.array ?? [] }.compactMap { value in
                    value["value"]?.isTruthy == true ? PipelineText.clean(value["value"]?.string) : nil
                }
            } else if title == "owner" || label == "owner" {
                for group in nested {
                    for value in group["dict"]?.array ?? [] where (value.text("label") ?? "").lowercased() == "username" {
                        if let name = value.text("value") { out.author = PipelineText.clean(name) }
                    }
                }
            } else if entry["dict"] != nil, title.isEmpty || title == "media" {
                // A saved collection lists its posts as nested records, titled "Media".
                for group in nested where group.isObject {
                    out.items.append(.object([("label_values", group["dict"]?.isTruthy == true ? group["dict"]! : .array([])),
                                              ("timestamp", record["timestamp"] ?? .null)]))
                }
            }
        }
        return out
    }

    private static func postText(_ caption: String?, _ hashtags: [String]) -> String? {
        if let caption { return caption }
        let tags = hashtags.filter { !$0.isEmpty }.map { "#" + $0 }.joined(separator: " ")
        return tags.isEmpty ? nil : tags
    }

    private static func linkRecord(_ code: String, at: Int, estimated: Bool, author: String?, text: String?, type: String, collection: String?, source: String) -> ImportRecord {
        let created = PipelineText.instagramShortcodeTime(code)
        return ImportRecord(id: "ig:\(code)", platform: "instagram", kind: text != nil ? "text" : "link",
                            url: "https://www.instagram.com/p/\(code)/", author: author, text: text, createdAt: created, createdEstimated: created != nil,
                            interactions: [ImportInteraction(type: type, at: at, estimated: estimated, collection: collection, source: source)])
    }

    private static func links(_ archive: Archive, _ name: String, type: String, collectionAware: Bool = false, emit: (ImportRecord) throws -> Void) throws {
        guard let data = load(archive, name) else { return }
        var collection: String?
        for record in mainList(data) {
            let recordTime = record.isObject ? PipelineText.plausibleTime(record["timestamp"]) ?? 0 : 0
            if let label = labels(record) {
                if !label.items.isEmpty, let group = label.name {     // a collection with its posts inside
                    for item in label.items {
                        guard let inner = labels(item), let code = PipelineText.instagramShortcode(inner.url) else { continue }
                        try emit(linkRecord(code, at: recordTime, estimated: false, author: inner.author, text: postText(inner.caption, inner.hashtags),
                                            type: type, collection: group, source: name))
                    }
                    continue
                }
                if let code = PipelineText.instagramShortcode(label.url) {
                    try emit(linkRecord(code, at: recordTime, estimated: recordTime == 0, author: label.author, text: postText(label.caption, label.hashtags),
                                        type: type, collection: nil, source: name))
                }
                continue
            }
            // Older shapes: string_list_data, string_map_data and header rows for collections.
            let flat = flatten(record)
            let code = flat.urls.lazy.compactMap { PipelineText.instagramShortcode($0) }.first
            if collectionAware, code == nil, let header = flat.name {
                collection = header
                continue
            }
            guard let code else { continue }
            try emit(linkRecord(code, at: flat.stamps.max() ?? 0, estimated: flat.stamps.isEmpty, author: flat.author, text: flat.text,
                                type: type, collection: collectionAware ? collection : nil, source: name))
        }
    }

    /// Media entries (`uri`, `creation_timestamp`, maybe `title`) anywhere in a structure.
    static func mediaEntries(_ value: JSONValue) -> [JSONValue] {
        var out: [JSONValue] = []
        value.walk { object in
            if object["uri"]?.string != nil, object["creation_timestamp"] != nil || object["title"] != nil { out.append(object) }
        }
        return out
    }

    /// Your own posts' shortcodes, by when they were posted, from those you liked or saved.
    /// The export lists your posts without their shortcode, but a shortcode holds the moment
    /// it was posted, to the second, which is the time your post carries.
    private static func ownCodes(_ archive: Archive, username: String?) throws -> [Int: String] {
        guard let username else { return [:] }
        var codes: [Int: String] = [:]
        let note: (ImportRecord) -> Void = { record in
            if record.author == username, let time = record.createdAt { codes[time] = String(record.id.dropFirst("ig:".count)) }
        }
        for name in archive.find(#"(^|/)liked_posts\.json$"#) { try links(archive, name, type: "like", emit: note) }
        for name in archive.find(#"(^|/)saved_collections\.json$"#) { try links(archive, name, type: "save", collectionAware: true, emit: note) }
        for name in archive.find(#"(^|/)saved_posts\.json$"#) { try links(archive, name, type: "save", emit: note) }
        return codes
    }

    private static func ownPosts(_ archive: Archive, username: String?, emit: (ImportRecord) throws -> Void) throws {
        let profile = username.map { "https://www.instagram.com/\($0)/" }
        let codes = try ownCodes(archive, username: username)
        // Older exports keep your posts in content/, newer ones in your_instagram_activity/media/.
        for name in archive.find(#"(^|/)(content|media)/(posts_\d+|reels|stories|igtv_videos|profile_photos)\.json$"#) {
            guard let data = load(archive, name) else { continue }
            let collection = ["stories": "stories", "reels": "reels", "profile_photos": "profile photos"][PipelineText.stem(name)]
            for post in mainList(data) {
                let entries = mediaEntries(post)
                guard let first = entries.first else { continue }
                let caption = PipelineText.clean(post.text("title") ?? first.text("title"))
                let postStamp = post["creation_timestamp"], firstStamp = first["creation_timestamp"]
                let stamp = (postStamp?.isTruthy == true ? postStamp : firstStamp)?.number.map { Int($0) } ?? 0
                var media: [ImportMedia] = []
                var kinds = Set<String>()
                for (index, entry) in entries.enumerated() {
                    let uri = entry["uri"]?.string ?? ""
                    let isVideo = PipelineText.videoExtensions.contains(PipelineText.suffix(uri))
                    kinds.insert(isVideo ? "video" : "image")
                    if let member = archive.find(suffix: uri) {
                        media.append(ImportMedia(ord: index, kind: isVideo ? "video" : "image", name: member) { try archive.read(member) })
                    }
                }
                let id = PipelineText.sha1Prefix(first["uri"]?.string ?? "")
                // Known by its shortcode when you also liked or saved it, so that's one item.
                let code = stamp != 0 ? codes[stamp] : nil
                try emit(ImportRecord(id: code.map { "ig:\($0)" } ?? "ig:own:\(id)", platform: "instagram", kind: kinds == ["video"] ? "video" : "image",
                                      url: code.map { "https://www.instagram.com/p/\($0)/" } ?? profile, author: username,
                                      text: caption, createdAt: stamp != 0 ? stamp : nil, hydrated: 1,
                                      interactions: [ImportInteraction(type: "post", at: stamp, collection: collection, source: name)], media: media,
                                      replaces: code == nil ? [] : ["ig:own:\(id)"]))
            }
        }
    }

    private static func comments(_ archive: Archive, username: String?, emit: (ImportRecord) throws -> Void) throws {
        for name in archive.find(#"(^|/)comments/[^/]*comments[^/]*\.json$"#) {
            guard let data = load(archive, name) else { continue }
            for record in mainList(data) {
                let flat = flatten(record)
                guard let text = flat.text else { continue }
                let at = flat.stamps.max() ?? 0
                try emit(ImportRecord(id: "ig:comment:\(PipelineText.sha1Prefix("\(at):\(text)"))", platform: "instagram", kind: "text", author: username, text: text,
                                      createdAt: at != 0 ? at : nil, hydrated: 1,
                                      interactions: [ImportInteraction(type: "comment", at: at, source: name)]))
            }
        }
    }

    private static func username(_ archive: Archive) -> String? {
        for name in archive.find(#"personal_information/personal_information\.json$"#) {
            guard let data = load(archive, name) else { continue }
            var found: String?
            data.walk { object in
                if found == nil, let value = object["string_map_data"]?["Username"]?.text("value") { found = value }
            }
            if let found { return found }
        }
        return nil
    }

    public static func parse(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        let username = username(archive)
        try ownPosts(archive, username: username, emit: emit)
        for name in archive.find(#"(^|/)liked_posts\.json$"#) { try links(archive, name, type: "like", emit: emit) }
        // Collections first, so a save keeps its collection's name when it also appears
        // without one in saved_posts.json.
        for name in archive.find(#"(^|/)saved_collections\.json$"#) { try links(archive, name, type: "save", collectionAware: true, emit: emit) }
        for name in archive.find(#"(^|/)saved_posts\.json$"#) { try links(archive, name, type: "save", emit: emit) }
        try comments(archive, username: username, emit: emit)
    }
}
