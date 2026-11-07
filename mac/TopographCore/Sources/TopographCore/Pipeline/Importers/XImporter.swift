import Foundation

/// The X (Twitter) archive. Its data/*.js files are JavaScript shims around JSON, and large
/// feeds are split across tweets.js, tweets-part1.js and so on.
public enum XImporter: ArchiveImporter {
    public static let name = "x"
    public static let title = "X"
    private static let shim = PipelineText.regex(#"^\s*window\.YTD\.[A-Za-z0-9_]+\.part\d+\s*=\s*"#)
    private static let trailingLink = PipelineText.regex(#"\s*https://t\.co/\w+\s*$"#)
    private static let repostAuthor = PipelineText.regex(#"^RT @([A-Za-z0-9_]+):"#)

    public static func detect(_ archive: Archive) -> Bool {
        !archive.find(#"(^|/)data/(tweets|like|account)(-part\d+)?\.js$"#).isEmpty
    }

    private static func feed(_ archive: Archive, _ name: String) throws -> [(source: String, entry: JSONValue)] {
        var out: [(String, JSONValue)] = []
        for file in archive.find("(^|/)data/\(name)(-part\\d+)?\\.js$") {
            let raw = try archive.readText(file)
            let range = NSRange(raw.startIndex..., in: raw)
            var body = raw
            if let match = shim.firstMatch(in: raw, range: range), let found = Range(match.range, in: raw) {
                body = String(raw[found.upperBound...])
            }
            body = PipelineText.strip(body)
            while body.hasSuffix(";") { body.removeLast() }
            let data = try JSONValue.parse(body)
            for entry in data.array ?? [] { out.append((file, entry)) }
        }
        return out
    }

    private static func unwrap(_ entry: JSONValue, _ key: String) -> JSONValue {
        guard entry.isObject else { return .object([]) }
        return entry[key] ?? entry
    }

    private static func expandedText(_ tweet: JSONValue) -> String? {
        var text = tweet.text("full_text") ?? tweet.text("text") ?? ""
        let entities = tweet["entities"] ?? .null
        for url in entities["urls"]?.array ?? [] {
            if let short = url.text("url"), let long = url.text("expanded_url") {
                text = text.replacingOccurrences(of: short, with: long)
            }
        }
        // A trailing t.co link pointing at attached media.
        let source = tweet["extended_entities"]?.isTruthy == true ? tweet["extended_entities"]! : entities
        if source["media"]?.isTruthy == true {
            text = trailingLink.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return PipelineText.clean(text)
    }

    private static func string(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .int(let number)?: String(number)
        case .double(let number)?: String(number)
        default: ""
        }
    }

    public static func parse(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        var me = "i"
        for (_, entry) in try feed(archive, "account") {
            if let username = unwrap(entry, "account").text("username") { me = username; break }
        }
        var mediaFiles: [String: [String]] = [:]
        for name in archive.find(#"(^|/)data/tweets?_media/[^/]+$"#) {
            let base = name.split(separator: "/").last.map(String.init) ?? name
            let id = base.components(separatedBy: "-")[0]
            mediaFiles[id, default: []].append(name)
        }

        // Your posts, replies and reposts.
        for (source, entry) in try feed(archive, "tweets") {
            let tweet = unwrap(entry, "tweet")
            let id = tweet.text("id_str") ?? string(tweet["id"])
            if id.isEmpty { continue }
            let at = PipelineText.parseTwitterDate(tweet["created_at"]?.string) ?? PipelineText.snowflakeTime(id)
            let full = tweet.text("full_text") ?? ""
            var author: String? = me
            let type: String
            if full.hasPrefix("RT @") {
                type = "repost"
                author = PipelineText.firstGroups(repostAuthor, full)?[1]
            } else if tweet["in_reply_to_status_id_str"]?.isTruthy == true {
                type = "reply"
            } else {
                type = "post"
            }

            let extended = tweet["extended_entities"]?["media"]
            let entities = extended?.isTruthy == true ? extended! : (tweet["entities"]?["media"] ?? .array([]))
            let localImages = (mediaFiles[id] ?? []).sorted().filter { !PipelineText.videoExtensions.contains(PipelineText.suffix($0)) }
            var media: [ImportMedia] = []
            var hasVideo = false
            for (index, entity) in (entities.array ?? []).enumerated() {
                let mediaType = entity.text("type") ?? "photo"
                let isVideo = mediaType == "video" || mediaType == "animated_gif"
                let remote = entity.text("media_url_https") ?? entity.text("media_url")
                var local: String?
                if !isVideo, let remote {
                    let key = remote.split(separator: "/").last.map(String.init) ?? remote
                    local = localImages.first { $0.hasSuffix("-" + key) }
                }
                if let local {
                    media.append(ImportMedia(ord: index, url: remote, name: local) { try archive.read(local) })
                } else {
                    // For a video, the link is its poster frame, fetched later.
                    media.append(ImportMedia(ord: index, url: remote))
                    if isVideo { hasVideo = true }
                }
            }
            let kind = hasVideo ? "video" : !media.isEmpty ? "image"
                : tweet["entities"]?["urls"]?.isTruthy == true ? "link" : "text"
            try emit(ImportRecord(id: "x:\(id)", platform: "x", kind: kind, url: "https://x.com/\(author ?? me)/status/\(id)", author: author,
                                  text: expandedText(tweet), createdAt: at, hydrated: type != "repost" || !media.isEmpty ? 1 : 0,
                                  interactions: [ImportInteraction(type: type, at: at, source: source)], media: media))
        }

        // Likes and bookmarks.
        for (name, key, type) in [("like", "like", "like"), ("bookmark", "bookmark", "bookmark"), ("bookmarks", "bookmark", "bookmark")] {
            for (source, entry) in try feed(archive, name) {
                let object = unwrap(entry, key)
                let found = ["tweetId", "tweet_id", "id"].lazy.compactMap { object[$0].flatMap { $0.isTruthy ? $0 : nil } }.first
                let id = string(found)
                if id.isEmpty { continue }
                let created = PipelineText.snowflakeTime(id)
                // The archive doesn't say when you liked something. The post's own time is
                // a lower bound, so it stands in, marked as estimated.
                var at: Int?
                for field in ["createdAt", "created_at", "bookmarkedAt", "timestamp"] {
                    if let value = object[field], value.isTruthy {
                        at = PipelineText.parseTwitterDate(string(value))
                        break
                    }
                }
                var text = PipelineText.clean(object.text("fullText") ?? object.text("full_text"))
                let gone = PipelineText.isUnavailable(text)
                if gone { text = nil }  // X's notice, not the post; the post itself is gone
                try emit(ImportRecord(id: "x:\(id)", platform: "x", kind: text != nil ? "text" : "link",
                                      url: object.text("expandedUrl") ?? "https://x.com/i/web/status/\(id)", text: text, createdAt: created,
                                      hydrated: gone ? -1 : 0,
                                      interactions: [ImportInteraction(type: type, at: at ?? created ?? 0, estimated: at == nil, source: source)]))
            }
        }
    }
}
