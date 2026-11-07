import Foundation
import TopographCore

/// Runs the pipeline for the app, off the main thread, one job at a time. Nothing here runs
/// unless you ask for it.
@MainActor
@Observable
final class PipelineRunner {
    enum Work: Equatable, Sendable {
        case importArchives([URL])
        case readFiles([String], options: FilesRules.Options, dryRun: Bool)
        case fixDates
        case hydrate
        case retryUnreachable(platform: String)
        case sync(source: String, account: String)
        case build(MapRecipe?)
    }

    struct Job: Equatable {
        let title: String
        let work: Work
    }

    private(set) var running: Job?
    /// The latest line of progress.
    private(set) var line = ""
    /// Everything said since the last job began.
    private(set) var log: [String] = []
    private(set) var failure: String?
    /// A hydrate started somewhere else, like the Python tools in a terminal.
    private(set) var hydrateElsewhere = false
    /// Whether that's been looked into yet.
    private(set) var hasCheckedHydrate = false
    private var stop: StopFlag?

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func set() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    func run(_ job: Job, library: URL, instagram: InstagramSession, then finished: @escaping @MainActor (Bool) -> Void) {
        guard running == nil else { return }
        let flag = StopFlag()
        stop = flag
        running = job
        line = job.title
        log = []
        failure = nil
        let page = instagram.isSignedIn ? instagram.pageReader : nil
        let reporter = PipelineReporter(progress: { [weak self] text in
            Task { @MainActor in self?.line = text }
        }, say: { [weak self] text in
            Task { @MainActor in self?.say(text) }
        }, isCancelled: { flag.isStopped })
        let work = job.work
        // Blocking work with all the cores it can use, so not on the shared task threads.
        DispatchQueue.global(qos: .utility).async {
            var problem: String?
            do {
                try Self.perform(work, library: library, instagramPage: page, reporter: reporter)
            } catch is PipelinePaused {
                reporter.say("Paused. Run it again to pick up where you left off.")
            } catch {
                problem = error.localizedDescription
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.running = nil
                self.stop = nil
                self.failure = problem
                finished(problem == nil)
            }
        }
    }

    private nonisolated static func perform(_ work: Work, library root: URL, instagramPage: (@Sendable (String) -> String?)?, reporter: PipelineReporter) throws {
        let library = try LibraryWriter(root: root)
        switch work {
        case .importArchives(let paths):
            try Pipeline.importArchives(paths, library: library, reporter: reporter)
        case .readFiles(let folders, let options, let dryRun):
            try Pipeline.readFiles(folders, options: options, dryRun: dryRun, library: library, reporter: reporter)
        case .fixDates:
            try Pipeline.readFiles([], fixDates: true, library: library, reporter: reporter)
        case .hydrate:
            try Pipeline.hydrate(library: library, hydrator: Hydrator(signedInPage: instagramPage), reporter: reporter)
        case .retryUnreachable(let platform):
            let count = try library.retryUnreachable(platform: platform)
            reporter.say("\(count.formatted()) posts to try again.")
            try Pipeline.hydrate(library: library, hydrator: Hydrator(signedInPage: instagramPage), platforms: [platform], reporter: reporter)
        case .sync(let source, let account):
            try Pipeline.sync(source: source, account: account, library: library, reporter: reporter)
        case .build(let recipe):
            try MapBuilder.build(recipe: recipe, library: library, reporter: reporter)
        }
    }

    /// Stop gently: what's done stays done, and running it again picks up there.
    func pause() {
        stop?.set()
    }

    private func say(_ text: String) {
        line = text
        log.append(text)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// Whether a hydrate is already going, so the app doesn't start a second one.
    func checkHydrateElsewhere() async {
        let found = await Task.detached(priority: .utility) { () -> Bool in
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            check.arguments = ["-f", "topograph hydrate"]
            check.standardOutput = FileHandle.nullDevice
            check.standardError = FileHandle.nullDevice
            guard (try? check.run()) != nil else { return false }
            check.waitUntilExit()
            return check.terminationStatus == 0
        }.value
        hydrateElsewhere = found && running?.work != .hydrate
        hasCheckedHydrate = true
    }
}
