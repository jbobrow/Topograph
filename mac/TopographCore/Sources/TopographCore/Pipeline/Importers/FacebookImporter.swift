import Foundation

/// Facebook's "Download your information" (JSON), which shares Instagram's quirks. Likes and
/// reactions are usually just "You liked Ann's photo", with no link or picture, so they're kept
/// as traces that count in Strata but aren't placed on the map.
public enum FacebookImporter: ArchiveImporter {
    public static let name = "facebook"
    public static let title = "Facebook"

    public static func detect(_ archive: Archive) -> Bool {
        !archive.find(#"(your_facebook_activity/|(^|/)posts/your_posts[^/]*\.json$|likes_and_reactions[^/]*\.json$|(^|/)photos_and_videos/album/)"#).isEmpty
    }

    private static func hash(_ parts: String...) -> String {
        PipelineText.sha1Prefix(parts.joined(separator: "|"))
    }

    /// Your words in a post: data[].post, then a description, then nothing.
    private static func postText(_ record: JSONValue) -> String? {
        guard record.isObject else { return nil }
        for entry in record["data"]?.array ?? [] where entry.isObject {
            if let post = entry.text("post") { return PipelineText.clean(post) }
        }
        for media in InstagramImporter.mediaEntries(record) {
            if let description = media.text("description") { return PipelineText.clean(description) }
        }
        return nil
    }

    private static func links(_ record: JSONValue) -> [String] {
        var out: [String] = []
        record.walk { object in
            if let context = object["external_context"], context.isObject, let url = context["url"]?.string { out.append(url) }
            if (object.text("label") ?? "").lowercased() == "url", let value = object["value"]?.string { out.append(value) }
            if let href = object["href"]?.string { out.append(href) }
        }
        return out.filter { $0.hasPrefix("http") }
    }

    private static func stamp(_ record: JSONValue) -> Int {
        if record.isObject, let time = PipelineText.plausibleTime(record["timestamp"]) { return time }
        var stamps: [Int] = []
        record.walk { object in
            for (key, value) in object.pairs where key.contains("timestamp") {
                if let time = PipelineText.plausibleTime(value) { stamps.append(time) }
            }
        }
        return stamps.max() ?? 0
    }

    private static func ownPosts(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        for name in archive.find(#"(^|/)(posts|photos_and_videos)/(?!.*(comment|like|react))[^\n]*\.json$"#) {
            guard let data = InstagramImporter.load(archive, name) else { continue }
            // Albums are {"name": ..., "photos": [...]}: one item per photo.
            let album: String?
            let records: [JSONValue]
            if data.isObject, let photos = data["photos"]?.array {
                album = PipelineText.clean(data["name"]?.string)
                records = photos.filter(\.isObject)
            } else {
                album = nil
                records = InstagramImporter.mainList(data)
            }
            for record in records {
                let entries = InstagramImporter.mediaEntries(record)
                let text = postText(record) ?? (record.isObject ? PipelineText.clean(record["description"]?.string) : nil)
                let at = stamp(record)
                if entries.isEmpty, text == nil { continue }
                var media: [ImportMedia] = []
                var kinds = Set<String>()
                for (index, entry) in entries.prefix(10).enumerated() {
                    let uri = entry["uri"]?.string ?? ""
                    let isVideo = PipelineText.videoExtensions.contains(PipelineText.suffix(uri))
                    kinds.insert(isVideo ? "video" : "image")
                    if let member = archive.find(suffix: uri) {
                        media.append(ImportMedia(ord: index, kind: isVideo ? "video" : "image", name: member) { try archive.read(member) })
                    }
                }
                let key = entries.first?["uri"]?.string ?? "\(at):\(text ?? "None")"
                try emit(ImportRecord(id: "fb:own:\(hash(key))", platform: "facebook", kind: entries.isEmpty ? "text" : kinds == ["video"] ? "video" : "image",
                                      url: links(record).first, text: text, createdAt: at != 0 ? at : nil, hydrated: 1,
                                      interactions: [ImportInteraction(type: "post", at: at, collection: album, source: name)], media: media))
            }
        }
    }

    private static func saved(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        for name in archive.find(#"(^|/)saved_items_and_collections/[^/]*\.json$|(^|/)saved_items[^/]*\.json$"#) {
            guard let data = InstagramImporter.load(archive, name) else { continue }
            for record in InstagramImporter.mainList(data) {
                let urls = links(record)
                guard let first = urls.first else { continue }
                let flat = InstagramImporter.flatten(record)
                var title: String?
                var titled = false
                record.walk { object in
                    if !titled, let context = object["external_context"], context.isObject, let name = context.text("name") {
                        title = PipelineText.clean(name)
                        titled = true
                    }
                }
                let at = stamp(record)
                let author = flat.author.flatMap { $0.contains("saved") ? nil : $0 }
                try emit(ImportRecord(id: "fb:link:\(hash(first))", platform: "facebook", kind: "link", url: first, author: author, text: title,
                                      interactions: [ImportInteraction(type: "save", at: at, collection: flat.name, source: name)]))
            }
        }
    }

    private static func pages(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        for name in archive.find(#"(^|/)pages/[^/]*liked[^/]*\.json$|(^|/)pages_you'?ve_liked\.json$"#) {
            guard let data = InstagramImporter.load(archive, name) else { continue }
            for record in InstagramImporter.mainList(data) {
                guard record.isObject, let page = PipelineText.clean(record.text("name") ?? record.text("title")) else { continue }
                try emit(ImportRecord(id: "fb:page:\(hash(page))", platform: "facebook", kind: "text", url: links(record).first, text: page, hydrated: 1,
                                      interactions: [ImportInteraction(type: "like", at: stamp(record), collection: "Pages", source: name)]))
            }
        }
    }

    private static func comments(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        for name in archive.find(#"(^|/)comments_and_reactions/comments[^/]*\.json$|(^|/)comments/comments[^/]*\.json$"#) {
            guard let data = InstagramImporter.load(archive, name) else { continue }
            for record in InstagramImporter.mainList(data) {
                var text: String?
                var found = false
                record.walk { object in
                    guard !found, let comment = object["comment"] else { return }
                    if comment.isObject, let inner = comment.text("comment") {
                        text = PipelineText.clean(inner)
                        found = true
                    } else if let plain = comment.string, !PipelineText.strip(plain).isEmpty {
                        text = PipelineText.clean(plain)
                        found = true
                    }
                }
                guard let text else { continue }
                let at = stamp(record)
                try emit(ImportRecord(id: "fb:comment:\(hash(String(at), text))", platform: "facebook", kind: "text", text: text, hydrated: 1,
                                      interactions: [ImportInteraction(type: "comment", at: at, source: name)]))
            }
        }
    }

    private static func reactions(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        for name in archive.find(#"likes_and_reactions[^/]*\.json$|(^|/)reactions[^/]*\.json$"#) {
            guard let data = InstagramImporter.load(archive, name) else { continue }
            for record in InstagramImporter.mainList(data) {
                let at = stamp(record)
                let title = record.isObject ? PipelineText.clean(record["title"]?.string) : nil
                if let first = links(record).first {
                    try emit(ImportRecord(id: "fb:link:\(hash(first))", platform: "facebook", kind: "link", url: first,
                                          interactions: [ImportInteraction(type: "like", at: at, source: name)]))
                } else if title != nil || at != 0 {
                    try emit(ImportRecord(id: "fb:trace:\(hash(String(at), title ?? "None"))", platform: "facebook", kind: "trace", text: title, hydrated: -1,
                                          interactions: [ImportInteraction(type: "react", at: at, source: name)]))
                }
            }
        }
    }

    public static func parse(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        try ownPosts(archive, emit: emit)
        try saved(archive, emit: emit)
        try pages(archive, emit: emit)
        try comments(archive, emit: emit)
        try reactions(archive, emit: emit)
    }
}
