import Foundation

/// The same items arranged different ways. `maps.py` makes them; each one's positions and
/// regions are stored under its own name, so they sit side by side and switching only reads.
public enum MapRecipe: String, CaseIterable, Sendable {
    case blended, words, pictures

    public static let suggested = MapRecipe.blended

    /// `layout_model` in maps.py.
    public func layoutModel(base: String) -> String {
        self == .pictures ? base : "\(base)+\(rawValue)"
    }

    public var title: String {
        switch self {
        case .blended: "blended"
        case .words: "pictures + words"
        case .pictures: "pictures"
        }
    }

    public var summary: String {
        switch self {
        case .blended: "Reads pictures and words, then draws your files in beside posts about the same thing. The most mixed, though some subjects spread out."
        case .words: "Reads pictures and words, and groups by subject. Your files tend to gather in regions of their own."
        case .pictures: "Mostly how things look, with captions counted a little. Items with pictures and items without sit apart."
        }
    }

    public var readsWords: Bool { self != .pictures }

    /// Said before anything is fetched. It's only the model's files, and only once.
    public static let wordsDownloadNote = "Downloads a text model once, about 90 MB, from Hugging Face. Nothing of yours is sent."

    /// Whether the text model is on this Mac already, where the pipeline will look for it.
    public static func wordsModelIsDownloaded(environment: [String: String] = ProcessInfo.processInfo.environment,
                                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let hub = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appending(path: "hub") }
            ?? home.appending(path: ".cache/huggingface/hub")
        let snapshots = hub.appending(path: "models--sentence-transformers--all-MiniLM-L6-v2/snapshots")
        let found = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        return found.contains { FileManager.default.fileExists(atPath: $0.appending(path: "model.safetensors").path) }
    }
}
