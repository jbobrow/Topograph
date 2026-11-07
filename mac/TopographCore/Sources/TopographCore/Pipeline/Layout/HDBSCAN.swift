import Foundation

/// HDBSCAN on points in the plane, as scikit-learn's with `cluster_selection_method="leaf"`:
/// mutual reachability, its minimum spanning tree, the condensed tree, and its leaves.
public enum HDBSCAN {
    /// For each point, the distance to its `count`th closest, counting itself as the first.
    static func coreDistances(_ xy: [Float], count: Int) -> [Float] {
        let n = xy.count / 2
        guard count > 1 else { return [Float](repeating: 0, count: n) }
        var cores = [Float](repeating: 0, count: n)
        // A grid of cells holding a few times the wanted number of points each.
        var low = (x: Float.infinity, y: Float.infinity), high = (x: -Float.infinity, y: -Float.infinity)
        for i in 0..<n {
            low = (min(low.x, xy[i * 2]), min(low.y, xy[i * 2 + 1]))
            high = (max(high.x, xy[i * 2]), max(high.y, xy[i * 2 + 1]))
        }
        let span = max(max(high.x - low.x, high.y - low.y), 1e-6)
        let side = max(1, min(4096, Int((Float(n) / Float(max(count * 2, 1))).squareRoot())))
        let cell = span / Float(side)
        func column(_ value: Float, _ origin: Float) -> Int { min(side - 1, max(0, Int((value - origin) / cell))) }
        var starts = [Int32](repeating: 0, count: side * side + 1)
        for i in 0..<n { starts[column(xy[i * 2 + 1], low.y) * side + column(xy[i * 2], low.x) + 1] += 1 }
        for index in 1..<starts.count { starts[index] += starts[index - 1] }
        var filled = starts
        var contents = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let at = column(xy[i * 2 + 1], low.y) * side + column(xy[i * 2], low.x)
            contents[Int(filled[at])] = Int32(i)
            filled[at] += 1
        }
        cores.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let target = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { i in
                let x = xy[i * 2], y = xy[i * 2 + 1]
                let cx = column(x, low.x), cy = column(y, low.y)
                var best = [Float]()
                best.reserveCapacity(count + 1)
                var ring = 0
                while true {
                    for row in max(0, cy - ring)...min(side - 1, cy + ring) {
                        let edgeRow = row == cy - ring || row == cy + ring
                        for col in max(0, cx - ring)...min(side - 1, cx + ring) where edgeRow || col == cx - ring || col == cx + ring {
                            let at = row * side + col
                            for slot in Int(starts[at])..<Int(starts[at + 1]) {
                                let other = Int(contents[slot])
                                let dx = xy[other * 2] - x, dy = xy[other * 2 + 1] - y
                                let distance = dx * dx + dy * dy
                                if best.count < count || distance < best[best.count - 1] {
                                    var position = best.count
                                    while position > 0, best[position - 1] > distance { position -= 1 }
                                    best.insert(distance, at: position)
                                    if best.count > count { best.removeLast() }
                                }
                            }
                        }
                    }
                    // Done when nothing further out could be closer.
                    let covered = Float(ring) * cell
                    if best.count == count, best[count - 1] <= covered * covered { break }
                    ring += 1
                    if ring > side { break }
                }
                target[i] = (best.last ?? 0).squareRoot()
            }
        }
        return cores
    }

    /// Prim's algorithm over mutual reachability. Sorted by distance, as (from, to, distance).
    static func spanningTree(_ xy: [Float], cores: [Float]) -> [(a: Int32, b: Int32, distance: Float)] {
        let n = xy.count / 2
        var best = [Float](repeating: .infinity, count: n)
        var source = [Int32](repeating: -1, count: n)
        var used = [Bool](repeating: false, count: n)
        var edges: [(a: Int32, b: Int32, distance: Float)] = []
        edges.reserveCapacity(n)
        var current = 0
        xy.withUnsafeBufferPointer { xy in
            cores.withUnsafeBufferPointer { cores in
                best.withUnsafeMutableBufferPointer { best in
                    source.withUnsafeMutableBufferPointer { source in
                        used.withUnsafeMutableBufferPointer { used in
                            for _ in 1..<max(n, 1) {
                                used[current] = true
                                let x = xy[current * 2], y = xy[current * 2 + 1], core = cores[current]
                                var nextIndex = -1
                                var nextValue = Float.infinity
                                for other in 0..<n where !used[other] {
                                    let dx = xy[other * 2] - x, dy = xy[other * 2 + 1] - y
                                    let reach = max(max(core, cores[other]), (dx * dx + dy * dy).squareRoot())
                                    if reach < best[other] {
                                        best[other] = reach
                                        source[other] = Int32(current)
                                    }
                                    if best[other] < nextValue {
                                        nextValue = best[other]
                                        nextIndex = other
                                    }
                                }
                                guard nextIndex >= 0 else { break }
                                edges.append((source[nextIndex], Int32(nextIndex), nextValue))
                                current = nextIndex
                            }
                        }
                    }
                }
            }
        }
        edges.sort { $0.distance < $1.distance }
        return edges
    }

    /// The final labels, -1 for noise, numbered in the order of the tree's cluster ids.
    public static func labels(_ xy: [Float], minClusterSize: Int, minSamples: Int) -> [Int] {
        let n = xy.count / 2
        guard n > 1 else { return [Int](repeating: -1, count: n) }
        let edges = spanningTree(xy, cores: coreDistances(xy, count: minSamples))

        // Single linkage: node n + i joins edge i's two sides.
        var left = [Int32](repeating: 0, count: n - 1), right = left
        var height = [Float](repeating: 0, count: n - 1)
        var sizes = [Int32](repeating: 1, count: 2 * n - 1)
        var parent = Array(Int32(0)..<Int32(2 * n - 1))
        func find(_ start: Int32) -> Int32 {
            var node = start
            while parent[Int(node)] != node {
                parent[Int(node)] = parent[Int(parent[Int(node)])]
                node = parent[Int(node)]
            }
            return node
        }
        for (index, edge) in edges.enumerated() {
            let x = find(edge.a), y = find(edge.b), joined = Int32(n + index)
            left[index] = x
            right[index] = y
            height[index] = edge.distance
            parent[Int(x)] = joined
            parent[Int(y)] = joined
            sizes[Int(joined)] = sizes[Int(x)] + sizes[Int(y)]
        }

        // The condensed tree, keeping only splits where both sides are big enough.
        struct Row { var parent: Int32; var child: Int32; var lambda: Float; var size: Int32 }
        var rows: [Row] = []
        rows.reserveCapacity(n * 2)
        let root = Int32(2 * n - 2)
        var relabel = [Int32](repeating: 0, count: 2 * n - 1)
        relabel[Int(root)] = Int32(n)
        var nextLabel = Int32(n + 1)
        func points(under node: Int32, _ visit: (Int32) -> Void) {
            var stack = [node]
            while let top = stack.popLast() {
                if Int(top) < n {
                    visit(top)
                } else {
                    stack.append(left[Int(top) - n])
                    stack.append(right[Int(top) - n])
                }
            }
        }
        var pending = [root]
        var ignored = [Bool](repeating: false, count: 2 * n - 1)
        var cursor = 0
        while cursor < pending.count {
            let node = pending[cursor]
            cursor += 1
            guard Int(node) >= n else { continue }
            let l = left[Int(node) - n], r = right[Int(node) - n]
            if !ignored[Int(node)] {
                let distance = height[Int(node) - n]
                let lambda: Float = distance > 0 ? 1 / distance : .infinity
                let leftSize = Int(sizes[Int(l)]), rightSize = Int(sizes[Int(r)])
                let label = relabel[Int(node)]
                func shed(_ side: Int32) {
                    points(under: side) { point in rows.append(Row(parent: label, child: point, lambda: lambda, size: 1)) }
                    var stack = [side]
                    while let top = stack.popLast() {
                        ignored[Int(top)] = true
                        if Int(top) >= n {
                            stack.append(left[Int(top) - n])
                            stack.append(right[Int(top) - n])
                        }
                    }
                }
                if leftSize >= minClusterSize, rightSize >= minClusterSize {
                    relabel[Int(l)] = nextLabel
                    rows.append(Row(parent: label, child: nextLabel, lambda: lambda, size: Int32(leftSize)))
                    nextLabel += 1
                    relabel[Int(r)] = nextLabel
                    rows.append(Row(parent: label, child: nextLabel, lambda: lambda, size: Int32(rightSize)))
                    nextLabel += 1
                } else if leftSize < minClusterSize, rightSize < minClusterSize {
                    shed(l)
                    shed(r)
                } else if leftSize < minClusterSize {
                    relabel[Int(r)] = label
                    shed(l)
                } else {
                    relabel[Int(l)] = label
                    shed(r)
                }
            }
            if !ignored[Int(l)] { pending.append(l) }
            if !ignored[Int(r)] { pending.append(r) }
        }

        // Leaves of the tree of clusters. If the only cluster is the root, there are none.
        var hasChildCluster = Set<Int32>()
        var clusters = Set<Int32>()
        for row in rows where row.size > 1 {
            hasChildCluster.insert(row.parent)
            clusters.insert(row.child)
        }
        let leaves = clusters.subtracting(hasChildCluster)
        guard !leaves.isEmpty else { return [Int](repeating: -1, count: n) }
        let numbers = Dictionary(uniqueKeysWithValues: leaves.sorted().enumerated().map { ($0.element, $0.offset) })

        // Every point of a leaf cluster gets its label; anything else that fell out is noise.
        var labels = [Int](repeating: -1, count: n)
        for row in rows where row.size == 1 {
            if let number = numbers[row.parent] { labels[Int(row.child)] = number }
        }
        return labels
    }

    /// Fine regions for a map, as `layout.cluster`: noise joins its nearest region, unless it's
    /// far from everything.
    public static func regions(_ xy: [Float]) -> [Int] {
        let n = xy.count / 2
        if n < 10 { return [Int](repeating: 0, count: n) }
        let minSize = max(12, n / 350)
        var found = labels(xy, minClusterSize: minSize, minSamples: max(3, minSize / 3))
        let placed = found.indices.filter { found[$0] >= 0 }
        if placed.isEmpty { return [Int](repeating: 0, count: n) }
        let noise = found.indices.filter { found[$0] < 0 }
        if noise.isEmpty { return found }
        var nearest = [Int](repeating: 0, count: noise.count)
        var distance = [Float](repeating: 0, count: noise.count)
        nearest.withUnsafeMutableBufferPointer { nearest in
            distance.withUnsafeMutableBufferPointer { distance in
                nonisolated(unsafe) let nearestOut = nearest.baseAddress!
                nonisolated(unsafe) let distanceOut = distance.baseAddress!
                DispatchQueue.concurrentPerform(iterations: noise.count) { position in
                    let x = xy[noise[position] * 2], y = xy[noise[position] * 2 + 1]
                    var best = Float.infinity, which = 0
                    for candidate in placed {
                        let dx = xy[candidate * 2] - x, dy = xy[candidate * 2 + 1] - y
                        let squared = dx * dx + dy * dy
                        if squared < best {
                            best = squared
                            which = candidate
                        }
                    }
                    nearestOut[position] = which
                    distanceOut[position] = best.squareRoot()
                }
            }
        }
        let cutoff = distance.count > 3 ? VectorMath.percentile(distance, 75) * 2 : .infinity
        for position in noise.indices where distance[position] <= cutoff {
            found[noise[position]] = found[nearest[position]]
        }
        return found
    }
}
