import Foundation
import TopographCore

/// Runs the Python pipeline for the app. It stays the reference for import, hydration and
/// mapping until they're ported, and it has the rules tuned on your real files.
/// Nothing here runs unless you ask for it.
@MainActor
@Observable
final class PipelineRunner {
    struct Job: Equatable {
        let title: String
        let arguments: [String]
    }

    private(set) var running: Job?
    /// The latest line of progress.
    private(set) var line = ""
    /// Everything said since the last job began.
    private(set) var log: [String] = []
    private(set) var failure: String?
    /// A hydrate started somewhere else, like a terminal.
    private(set) var hydrateElsewhere = false
    /// Whether that's been looked into yet.
    private(set) var hasCheckedHydrate = false
    private var process: Process?
    private var partial = ""

    /// The command, in order: `TOPOGRAPH_CLI`, then this repo's virtual environment, found
    /// by walking up from the app (for development builds), then the usual place.
    static func findCommand() -> URL? {
        let manager = FileManager.default
        if let env = ProcessInfo.processInfo.environment["TOPOGRAPH_CLI"], manager.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        var folder = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = folder.appending(path: ".venv/bin/topograph")
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
            folder.deleteLastPathComponent()
        }
        let usual = manager.homeDirectoryForCurrentUser.appending(path: "Developer/Topograph/.venv/bin/topograph")
        return manager.isExecutableFile(atPath: usual.path) ? usual : nil
    }

    func run(_ job: Job, library: URL, then finished: @escaping @MainActor (Bool) -> Void) {
        guard running == nil else { return }
        guard let command = Self.findCommand() else {
            failure = "Couldn't find the topograph command. Install it with pip install -e \".[clip]\", or set TOPOGRAPH_CLI."
            return
        }
        let process = Process()
        process.executableURL = command
        process.arguments = ["--library", library.path] + job.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.take(text) }
        }
        process.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            let succeeded = ended.terminationStatus == 0 || ended.terminationReason == .uncaughtSignal
            let status = ended.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.running = nil
                self.process = nil
                if !succeeded {
                    self.failure = self.log.last { !$0.isEmpty } ?? "It stopped with status \(status)."
                }
                finished(succeeded)
            }
        }
        running = job
        line = job.title
        log = []
        partial = ""
        failure = nil
        do {
            try process.run()
            self.process = process
        } catch {
            running = nil
            failure = error.localizedDescription
        }
    }

    /// Stop gently, the same as Ctrl-C: the Python tools save their place.
    func pause() {
        process?.interrupt()
    }

    /// Live progress rewrites one line with carriage returns.
    private func take(_ text: String) {
        partial += text
        let pieces = partial.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
        for piece in pieces.dropLast() {
            let clean = Self.withoutEscapes(String(piece)).trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                line = clean
                log.append(clean)
            }
        }
        partial = String(pieces.last ?? "")
        let current = Self.withoutEscapes(partial).trimmingCharacters(in: .whitespaces)
        if !current.isEmpty { line = current }
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private static func withoutEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
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
        hydrateElsewhere = found && running?.arguments.first != "hydrate"
        hasCheckedHydrate = true
    }
}
