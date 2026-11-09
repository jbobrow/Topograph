import CoreGraphics
import Foundation

public struct Region: Sendable, Identifiable {
    public let id: Int
    public let label: String
    public let terms: [String]
    public let parent: Int?
    /// Where its name goes on the map.
    public let x: Double
    public let y: Double
    /// Its size: the rms distance of its members from its center.
    public let r: Double
    public let depth: Int
    /// Largest first.
    public let children: [Int]
    /// From the top of the tree down to this region.
    public let path: [Int]
    /// Everything inside it, including inside the regions it holds.
    public let count: Int

    func withLabel(_ label: String) -> Region {
        Region(id: id, label: label, terms: terms, parent: parent, x: x, y: y, r: r, depth: depth,
               children: children, path: path, count: count)
    }
}

/// Regions nest: large ones when zoomed out, the ones inside them as you zoom in.
public struct RegionTree: Sendable {
    public struct Record: Sendable {
        public let id: Int
        public let label: String
        public let terms: [String]
        public let parent: Int?
        public let x: Double?
        public let y: Double?
        public let r: Double?

        public init(id: Int, label: String, terms: [String] = [], parent: Int? = nil, x: Double? = nil, y: Double? = nil, r: Double? = nil) {
            self.id = id
            self.label = label
            self.terms = terms
            self.parent = parent
            self.x = x
            self.y = y
            self.r = r
        }
    }

    public let regions: [Int: Region]
    /// Largest first.
    public let roots: [Int]
    private let own: [Int: [Int32]]

    public init(records: [Record], items: [MapItem]) {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kids: [Int: [Int]] = [:]
        var tops: [Int] = []
        for record in records {
            if let parent = record.parent, byID[parent] != nil {
                kids[parent, default: []].append(record.id)
            } else {
                tops.append(record.id)
            }
        }
        var own: [Int: [Int32]] = [:]
        for index in items.indices {
            if let region = items[index].region, byID[region] != nil { own[region, default: []].append(Int32(index)) }
        }

        var built: [Int: Region] = [:]
        var members: [Int: [Int32]] = [:]
        @discardableResult
        func settle(_ id: Int, path: [Int]) -> [Int32] {
            let record = byID[id]!
            let here = path + [id]
            var inside = own[id] ?? []
            for child in kids[id] ?? [] { inside += settle(child, path: here) }
            members[id] = inside
            let sorted = (kids[id] ?? []).sorted { (members[$0]?.count ?? 0) > (members[$1]?.count ?? 0) }

            // Maps built before regions nested have no anchors of their own.
            var (x, y, r) = (record.x, record.y, record.r)
            if x == nil || y == nil || r == nil {
                let spot = RegionTree.anchor(of: inside, items: items)
                x = spot.x
                y = spot.y
                r = spot.r
            }
            built[id] = Region(id: id, label: record.label, terms: record.terms, parent: path.last,
                               x: x!, y: y!, r: r!, depth: path.count, children: sorted, path: here, count: inside.count)
            return inside
        }
        for top in tops { settle(top, path: []) }
        regions = built
        roots = tops.sorted { (built[$0]?.count ?? 0) > (built[$1]?.count ?? 0) }
        self.own = own
    }

    init(regions: [Int: Region], roots: [Int], base: RegionTree) {
        self.regions = regions
        self.roots = roots
        own = base.own
    }

    /// The member nearest the middle, and the spread around it.
    private static func anchor(of members: [Int32], items: [MapItem]) -> (x: Double, y: Double, r: Double) {
        guard !members.isEmpty else { return (500, 500, 4) }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let xs = members.map { Double(items[Int($0)].x) }, ys = members.map { Double(items[Int($0)].y) }
        let mx = median(xs), my = median(ys)
        let nearest = members.indices.min { a, b in
            (xs[a] - mx) * (xs[a] - mx) + (ys[a] - my) * (ys[a] - my) < (xs[b] - mx) * (xs[b] - mx) + (ys[b] - my) * (ys[b] - my)
        }!
        let cx = xs.reduce(0, +) / Double(xs.count), cy = ys.reduce(0, +) / Double(ys.count)
        let spread = zip(xs, ys).reduce(0) { $0 + ($1.0 - cx) * ($1.0 - cx) + ($1.1 - cy) * ($1.1 - cy) } / Double(xs.count)
        return (xs[nearest], ys[nearest], max(4, spread.squareRoot()))
    }

    /// Item indexes inside a region, however deep.
    public func members(of id: Int) -> [Int32] {
        guard let region = regions[id] else { return [] }
        return region.children.reduce(own[id] ?? []) { $0 + members(of: $1) }
    }

    /// How many of the visible items sit inside each region.
    public func counts(items: [MapItem], visible: [Int32]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for index in visible {
            guard let region = items[Int(index)].region, let path = regions[region]?.path else { continue }
            for id in path { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// A cut through the tree with few enough layers to read: the largest regions are
    /// split into the regions inside them while that fits. Largest first.
    public func strataLayers(maxLayers: Int = 16) -> [Int] {
        var cut = roots
        while true {
            let open = cut
                .filter { !(regions[$0]?.children.isEmpty ?? true) && cut.count - 1 + regions[$0]!.children.count <= maxLayers }
                .max { (regions[$0]?.count ?? 0) < (regions[$1]?.count ?? 0) }
            guard let open, let at = cut.firstIndex(of: open) else { break }
            cut.replaceSubrange(at...at, with: regions[open]!.children)
        }
        return cut.sorted { (regions[$0]?.count ?? 0) > (regions[$1]?.count ?? 0) }
    }
}

/// One region's name, placed on screen.
public struct PlacedLabel: Sendable, Equatable {
    public let id: Int
    /// The anchor, where the crosshair goes.
    public let x: Double
    public let y: Double
    public let top: Bool
    public let fontSize: Double
    public let count: Int
    /// The whole label, crosshair included.
    public let box: CGRect

    public static func geometry(id: Int, x: Double, y: Double, top: Bool, count: Int,
                                nameWidth: Double, countWidth: Double) -> PlacedLabel {
        let fontSize: Double = top ? 12 : 11
        let textX = x + 8
        let total = nameWidth + 6 + countWidth
        let box = CGRect(x: x - 5, y: y - fontSize / 2 - 3, width: textX + total + 4 - (x - 5), height: fontSize + 6)
        return PlacedLabel(id: id, x: x, y: y, top: top, fontSize: fontSize, count: count, box: box)
    }
}

/// Which regions are named depends on zoom: a region hands over to the regions inside
/// it once it is large on screen, and the finest regions step aside once you are well
/// inside them. A port of `namedRegions` and `drawLabels` in viewer/app.js.
public struct LabelPlanner: Sendable {
    /// Regions opened up at the current zoom. They're what the where-you-are bar shows.
    public private(set) var expanded: Set<Int> = []

    public init() {}

    /// A region this large (rms radius, points) opens up.
    public static func expandAt(_ size: CGSize) -> Double { min(size.width, size.height) * 0.3 }

    private static func pastAt(_ size: CGSize) -> Double { max(size.width, size.height) * 0.75 }

    /// The regions that want a name at this zoom.
    public mutating func named(tree: RegionTree, counts: [Int: Int], transform: MapTransform, size: CGSize) -> [Int] {
        named(tree: tree, counts: counts, size: size) { region in
            (CGPoint(x: region.x * transform.k + transform.x, y: region.y * transform.k + transform.y), transform.k)
        }
    }

    /// The same, wherever a region's anchor lands on screen and at whatever scale it's seen
    /// there (points per map unit), as in 3D, where nearer regions open up first. `locate`
    /// returns nil for a region that can't be seen at all.
    public mutating func named(tree: RegionTree, counts: [Int: Int], size: CGSize,
                               locate: (Region) -> (point: CGPoint, k: Double)?) -> [Int] {
        let open = Self.expandAt(size), past = Self.pastAt(size)
        var out: [Int] = []
        func visit(_ id: Int) {
            guard let region = tree.regions[id], (counts[id] ?? 0) > 0 else { return }
            guard let (at, k) = locate(region) else {
                expanded.remove(id)
                return
            }
            let onScreen = region.r * k
            let reach = onScreen * 3 + 120
            if at.x + reach < 0 || at.x - reach > size.width || at.y + reach < 0 || at.y - reach > size.height { return }
            let limit = region.children.isEmpty ? past : open
            // A little hysteresis so a name doesn't flicker at the threshold.
            let isOpen = expanded.contains(id) ? onScreen > limit * 0.85 : onScreen > limit
            if isOpen {
                expanded.insert(id)
                region.children.forEach(visit)
            } else {
                expanded.remove(id)
                out.append(id)
            }
        }
        tree.roots.forEach(visit)
        return out
    }

    /// Bigger regions claim their spot first, and a name that would overlap is hidden.
    /// Widths come from the caller, which knows the font.
    public mutating func plan(tree: RegionTree, counts: [Int: Int], transform: MapTransform, size: CGSize,
                              width: (String, Double) -> Double) -> [PlacedLabel] {
        plan(tree: tree, counts: counts, size: size, width: width) { region in
            (CGPoint(x: region.x * transform.k + transform.x, y: region.y * transform.k + transform.y), transform.k)
        }
    }

    /// The same, with anchors and scales from `locate`, as `named(tree:counts:size:locate:)` takes them.
    public mutating func plan(tree: RegionTree, counts: [Int: Int], size: CGSize, width: (String, Double) -> Double,
                              locate: (Region) -> (point: CGPoint, k: Double)?) -> [PlacedLabel] {
        var anchors: [Int: CGPoint] = [:]
        let wanted = named(tree: tree, counts: counts, size: size) { region in
            guard let found = locate(region) else { return nil }
            anchors[region.id] = found.point
            return found
        }.sorted {
            let a = tree.regions[$0]!, b = tree.regions[$1]!
            return a.depth != b.depth ? a.depth < b.depth : a.count > b.count
        }
        var placed: [PlacedLabel] = []
        let screen = CGRect(origin: .zero, size: size)
        for id in wanted {
            guard let region = tree.regions[id], let at = anchors[id] else { continue }
            let count = counts[id] ?? 0
            let top = region.depth == 0
            let label = PlacedLabel.geometry(
                id: id, x: at.x, y: at.y, top: top,
                count: count, nameWidth: width(region.label, top ? 12 : 11), countWidth: width(count.formatted(), 10))
            guard label.box.intersects(screen) else { continue }
            if placed.contains(where: { $0.box.intersects(label.box) }) { continue }
            placed.append(label)
        }
        return placed
    }
}
