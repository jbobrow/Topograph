import Foundation

/// How a long step says what it's doing, and how it's asked to stop.
public struct PipelineReporter: Sendable {
    /// The live line, rewritten as a step moves along.
    public var progress: @Sendable (String) -> Void
    /// A line that stays.
    public var say: @Sendable (String) -> Void
    public var isCancelled: @Sendable () -> Bool

    public init(progress: @escaping @Sendable (String) -> Void, say: @escaping @Sendable (String) -> Void, isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.progress = progress
        self.say = say
        self.isCancelled = isCancelled
    }
}

/// Stopped when asked to. Everything done so far is saved, so running it again picks up there.
public struct PipelinePaused: Error {}

/// One step's live line: calm, and updated a few times a second at most.
public final class ProgressLine {
    private let title: String
    private var total: Int?
    private let unit: String
    private let reporter: PipelineReporter
    private(set) var done = 0
    private var last = Date.distantPast

    init(_ title: String, total: Int? = nil, unit: String = "", reporter: PipelineReporter) {
        self.title = title
        self.total = total
        self.unit = unit
        self.reporter = reporter
        reporter.progress(title)
    }

    func setTotal(_ total: Int) { self.total = total }

    func advance(_ by: Int = 1, note: String? = nil) {
        done += by
        let now = Date()
        guard now.timeIntervalSince(last) > 0.1 else { return }
        last = now
        reporter.progress(text(note))
    }

    private func text(_ note: String?) -> String {
        var line = "\(title)  \(done.formatted())"
        if let total { line += " / \(total.formatted())" }
        if !unit.isEmpty { line += " \(unit)" }
        if let note, !note.isEmpty { line += "  \(note)" }
        return line
    }

    func close(_ summary: String) {
        reporter.say("\(title): \(summary)")
    }
}

/// The same work as the `topograph` commands, for the app.
public enum Pipeline {
    private static func checkStop(_ reporter: PipelineReporter) throws {
        if reporter.isCancelled() { throw PipelinePaused() }
    }

    /// Import export ZIPs or folders. With no platform named, each one in them is recognized.
    public static func importArchives(_ paths: [URL], platform: String? = nil, library: LibraryWriter, reporter: PipelineReporter) throws {
        let archive = try Archive(paths)
        let importers = platform.map { name in ArchiveImporters.all.filter { $0.name == name } } ?? ArchiveImporters.detect(archive)
        guard !importers.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Couldn’t recognize this export."])
        }
        for importer in importers {
            var new = 0
            let line = ProgressLine("Importing \(importer.title)", unit: "records", reporter: reporter)
            try importer.parse(archive) { record in
                try checkStop(reporter)
                if try library.upsert(record) { new += 1 }
                line.advance(note: "\(new.formatted()) new" + (record.media.isEmpty ? "" : ", copying images"))
            }
            line.close("\(line.done.formatted()) records, \(new.formatted()) new items")
        }
    }

    /// Read screenshots, downloads and working files from folders, or report what would be
    /// read with `dryRun`. With no folders, the ones used last time.
    public static func readFiles(_ folders: [String] = [], options: FilesRules.Options = .init(), dryRun: Bool = false, fixDates: Bool = false, library: LibraryWriter, reporter: PipelineReporter) throws {
        func stored(_ key: String) throws -> [String] {
            guard let text = try library.meta(key), let list = try JSONValue.parse(text).array else { return [] }
            return list.compactMap(\.string)
        }
        let roots = folders.isEmpty ? try stored("files_roots") : folders
        guard !roots.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Name the folders to read."])
        }
        var options = options
        options.exclude = Array(Set(try stored("files_excludes") + options.exclude)).sorted()

        var report = FilesReport()
        let look = ProgressLine("Looking through your folders" + (dryRun ? " (a first look)" : ""), unit: "files checked", reporter: reporter)
        let candidates = FilesImporter.collect(roots: roots, options: options, report: &report, onFolder: { folder, checked in
            look.advance(checked - look.done, note: (folder as NSString).lastPathComponent)
        }, stop: reporter.isCancelled)
        try checkStop(reporter)
        look.advance(report.checked - look.done)
        look.close("\(report.checked.formatted()) files checked, \(candidates.count.formatted()) to keep")
        if dryRun {
            for line in report.text.components(separatedBy: "\n") { reporter.say(line) }
            return
        }
        if fixDates {
            let fixing = ProgressLine("Correcting dates", total: candidates.count, unit: "files", reporter: reporter)
            let result = try FilesImporter.fixDates(library: library, candidates: candidates) { _ in fixing.advance() }
            fixing.close("\(result.corrected.formatted()) dates corrected, \(result.dropped.formatted()) opened records dropped")
            return
        }
        try library.setMeta("files_roots", jsonList(roots))
        try library.setMeta("files_excludes", jsonList(options.exclude))
        let finished = try library.finishedFiles()
        var new = 0
        let previews = ProgressLine("Making previews", total: candidates.count, unit: "files", reporter: reporter)
        for candidate in candidates {
            try checkStop(reporter)
            if let record = FilesImporter.record(for: candidate, report: &report, finished: finished), try library.upsert(record) { new += 1 }
            let folder = ((candidate.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            previews.advance(note: folder)
        }
        previews.close("\(previews.done.formatted()) files, \(new.formatted()) new")
        for line in report.text.components(separatedBy: "\n") { reporter.say(line) }
    }

    /// Fetch images for liked and saved posts. Stop it any time; running it again resumes.
    public static func hydrate(library: LibraryWriter, hydrator: Hydrator = Hydrator(), platforms: Set<String>? = nil, limit: Int? = nil, reporter: PipelineReporter) throws {
        reporter.say("Fetching images for liked and saved posts. Pause any time; it picks up where it left off.")
        let waiting = ProgressLine("Downloading waiting images", unit: "images", reporter: reporter)
        let arrived = try hydrator.downloadPendingMedia(library: library, delay: hydrator.delay / 3, reporter: reporter, line: waiting)
        if waiting.done > 0 { waiting.close("\(arrived.formatted()) images") }
        _ = try hydrator.hydrate(library: library, platforms: platforms, limit: limit, reporter: reporter)
    }

    /// Read your public activity from Bluesky or Are.na.
    public static func sync(source: String, account: String, library: LibraryWriter, limit: Int? = nil, fetcher: SyncFetcher = SyncFetcher(), reporter: PipelineReporter) throws {
        var new = 0
        let line = ProgressLine("Reading \(source == "arena" ? "Are.na" : "Bluesky")", unit: "records", reporter: reporter)
        let emit: (ImportRecord) throws -> Void = { record in
            try checkStop(reporter)
            if try library.upsert(record) { new += 1 }
            line.advance(note: "\(new.formatted()) new")
        }
        switch source {
        case "bluesky": try LiveSync.bluesky(handle: account, fetcher: fetcher, limit: limit, emit: emit)
        case "arena": try LiveSync.arena(slug: account, fetcher: fetcher, limit: limit, emit: emit)
        default: throw CocoaError(.featureUnsupported)
        }
        try library.setMeta("sync_\(source)", account)
        line.close("\(line.done.formatted()) records, \(new.formatted()) new items")
    }

    static func jsonList(_ values: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
