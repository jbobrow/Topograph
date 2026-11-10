import Foundation
import TopographCore

// The Swift pipeline from the command line, with the same words as `topograph`, for trying it
// on a throwaway library: TOPOGRAPH_LIBRARY=/tmp/try swift run topograph-native import some.zip

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: topograph-native import|files|hydrate|sync|build|same|layout ...")
    exit(2)
}
let flags = Set(arguments.dropFirst().filter { $0.hasPrefix("--") })
let values = arguments.dropFirst().filter { !$0.hasPrefix("--") }

let reporter = PipelineReporter(progress: { line in
    print("\u{1B}[2K\r\(line)", terminator: "")
    fflush(stdout)
}, say: { line in
    print("\u{1B}[2K\r\(line)")
})

do {
    let library = try LibraryWriter()
    switch command {
    case "import":
        try Pipeline.importArchives(values.map { URL(fileURLWithPath: $0) }, library: library, reporter: reporter)
    case "files":
        try Pipeline.readFiles(values, dryRun: flags.contains("--dry-run"), fixDates: flags.contains("--fix-dates"), library: library, reporter: reporter)
    case "hydrate":
        let platforms = values.first.map { Set([$0]) }
        try Pipeline.hydrate(library: library, platforms: platforms, limit: values.dropFirst().first.flatMap(Int.init), reporter: reporter)
    case "sync":
        try Pipeline.sync(source: values[0], account: values[1], library: library, reporter: reporter)
    case "build":
        let recipe = values.first.flatMap(MapRecipe.init(rawValue:))
        try MapBuilder.build(recipe: recipe, library: library, force: flags.contains("--force"), reporter: reporter)
    case "same":
        try SamePictures.find(library: library, reporter: reporter)
    case "layout":
        let recipe = try MapBuilder.chosenMap(values.first.flatMap(MapRecipe.init(rawValue:)), library: library)
        try MapBuilder.computeLayout(library: library, recipe: recipe, clip: try CLIPEncoder(), reporter: reporter)
    case "list-files":
        // Every decision, for comparing with the Python tools. Goes to a file, as it names files.
        var report = FilesReport()
        var lines: [String] = []
        _ = FilesImporter.collect(roots: values.dropFirst().map { $0 }, options: .init(), report: &report, onDecision: { lines.append("\($1)\t\($0)") })
        try lines.sorted().joined(separator: "\n").write(toFile: values[0], atomically: true, encoding: .utf8)
    case "check-regions":
        try checkRegions(library: library, map: values.first ?? "blended")
    case "check-palette":
        try checkPalette(library: library)
    case "check-clouds":
        try checkClouds(endingAt: values.first)
    case "check-words":
        try checkWords(library: library)
    default:
        print("unknown command \(command)")
        exit(2)
    }
} catch {
    print("\n\(error.localizedDescription)")
    exit(1)
}
