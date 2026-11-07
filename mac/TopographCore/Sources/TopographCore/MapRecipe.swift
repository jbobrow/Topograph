import Foundation

/// The same items arranged different ways. `MapBuilder` makes them; each one's positions and
/// regions are stored under its own name, so they sit side by side and switching only reads.
public enum MapRecipe: String, CaseIterable, Sendable {
    case blended, words, pictures

    public static let suggested = MapRecipe.blended

    /// Pictures keeps the plain name it has always had.
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
}
