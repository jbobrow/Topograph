import Foundation

/// The viewer's three kinds of action, which you can turn on and off.
public struct ActionGroups: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let made = ActionGroups(rawValue: 1)
    public static let liked = ActionGroups(rawValue: 2)
    public static let kept = ActionGroups(rawValue: 4)
    public static let all: ActionGroups = [.made, .liked, .kept]

    public init(types: some Sequence<String>) {
        self = []
        for type in types {
            switch type {
            case "post", "repost", "reply", "comment", "made", "capture": insert(.made)
            case "like", "react": insert(.liked)
            case "save", "bookmark", "download": insert(.kept)
            default: break
            }
        }
    }
}

/// Which items are showing. Everything showing by default.
public struct MapFilter: Sendable, Equatable {
    /// Platforms turned off. Kept as what's off so a new platform shows by default.
    public var hiddenPlatforms: Set<String> = []
    public var groups: ActionGroups = .all
    /// Lowercase words to find in the text or as an @author.
    public var query = ""
    /// Unix seconds. Items with no time are hidden while a range is set.
    public var range: ClosedRange<Int>?

    public init() {}

    public func matches(_ item: MapItem) -> Bool {
        if hiddenPlatforms.contains(item.platform) { return false }
        // An item with only quiet actions, like opening a file, has no group to turn off.
        if !item.groups.isEmpty && item.groups.isDisjoint(with: groups) { return false }
        if let range {
            guard let time = item.time, range.contains(time) else { return false }
        }
        return true
    }

    /// The items showing. With a query, `search` finds the words; it's built once per map
    /// because scanning every caption afresh is too slow to do as you type.
    public func visible(in items: [MapItem], search: SearchIndex) -> [Int32] {
        let found = query.isEmpty ? nil : search.matches(query)
        var out: [Int32] = []
        out.reserveCapacity(found?.count ?? items.count)
        if let found {
            for index in found where matches(items[Int(index)]) { out.append(index) }
        } else {
            for index in items.indices where matches(items[index]) { out.append(Int32(index)) }
        }
        return out
    }
}

/// Every item's text and @author, lowercased, in one buffer that can be scanned quickly.
public struct SearchIndex: Sendable {
    private let bytes: [UInt8]
    /// Where each item's text starts.
    private let starts: [Int]

    public init(items: [MapItem]) {
        var bytes: [UInt8] = []
        var starts: [Int] = []
        starts.reserveCapacity(items.count)
        for item in items {
            starts.append(bytes.count)
            if let text = item.text { bytes.append(contentsOf: text.lowercased().utf8) }
            if let author = item.author {
                bytes.append(0x20)
                bytes.append(0x40)
                bytes.append(contentsOf: author.lowercased().utf8)
            }
            bytes.append(0)     // no query can match across two items
        }
        self.bytes = bytes
        self.starts = starts
    }

    /// Indexes of the items holding `query`, in order, each once.
    public func matches(_ query: String) -> [Int32] {
        let needle = Array(query.lowercased().utf8)
        guard !needle.isEmpty, !bytes.isEmpty else { return [] }
        var out: [Int32] = []
        bytes.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                let base = hay.baseAddress!
                var offset = 0
                var item = 0
                while offset < hay.count,
                      let hit = memmem(base + offset, hay.count - offset, pin.baseAddress!, pin.count) {
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    while item + 1 < starts.count, starts[item + 1] <= at { item += 1 }
                    out.append(Int32(item))
                    // Carry on from the next item.
                    guard item + 1 < starts.count else { break }
                    offset = starts[item + 1]
                }
            }
        }
        return out
    }
}

/// Finds the nearest item to a point on the map.
public struct SpatialIndex: Sendable {
    private static let columns = 64
    private let cellSize = Float(DensityField.mapSize) / Float(columns)
    private var cells: [[Int32]]
    private let positions: [SIMD2<Float>]

    public init(items: [MapItem], visible: [Int32]) {
        cells = Array(repeating: [], count: Self.columns * Self.columns)
        positions = items.map { SIMD2($0.x, $0.y) }
        for index in visible {
            cells[cell(positions[Int(index)])].append(index)
        }
    }

    private func cell(_ p: SIMD2<Float>) -> Int {
        coordinate(p.x) + coordinate(p.y) * Self.columns
    }

    private func coordinate(_ value: Float) -> Int {
        min(max(Int(value / cellSize), 0), Self.columns - 1)
    }

    /// The nearest item within `radius` map units, if there is one.
    public func nearest(x: Double, y: Double, radius: Double) -> Int32? {
        let point = SIMD2(Float(x), Float(y))
        let reach = Float(radius)
        let x0 = coordinate(point.x - reach), x1 = coordinate(point.x + reach)
        let y0 = coordinate(point.y - reach), y1 = coordinate(point.y + reach)
        var best: Int32?
        var bestDistance = reach * reach
        for row in y0...y1 {
            for column in x0...x1 {
                for index in cells[column + row * Self.columns] {
                    let d = positions[Int(index)] - point
                    let distance = d.x * d.x + d.y * d.y
                    if distance <= bestDistance {
                        bestDistance = distance
                        best = index
                    }
                }
            }
        }
        return best
    }
}
