import Foundation

/// A CSV file as rows of named fields, the same as Python's `csv.DictReader`.
enum CSVTable {
    static func rows(_ text: String) -> [[String: String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        if pending == "\u{FEFF}" { pending = scalars.next() }
        while let scalar = pending {
            pending = scalars.next()
            if quoted {
                if scalar == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = scalars.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else if scalar == "\"", field.isEmpty {
                quoted = true
            } else if scalar == "," {
                record.append(field)
                field = ""
            } else if scalar == "\n" || scalar == "\r" {
                if scalar == "\r", pending == "\n" { pending = scalars.next() }
                record.append(field)
                field = ""
                records.append(record)
                record = []
            } else {
                field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        records.removeAll { $0 == [""] }
        guard let header = records.first else { return [] }
        return records.dropFirst().map { row in
            var named: [String: String] = [:]
            for (index, name) in header.enumerated() where index < row.count { named[name] = row[index] }
            return named
        }
    }
}

/// YouTube, from a Google Takeout export with JSON chosen for history. Videos arrive with no
/// picture; hydration fetches each one's thumbnail by its id.
public enum YouTubeImporter: ArchiveImporter {
    public static let name = "youtube"
    public static let title = "YouTube"
    private static let root = "(^|/)YouTube[^/]*/"
    private static let videoLink = PipelineText.regex(#"[?&]v=([\w-]{6,})"#)
    private static let watched = PipelineText.regex(#"^Watched\s+"#)
    private static let videosSuffix = PipelineText.regex("-videos$")

    public static func thumbnailURL(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/hqdefault.jpg" }

    public static func detect(_ archive: Archive) -> Bool {
        !archive.find(root + #"history/watch-history\.json$"#).isEmpty || !archive.find(root + #"playlists/[^/]+\.csv$"#).isEmpty
    }

    private static func video(_ id: String, _ interaction: ImportInteraction, title: String? = nil, author: String? = nil) -> ImportRecord {
        ImportRecord(id: "youtube:\(id)", platform: "youtube", kind: "video", url: "https://www.youtube.com/watch?v=\(id)",
                     author: author, text: title, interactions: [interaction])
    }

    public static func parse(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        for name in archive.find(root + #"history/watch-history\.json$"#) {
            for entry in try archive.readJSON(name).array ?? [] {
                // A video that's since been removed leaves no link.
                guard let id = PipelineText.firstGroups(videoLink, entry.text("titleUrl") ?? "")?[1] else { continue }
                let raw = PipelineText.clean(entry["title"]?.string) ?? ""
                let title = watched.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
                let channel = entry["subtitles"]?.array?.first?.text("name")
                try emit(video(id, ImportInteraction(type: "view", at: PipelineText.takeoutTime(entry["time"]?.string), source: name),
                               title: title.isEmpty ? nil : title, author: channel))
            }
        }
        for name in archive.find(root + #"playlists/[^/]+\.csv$"#) {
            let stem = PipelineText.stem(name)
            if ["playlists", "playlist"].contains(stem.lowercased()) { continue }   // the list of playlists
            let playlist = videosSuffix.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: "")
            let liked = ["liked videos", "liked", "likes", "favorites"].contains(playlist.lowercased())
            for row in CSVTable.rows(try archive.readText(name)) {
                let id = PipelineText.strip(row["Video ID"].flatMap { $0.isEmpty ? nil : $0 } ?? row["Video Id"] ?? "")
                if id.isEmpty { continue }
                let time = PipelineText.takeoutTime(row["Playlist Video Creation Timestamp"].flatMap { $0.isEmpty ? nil : $0 } ?? row["Playlist video creation timestamp"])
                try emit(video(id, liked ? ImportInteraction(type: "like", at: time, source: name)
                                         : ImportInteraction(type: "save", at: time, collection: playlist, source: name)))
            }
        }
        for name in archive.find(root + #"comments/[^/]*comments[^/]*\.csv$"#) {
            for row in CSVTable.rows(try archive.readText(name)) {
                let id = PipelineText.strip(row["Video ID"] ?? "")
                if id.isEmpty { continue }
                try emit(video(id, ImportInteraction(type: "comment", at: PipelineText.takeoutTime(row["Comment Create Timestamp"]), source: name)))
            }
        }
    }
}

/// Searches from Google My Activity. A search says more about curiosity than taste, so each is a
/// text item on its own platform. Only searches are read: sites visited in Chrome are far more
/// private and say little about taste. Sensitive subjects are skipped by the same rules as files.
public enum GoogleImporter: ArchiveImporter {
    public static let name = "google"
    public static let title = "Google searches"
    private static let filePattern = #"(^|/)My Activity/([^/]+)/[^/]*\.json$"#
    private static let read: Set<String> = ["search", "image search", "discover"]
    private static let search = PipelineText.regex(#"^Searched for\s+(.+)$"#, .dotMatchesLineSeparators)

    public static func detect(_ archive: Archive) -> Bool { !archive.find(filePattern).isEmpty }

    public static func parse(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws {
        let file = PipelineText.regex(filePattern)
        for name in archive.find(filePattern) {
            guard let product = PipelineText.firstGroups(file, name)?[2], read.contains(product.lowercased()) else { continue }
            for entry in try archive.readJSON(name).array ?? [] {
                guard let match = PipelineText.firstGroups(search, entry.text("title") ?? "")?[1] else { continue }
                let query = PipelineText.strip(match)
                if query.isEmpty || FilesRules.isSensitivePath(query.lowercased()) { continue }
                // The same search again is one item you came back to.
                try emit(ImportRecord(id: "google:\(PipelineText.sha1Prefix(query.lowercased()))", platform: "google", kind: "text", url: entry.text("titleUrl"), text: query, hydrated: 1,
                                      interactions: [ImportInteraction(type: "search", at: PipelineText.takeoutTime(entry["time"]?.string), collection: product, source: name)]))
            }
        }
    }
}
