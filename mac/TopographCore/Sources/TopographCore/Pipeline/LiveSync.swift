import Foundation

/// Gets JSON one request at a time, politely. Tests replace `opener`.
public final class SyncFetcher: @unchecked Sendable {
    public static let maxFailures = 10

    public struct TooManyFailures: Error, LocalizedError {
        public var errorDescription: String? { "10 network failures in a row, so stopping. Check your connection and run it again." }
    }

    let delay: TimeInterval
    let opener: (String) throws -> Data
    let wait: (TimeInterval) -> Void
    public private(set) var failures = 0

    public init(delay: TimeInterval = 1.5, opener: ((String) throws -> Data)? = nil, wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.delay = delay
        self.opener = opener ?? { try WebFetcher.standard.fetch($0, "application/json", 30) }
        self.wait = wait
    }

    /// `urllib.parse.urlencode`: letters, digits and `_.-~` as they are, spaces as `+`.
    static func encode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"):
                out.append(Character(Unicode.Scalar(byte)))
            case 0x20: out.append("+")
            default: out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    public func json(_ base: String, _ path: String, _ parameters: [(String, String?)] = []) throws -> JSONValue {
        let query = parameters.compactMap { key, value in value.map { "\(key)=\(Self.encode($0))" } }.joined(separator: "&")
        let url = "\(base)/\(path)" + (query.isEmpty ? "" : "?\(query)")
        wait(delay)
        do {
            let data = try JSONValue.parse(String(decoding: try opener(url), as: UTF8.self))
            failures = 0
            return data
        } catch {
            failures += 1
            if failures >= Self.maxFailures { throw TooManyFailures() }
            throw error
        }
    }
}

/// Live sync with open APIs. Only your own public activity is read: no login and no write
/// access. Pictures are fetched afterward like any others, when hydrating.
public enum LiveSync {
    private static let blueskyHost = "https://bsky.social/xrpc"
    private static let blueskyApp = "https://public.api.bsky.app/xrpc"
    private static let arenaHost = "https://api.are.na/v2"

    private static func blueskyPost(_ post: JSONValue, _ interaction: ImportInteraction) -> ImportRecord? {
        guard let uri = post["uri"]?.string else { return nil }
        let author = post["author"] ?? .null
        let record = post["record"] ?? .null
        let images = post["embed"]?["images"]?.array ?? []
        let media = images.prefix(4).enumerated().map { index, image in
            ImportMedia(ord: index, url: image.text("fullsize") ?? image.text("thumb"))
        }
        let key = uri.components(separatedBy: "/").last ?? uri
        let handle = author.text("handle")
        let created = PipelineText.takeoutTime(record["createdAt"]?.string)
        return ImportRecord(id: "bluesky:\(uri)", platform: "bluesky", kind: media.isEmpty ? "text" : "image",
                            url: "https://bsky.app/profile/\(handle ?? author["did"]?.string ?? "None")/post/\(key)", author: handle,
                            text: PipelineText.clean(record["text"]?.string), createdAt: created != 0 ? created : nil, hydrated: 1,
                            interactions: [interaction], media: media)
    }

    /// Your posts, reposts and likes, newest first. Likes are public records on your repo.
    public static func bluesky(handle: String, fetcher: SyncFetcher, limit: Int? = nil, emit: (ImportRecord) throws -> Void) throws {
        guard let did = try fetcher.json(blueskyApp, "com.atproto.identity.resolveHandle", [("handle", handle)])["did"]?.string else { return }
        var count = 0
        var cursor: String?
        while true {
            let page = try fetcher.json(blueskyApp, "app.bsky.feed.getAuthorFeed", [("actor", did), ("limit", "100"), ("cursor", cursor)])
            for entry in page["feed"]?.array ?? [] {
                guard let post = entry["post"] else { continue }
                let reason = entry["reason"] ?? .null
                if reason.text("$type")?.hasSuffix("reasonRepost") == true {
                    let interaction = ImportInteraction(type: "repost", at: PipelineText.takeoutTime(reason["indexedAt"]?.string), source: "bluesky")
                    if let record = blueskyPost(post, interaction) { try emit(record) }
                } else if post["author"]?["did"]?.string == did {
                    let interaction = ImportInteraction(type: "post", at: PipelineText.takeoutTime(post["record"]?["createdAt"]?.string), source: "bluesky")
                    if let record = blueskyPost(post, interaction) { try emit(record) }
                }
                count += 1
            }
            cursor = page.text("cursor")
            if cursor == nil || (limit.map { count >= $0 } ?? false) { break }
        }

        count = 0
        cursor = nil
        while true {
            let page = try fetcher.json(blueskyHost, "com.atproto.repo.listRecords", [("repo", did), ("collection", "app.bsky.feed.like"), ("limit", "100"), ("cursor", cursor)])
            var uris: [String] = []
            var times: [String: Int] = [:]
            for record in page["records"]?.array ?? [] {
                guard let uri = record["value"]?["subject"]?["uri"]?.string else { continue }
                if times[uri] == nil { uris.append(uri) }
                times[uri] = PipelineText.takeoutTime(record["value"]?["createdAt"]?.string)
            }
            var start = 0
            while start < uris.count {
                let chunk = uris[start..<min(start + 25, uris.count)]
                let posts = try fetcher.json(blueskyApp, "app.bsky.feed.getPosts", chunk.map { ("uris", $0) })
                for post in posts["posts"]?.array ?? [] {
                    let interaction = ImportInteraction(type: "like", at: post["uri"]?.string.flatMap { times[$0] } ?? 0, source: "bluesky")
                    if let record = blueskyPost(post, interaction) {
                        try emit(record)
                        count += 1
                    }
                }
                start += 25
            }
            cursor = page.text("cursor")
            if cursor == nil || (limit.map { count >= $0 } ?? false) { break }
        }
    }

    private static func arenaBlock(_ block: JSONValue, channel: JSONValue) -> ImportRecord? {
        if block["base_class"]?.string != "Block", block["class"]?.string == "Channel" { return nil }
        guard let idValue = block["id"] else { return nil }
        let id: String
        switch idValue {
        case .int(let number): id = String(number)
        case .string(let text): id = text
        default: return nil
        }
        let image = block["image"] ?? .null
        let url = image["large"]?.text("url") ?? image["original"]?.text("url")
        let text = PipelineText.clean(block.text("content") ?? block.text("title") ?? block.text("generated_title"))
        let created = PipelineText.takeoutTime(block["created_at"]?.string)
        return ImportRecord(id: "arena:\(id)", platform: "arena", kind: url != nil ? "image" : "text",
                            url: block["source"]?.text("url") ?? "https://www.are.na/block/\(id)", author: block["user"]?["slug"]?.string, text: text,
                            createdAt: created != 0 ? created : nil, hydrated: 1,
                            interactions: [ImportInteraction(type: "save", at: PipelineText.takeoutTime(block.text("connected_at") ?? block["created_at"]?.string),
                                                             collection: channel["title"]?.string, source: "arena")],
                            media: url.map { [ImportMedia(ord: 0, url: $0)] } ?? [])
    }

    /// The blocks in your channels. Each channel is a collection.
    public static func arena(slug: String, fetcher: SyncFetcher, limit: Int? = nil, emit: (ImportRecord) throws -> Void) throws {
        var count = 0, page = 1
        let path = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "@:$&+,;="))) ?? slug
        while true {
            let listing = try fetcher.json(arenaHost, "users/\(path)/channels", [("page", String(page)), ("per", "50")])
            let channels = listing["channels"]?.array ?? []
            for channel in channels {
                guard let channelSlug = channel["slug"]?.string else { continue }
                var inner = 1
                while true {
                    let contents = try fetcher.json(arenaHost, "channels/\(channelSlug)/contents", [("page", String(inner)), ("per", "100")])
                    let blocks = contents["contents"]?.array ?? []
                    for block in blocks {
                        if let record = arenaBlock(block, channel: channel) {
                            try emit(record)
                            count += 1
                            if let limit, count >= limit { return }
                        }
                    }
                    if blocks.count < 100 { break }
                    inner += 1
                }
            }
            let total = listing["total_pages"]?.number.map { Int($0) } ?? 1
            if page >= max(total, 1) || channels.isEmpty { return }
            page += 1
        }
    }
}
