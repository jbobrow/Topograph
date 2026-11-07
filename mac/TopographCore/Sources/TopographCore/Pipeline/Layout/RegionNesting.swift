import Foundation

/// A region of the map while it's being built: which items it holds, where it sits in the
/// tree, and what it's called. See regions.py.
public struct BuiltRegion: Sendable {
    public var id: Int
    public var members: [Int]
    public var children: [Int] = []
    public var parent: Int?
    public var depth = 0
    public var label = ""
    public var terms: [String] = []
    public var score = 0.0
}

public enum RegionNesting {
    /// Ward linkage on points. Returns the merges in the order they happened, as positions in
    /// the original list and new nodes numbered from `count` up, like SciPy's.
    static func wardMerges(_ points: [(x: Double, y: Double)]) -> [(a: Int, b: Int)] {
        let count = points.count
        var alive = Array(0..<count)
        var node = Array(0..<count)
        var size = [Double](repeating: 1, count: count)
        var distance = [Double](repeating: 0, count: count * count)
        for i in 0..<count {
            for j in 0..<count {
                let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                distance[i * count + j] = (dx * dx + dy * dy).squareRoot()
            }
        }
        var merges: [(a: Int, b: Int)] = []
        var next = count
        while alive.count > 1 {
            var best = Double.infinity, x = 0, y = 0
            for (position, i) in alive.enumerated() {
                for j in alive[(position + 1)...] where distance[i * count + j] < best {
                    best = distance[i * count + j]
                    (x, y) = (i, j)
                }
            }
            merges.append((node[x], node[y]))
            let joined = size[x] + size[y]
            for k in alive where k != x && k != y {
                let dxk = distance[x * count + k], dyk = distance[y * count + k]
                let value = (((size[x] + size[k]) * dxk * dxk + (size[y] + size[k]) * dyk * dyk - size[k] * best * best) / (joined + size[k])).squareRoot()
                distance[x * count + k] = value
                distance[k * count + x] = value
            }
            size[x] = joined
            node[x] = next
            next += 1
            alive.removeAll { $0 == y }
        }
        return merges
    }

    /// Which group each point falls in when the merges stop at `target` groups (`fcluster`'s
    /// "maxclust"), numbered from 0 in the order the points first show each group.
    static func flat(_ merges: [(a: Int, b: Int)], count: Int, target: Int) -> [Int] {
        var parent = Array(0..<(count * 2))
        func find(_ start: Int) -> Int {
            var node = start
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        for (index, merge) in merges.prefix(max(0, count - target)).enumerated() {
            let joined = count + index
            parent[find(merge.a)] = joined
            parent[find(merge.b)] = joined
        }
        var numbers: [Int: Int] = [:]
        return (0..<count).map { point in
            let root = find(point)
            if let number = numbers[root] { return number }
            numbers[root] = numbers.count
            return numbers[root]!
        }
    }

    /// Nest the finest regions (a label per item, -1 for none) into larger ones. Leaf ids are
    /// the labels, and merged regions get new ids above them.
    public static func build(xy: [Float], leaf: [Int], top: Int = 7, branching: Double = 3) -> (regions: [Int: BuiltRegion], roots: [Int]) {
        let leaves = Set(leaf).subtracting([-1]).sorted()
        var members: [Int: [Int]] = [:]
        for (item, label) in leaf.enumerated() where label != -1 { members[label, default: []].append(item) }
        var regions: [Int: BuiltRegion] = [:]
        for label in leaves { regions[label] = BuiltRegion(id: label, members: members[label] ?? []) }
        var roots = leaves
        if leaves.count > top + 2 {
            let centers = leaves.map { label -> (x: Double, y: Double) in
                let inside = members[label] ?? []
                var x = 0.0, y = 0.0
                for item in inside {
                    x += Double(xy[item * 2])
                    y += Double(xy[item * 2 + 1])
                }
                let count = Double(max(inside.count, 1))
                return (x / count, y / count)
            }
            let merges = wardMerges(centers)
            var targets: [Int] = []
            var scale = Double(top)
            while scale * 1.8 < Double(leaves.count) {
                targets.append(Int(scale.rounded(.toNearestOrEven)))
                scale *= branching
            }
            var current = Dictionary(uniqueKeysWithValues: leaves.map { ($0, $0) })    // leaf -> region standing for it here
            var nextID = (leaves.last ?? -1) + 1
            for target in targets.reversed() {          // finest merge first
                let groups = flat(merges, count: leaves.count, target: target)
                var merged: [Int: Int] = [:]
                for group in 0...(groups.max() ?? 0) {
                    let inside = leaves.indices.filter { groups[$0] == group }.map { leaves[$0] }
                    let kids = Set(inside.compactMap { current[$0] }).sorted()
                    let id: Int
                    if kids.count == 1 {
                        id = kids[0]
                    } else {
                        id = nextID
                        nextID += 1
                        regions[id] = BuiltRegion(id: id, members: kids.flatMap { regions[$0]?.members ?? [] }, children: kids)
                        for kid in kids { regions[kid]?.parent = id }
                    }
                    for label in inside { merged[label] = id }
                }
                current = merged
            }
            roots = Set(current.values).sorted()
        }
        func setDepth(_ id: Int, _ depth: Int) {
            regions[id]?.depth = depth
            for kid in regions[id]?.children ?? [] { setDepth(kid, depth + 1) }
        }
        for root in roots { setDepth(root, 0) }
        return (regions, roots)
    }

    /// Where a region's name goes (the member nearest its median) and its size.
    public static func anchor(xy: [Float], members: [Int]) -> (x: Double, y: Double, r: Double) {
        guard !members.isEmpty else { return (0, 0, 4) }
        let medianX = VectorMath.median(members.map { xy[$0 * 2] }), medianY = VectorMath.median(members.map { xy[$0 * 2 + 1] })
        var best = Float.infinity, chosen = members[0]
        var sumX = 0.0, sumY = 0.0
        for item in members {
            let dx = xy[item * 2] - medianX, dy = xy[item * 2 + 1] - medianY
            let squared = dx * dx + dy * dy
            if squared < best {
                best = squared
                chosen = item
            }
            sumX += Double(xy[item * 2])
            sumY += Double(xy[item * 2 + 1])
        }
        var radius = 4.0
        if members.count > 1 {
            let centerX = sumX / Double(members.count), centerY = sumY / Double(members.count)
            var total = 0.0
            for item in members {
                let dx = Double(xy[item * 2]) - centerX, dy = Double(xy[item * 2 + 1]) - centerY
                total += dx * dx + dy * dy
            }
            radius = max((total / Double(members.count)).squareRoot(), 4)
        }
        return (Double(xy[chosen * 2]), Double(xy[chosen * 2 + 1]), radius)
    }
}
