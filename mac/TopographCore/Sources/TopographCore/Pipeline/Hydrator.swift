import Foundation
import GRDB

/// Fetch media and text for items that arrived as bare links, one request at a time, at a human
/// pace. Marks what it can't reach so it isn't retried forever. See hydrate.py.
///
///   X          the public endpoint behind embedded tweets (no login). Unofficial, may change.
///   Instagram  the post's public embed page, then the post page. When you've signed in, a
///              web view reads whatever the public pages refused, as you.
///   YouTube    a video's thumbnail, by its id. Nothing is asked of YouTube but the picture.
public struct Hydrator: Sendable {
    public struct Found: Sendable, Equatable {
        public struct Media: Sendable, Equatable {
            public var url: String
            public var video: Bool
        }

        public var text: String?
        public var author: String?
        public var createdAt: Int?
        public var media: [Media]
    }

    public static let maxAttempts = 3
    /// The sources whose posts can be fetched.
    public static let fetchable: Set<String> = ["x", "instagram", "youtube"]
    public static let maxFailures = 10

    public var fetcher: WebFetcher = .standard
    /// The HTML of an Instagram post as you see it signed in, or nil if you aren't.
    public var signedInPage: (@Sendable (_ url: String) -> String?)?
    public var delay: TimeInterval = 1.5
    public var wait: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    public init(fetcher: WebFetcher = .standard, signedInPage: (@Sendable (_ url: String) -> String?)? = nil, delay: TimeInterval = 1.5,
                wait: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.fetcher = fetcher
        self.signedInPage = signedInPage
        self.delay = delay
        self.wait = wait
    }

    // MARK: X

    private static func base36(_ value: Double, maxFractionDigits: Int = 11) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var whole = Int(value)
        var fraction = value - Double(whole)
        var out = ""
        repeat {
            out.insert(digits[whole % 36], at: out.startIndex)
            whole /= 36
        } while whole != 0
        var part = ""
        for _ in 0..<maxFractionDigits {
            fraction *= 36
            let digit = Int(fraction)
            part.append(digits[digit])
            fraction -= Double(digit)
            if fraction == 0 { break }
        }
        return part.isEmpty ? out : out + "." + part
    }

    /// The token the embed endpoint expects.
    public static func xToken(_ id: String) -> String {
        guard let number = Double(id) else { return "a" }
        let token = base36(number / 1e15 * .pi).filter { $0 != "0" && $0 != "." }
        return token.isEmpty ? "a" : token
    }

    public static func parseXSyndication(_ data: JSONValue) -> Found {
        var media: [Found.Media] = []
        for entry in data["mediaDetails"]?.array ?? [] {
            if let url = entry.text("media_url_https") {
                let type = entry["type"]?.string
                media.append(.init(url: url, video: type == "video" || type == "animated_gif"))
            }
        }
        if media.isEmpty, let poster = data["video"]?.text("poster") { media.append(.init(url: poster, video: true)) }
        if media.isEmpty, let values = data["card"]?["binding_values"], values.isTruthy {
            for key in ["photo_image_full_size_large", "thumbnail_image_large", "summary_photo_image_large"] {
                if let url = values[key]?["image_value"]?.text("url") {
                    media.append(.init(url: url, video: false))
                    break
                }
            }
        }
        return Found(text: data["text"]?.string, author: data["user"]?["screen_name"]?.string,
                     createdAt: PipelineText.parseTwitterDate(data["created_at"]?.string), media: media)
    }

    private func hydrateX(id: String) throws -> Found? {
        let tweet = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
        let body = try fetcher.fetch("https://cdn.syndication.twimg.com/tweet-result?id=\(tweet)&lang=en&token=\(Self.xToken(tweet))", "application/json", 20)
        let text = PipelineText.strip(String(decoding: body, as: UTF8.self))
        guard !text.isEmpty, let data = try? JSONValue.parse(text), data.isTruthy, data["__typename"]?.string != "TweetTombstone" else { return nil }
        var found = Self.parseXSyndication(data)
        if PipelineText.isUnavailable(found.text) {
            if found.media.isEmpty { return nil }
            found.text = nil
        }
        return found
    }

    // MARK: Instagram

    private static let openGraph = PipelineText.regex(#"<meta[^>]+property="og:([a-z:_]+)"[^>]+content="([^"]*)""#, .caseInsensitive)
    private static let openGraphReversed = PipelineText.regex(#"<meta[^>]+content="([^"]*)"[^>]+property="og:([a-z:_]+)""#, .caseInsensitive)
    private static let description = PipelineText.regex(#"^.*?-\s*([A-Za-z0-9_.]+)\s+on\s+[^:]+:\s*"?(.*?)"?\.?$"#, .dotMatchesLineSeparators)
    private static let embedImage = PipelineText.regex(#"<img[^>]+class="[^"]*EmbeddedMediaImage[^"]*"[^>]+src="([^"]+)""#, .caseInsensitive)
    private static let embedImageReversed = PipelineText.regex(#"<img[^>]+src="([^"]+)"[^>]+class="[^"]*EmbeddedMediaImage[^"]*""#, .caseInsensitive)
    private static let embedCaption = PipelineText.regex(#"<div class="Caption">(.*?)<div class="CaptionComments">"#, .dotMatchesLineSeparators)
    private static let embedUser = PipelineText.regex(#"<a class="CaptionUsername"[^>]*>([^<]+)</a>"#)
    private static let tag = PipelineText.regex("<[^>]+>")
    private static let runOfSpaces = PipelineText.regex(#"[ \t]+"#)
    private static let html: CLIPTokenizer? = try? CLIPTokenizer()

    private static func unescape(_ text: String) -> String { html?.unescaped(text) ?? text }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    public static func parseInstagramEmbed(_ page: String) -> Found? {
        guard let image = PipelineText.firstGroups(embedImage, page)?[1] ?? PipelineText.firstGroups(embedImageReversed, page)?[1] else { return nil }
        var caption: String?, author: String?
        if let raw = PipelineText.firstGroups(embedCaption, page)?[1] {
            if let user = PipelineText.firstGroups(embedUser, raw)?[1] { author = PipelineText.strip(unescape(user)) }
            let withoutUser = replacing(embedUser, in: raw, with: "")
            let plain = unescape(replacing(tag, in: withoutUser.replacingOccurrences(of: "<br />", with: "\n"), with: " "))
            caption = PipelineText.clean(replacing(runOfSpaces, in: plain, with: " "))
        }
        return Found(text: caption, author: author, createdAt: nil, media: [.init(url: unescape(image), video: false)])
    }

    public static func parseInstagramOpenGraph(_ page: String) -> Found? {
        var tags: [String: String] = [:]
        let range = NSRange(page.startIndex..., in: page)
        for match in openGraph.matches(in: page, range: range) {
            if let key = Range(match.range(at: 1), in: page), let value = Range(match.range(at: 2), in: page) {
                tags[page[key].lowercased()] = unescape(String(page[value]))
            }
        }
        for match in openGraphReversed.matches(in: page, range: range) {
            if let value = Range(match.range(at: 1), in: page), let key = Range(match.range(at: 2), in: page) {
                tags[page[key].lowercased()] = unescape(String(page[value]))
            }
        }
        guard let image = tags["image"], !image.isEmpty, !isInstagramsOwn(image) else { return nil }
        var text: String?, author: String?
        if let about = [tags["description"], tags["title"]].compactMap({ $0?.isEmpty == false ? $0 : nil }).first {
            if let groups = PipelineText.firstGroups(description, about) {
                author = groups[1]
                text = PipelineText.clean(groups[2])
            } else {
                text = about
            }
        }
        return Found(text: text, author: author, createdAt: nil, media: [.init(url: image, video: tags["type"] == "video")])
    }

    /// Instagram's own pictures, its logo among them, come from rsrc.php. A post page that offers
    /// one is the sign-in page Instagram shows in place of a post it won't give out.
    static func isInstagramsOwn(_ image: String) -> Bool { image.contains("/rsrc.php/") }

    /// Posts saved with Instagram's logo for a picture, before its sign-in page was recognized,
    /// go back to waiting: they were never really fetched. Returns how many.
    @discardableResult
    public static func forgetSignInPages(library: LibraryWriter) throws -> Int {
        try library.db.write { db in
            let ids = try String.fetchAll(db, sql: """
                select distinct media.item_id from media join item on item.id = media.item_id
                where item.platform = 'instagram' and media.original_url like '%/rsrc.php/%'
                """)
            for id in ids {
                for table in ["media", "embedding", "layout"] {
                    try db.execute(sql: "delete from \(table) where item_id = ?", arguments: [id])
                }
                // "Instagram" was the page's title, not the post's caption.
                try db.execute(sql: """
                    update item set hydrated = 0, hydrate_attempts = 0, text = nullif(text, 'Instagram'),
                    kind = case when coalesce(nullif(text, 'Instagram'), '') = '' then 'link' else 'text' end where id = ?
                    """, arguments: [id])
            }
            return ids.count
        }
    }

    private func hydrateInstagram(url: String?) throws -> Found? {
        guard let code = PipelineText.instagramShortcode(url) else { return nil }
        var answered = false
        let pages: [(String, (String) -> Found?)] = [("https://www.instagram.com/p/\(code)/embed/captioned/", Self.parseInstagramEmbed),
                                                     ("https://www.instagram.com/p/\(code)/", Self.parseInstagramOpenGraph)]
        var lastFailure: FetchFailure?
        for (address, parser) in pages {
            do {
                let page = String(decoding: try fetcher.fetch(address, "text/html", 20), as: UTF8.self)
                answered = true
                if let found = parser(page) { return found }
            } catch let failure as FetchFailure {
                if !failure.isNetwork { answered = true }
                lastFailure = failure
            }
        }
        if let signedIn = signedInPage, let page = signedIn(pages[1].0), let found = Self.parseInstagramOpenGraph(page) { return found }
        // With no answer at all the post may be fine: this mustn't count against it.
        if !answered, let lastFailure { throw lastFailure }
        return nil
    }

    private func hydrate(id: String, platform: String, url: String?) throws -> Found? {
        switch platform {
        case "x": return try hydrateX(id: id)
        case "instagram": return try hydrateInstagram(url: url)
        case "youtube":
            let video = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
            return Found(media: [.init(url: YouTubeImporter.thumbnailURL(video), video: true)])
        default: return nil
        }
    }

    // MARK: Running

    /// Download media rows that only have a web address. Returns how many arrived.
    @discardableResult
    func downloadPendingMedia(library: LibraryWriter, itemID: String? = nil, platforms: Set<String>? = nil, delay: TimeInterval,
                              reporter: PipelineReporter, line: ProgressLine? = nil) throws -> Int {
        var rows = try library.db.read { db -> [Row] in
            var sql = """
                select media.item_id, ord, original_url, media.kind, item.platform from media join item on item.id = media.item_id
                where status = 'pending' and original_url is not null
                """
            var arguments = StatementArguments()
            if let itemID {
                sql += " and item_id = ?"
                arguments = [itemID]
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments)
        }
        if let platforms { rows = rows.filter { platforms.contains($0["platform"] as String) } }
        line?.setTotal(rows.count)
        var done = 0
        for row in rows {
            let id = row["item_id"] as String, ord = row["ord"] as Int, url = row["original_url"] as String, kind = row["kind"] as String
            line?.advance()
            let data: Data
            do {
                data = try fetcher.fetch(url, "image/*", 20)
            } catch {
                try library.db.write { try $0.execute(sql: "update media set status = 'failed' where item_id = ? and ord = ?", arguments: [id, ord]) }
                continue
            }
            // For a video, the address already points at a poster frame.
            let prepared = MediaIngest.prepare(data, kind: "image", name: nil, isPoster: kind == "video", library: library)
            try library.store(prepared, itemID: id, ord: ord)
            if case .ready = prepared { done += 1 }
            try reporter.pause(delay, wait: wait)
        }
        return done
    }

    public struct Stats: Sendable {
        public var hydrated = 0
        public var unreachable = 0
        /// Not found this time, but with attempts left.
        public var toRetry = 0
        public var skipped = 0
        public var media = 0
        public var stoppedOnFailures = false
    }

    /// Posts not tried yet come first, newest first, then the ones that have failed: most of those
    /// are gone, and thousands of them could otherwise stand in front of posts that are still there.
    /// Resumable: stop it any time and what it fetched stays. `retryingUnreachable` takes only the
    /// posts already given up on instead, which stay given up on unless they're found.
    public func hydrate(library: LibraryWriter, platforms: Set<String>? = nil, limit: Int? = nil, retryingUnreachable: Bool = false, reporter: PipelineReporter) throws -> Stats {
        var stats = Stats()
        let forgotten = try Self.forgetSignInPages(library: library)
        if forgotten > 0 {
            reporter.say("\(forgotten.formatted()) Instagram posts had Instagram’s logo for a picture, so they’ll be fetched again.")
        }
        let chosen = retryingUnreachable ? "hydrated = -1" : "hydrated = 0 and hydrate_attempts < \(Self.maxAttempts)"
        var rows = try library.db.read { db in
            try Row.fetchAll(db, sql: """
                select id, platform, url, hydrate_attempts from item where \(chosen)
                order by hydrate_attempts, (select max(at) from interaction where item_id = item.id) desc
                """)
        }
        // Only what can be fetched, so the count is the one the Sources page shows: a Facebook
        // link has nothing here to fetch it with.
        rows = rows.filter { Self.fetchable.contains($0["platform"] as String) && platforms?.contains($0["platform"] as String) != false }
        if let limit { rows = Array(rows.prefix(limit)) }
        let line = ProgressLine("Fetching liked and saved posts", total: rows.count, unit: "posts", reporter: reporter)
        var failures = 0
        for row in rows {
            let id = row["id"] as String, platform = row["platform"] as String
            line.advance(note: "\(stats.hydrated.formatted()) fetched, \(stats.toRetry.formatted()) to retry, \(stats.unreachable.formatted()) unreachable")
            var found: Found?
            var networkDown = false, failed = false
            do {
                found = try hydrate(id: id, platform: platform, url: row["url"])
            } catch let failure as FetchFailure {
                failed = true
                networkDown = failure.isNetwork
            }
            if let found {
                failures = 0
                let kind = found.media.contains(where: \.video) ? "video" : found.media.isEmpty ? "text" : "image"
                try library.db.write { db in
                    try db.execute(sql: """
                        update item set hydrated = 1, kind = ?, text = coalesce(?, text), author = coalesce(?, author),
                        created_at = coalesce(?, created_at), created_estimated = case when ? is null then created_estimated else 0 end where id = ?
                        """, arguments: [kind, found.text, found.author, found.createdAt, found.createdAt, id])
                    try db.execute(sql: "delete from embedding where item_id = ?", arguments: [id])    // now stale
                    for (ord, media) in found.media.prefix(4).enumerated() {
                        try db.execute(sql: "insert or ignore into media(item_id, ord, kind, original_url) values (?,?,?,?)",
                                       arguments: [id, ord, media.video ? "video" : "image", media.url])
                    }
                }
                // Never hold the library while waiting on the network: hydrating runs for days.
                stats.media += try downloadPendingMedia(library: library, itemID: id, delay: 0.2, reporter: reporter)
                stats.hydrated += 1
            } else {
                if failed { failures += 1 }
                var gaveUp = false
                // A network that's down says nothing about the post, so it doesn't count against it.
                if !networkDown {
                    let attempts = (row["hydrate_attempts"] as Int) + 1
                    try library.db.write { db in
                        try db.execute(sql: "update item set hydrate_attempts = ?, hydrated = case when ? >= ? then -1 else 0 end where id = ?",
                                       arguments: [attempts, attempts, Self.maxAttempts, id])
                    }
                    gaveUp = attempts >= Self.maxAttempts
                }
                if gaveUp { stats.unreachable += 1 } else { stats.toRetry += 1 }
            }
            if failures >= Self.maxFailures {
                stats.stoppedOnFailures = true
                reporter.say("10 network failures in a row, so stopping. Check your connection and run it again.")
                break
            }
            try reporter.pause(delay, wait: wait)
        }
        line.close("\(stats.hydrated.formatted()) fetched, \(stats.toRetry.formatted()) to retry, \(stats.unreachable.formatted()) unreachable, \(stats.media.formatted()) images")
        return stats
    }
}

extension Hydrator.Found {
    init(media: [Media]) { self.init(text: nil, author: nil, createdAt: nil, media: media) }
}
