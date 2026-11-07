import Foundation

/// UMAP to two dimensions, as `umap-learn` does it with cosine distance, 30 neighbors and
/// min_dist 0.05, except that neighbors are found exactly. A Swift map isn't the same picture
/// as a Python one, since their random numbers differ: judge it by eye and by whether near
/// things stay near, not by coordinates.
public enum UMAP {
    // umap.umap_.find_ab_params(spread=1, min_dist=0.05)
    private static let a: Float = 1.750224963102406
    private static let b: Float = 0.8420553926413736
    private static let negativeSamples = 5
    private static let gamma: Float = 1

    /// A sparse symmetric graph, as coordinate lists.
    struct Graph {
        var n: Int
        var head: [Int32]
        var tail: [Int32]
        var weight: [Float]
    }

    /// `smooth_knn_dist`: for each item, the distance to its nearest other (rho) and a scale
    /// so that its neighbors' weights sum to log2(k).
    static func smoothDistances(_ neighbors: VectorMath.Neighbors, n: Int) -> (sigma: [Float], rho: [Float]) {
        let k = neighbors.k
        let target = log2(Double(k))
        let tolerance = 1e-5, minScale = 1e-3
        var overall = 0.0
        for distance in neighbors.distances { overall += Double(distance) }
        overall /= Double(max(neighbors.distances.count, 1))
        var sigmas = [Float](repeating: 0, count: n), rhos = [Float](repeating: 0, count: n)
        for item in 0..<n {
            let line = neighbors.distances[(item * k)..<((item + 1) * k)]
            let nonzero = line.filter { $0 > 0 }
            let rho = Double(nonzero.first ?? 0)
            var low = 0.0, high = Double.infinity, middle = 1.0
            for _ in 0..<64 {
                var sum = 0.0
                for distance in line.dropFirst() {
                    let excess = Double(distance) - rho
                    sum += excess > 0 ? exp(-(excess / middle)) : 1
                }
                if abs(sum - target) < tolerance { break }
                if sum > target {
                    high = middle
                    middle = (low + high) / 2
                } else {
                    low = middle
                    middle = high == .infinity ? middle * 2 : (low + high) / 2
                }
            }
            var sigma = middle
            if rho > 0 {
                let mean = nonzero.reduce(0.0) { $0 + Double($1) } / Double(nonzero.count)
                sigma = max(sigma, minScale * mean)
            } else {
                sigma = max(sigma, minScale * overall)
            }
            sigmas[item] = Float(sigma)
            rhos[item] = Float(rho)
        }
        return (sigmas, rhos)
    }

    /// `fuzzy_simplicial_set`: neighbor weights made symmetric by a + b − ab.
    static func fuzzyGraph(_ neighbors: VectorMath.Neighbors, n: Int) -> Graph {
        let k = neighbors.k
        let (sigmas, rhos) = smoothDistances(neighbors, n: n)
        var outgoing = [[(to: Int32, weight: Float)]](repeating: [], count: n)
        for item in 0..<n {
            outgoing[item].reserveCapacity(k)
            for position in 0..<k {
                let other = neighbors.indices[item * k + position]
                if Int(other) == item { continue }
                let excess = neighbors.distances[item * k + position] - rhos[item]
                let weight: Float = excess <= 0 || sigmas[item] == 0 ? 1 : exp(-excess / sigmas[item])
                outgoing[item].append((other, weight))
            }
        }
        var graph = Graph(n: n, head: [], tail: [], weight: [])
        graph.head.reserveCapacity(n * k * 2)
        graph.tail.reserveCapacity(n * k * 2)
        graph.weight.reserveCapacity(n * k * 2)
        for item in 0..<n {
            for edge in outgoing[item] where edge.weight > 0 {
                let other = Int(edge.to)
                let back = outgoing[other].first { Int($0.to) == item }?.weight ?? 0
                // Each pair once from each side, so a pair known to both isn't counted twice.
                if back > 0, other < item { continue }
                let joined = edge.weight + back - edge.weight * back
                if joined <= 0 { continue }
                graph.head.append(Int32(item))
                graph.tail.append(edge.to)
                graph.weight.append(joined)
                graph.head.append(edge.to)
                graph.tail.append(Int32(item))
                graph.weight.append(joined)
            }
        }
        return graph
    }

    /// Which connected group each item is in.
    static func components(_ graph: Graph) -> (count: Int, labels: [Int32]) {
        var parent = Array(Int32(0)..<Int32(graph.n))
        func find(_ start: Int32) -> Int32 {
            var node = start
            while parent[Int(node)] != node {
                parent[Int(node)] = parent[Int(parent[Int(node)])]
                node = parent[Int(node)]
            }
            return node
        }
        for edge in graph.head.indices {
            let x = find(graph.head[edge]), y = find(graph.tail[edge])
            if x != y { parent[Int(x)] = y }
        }
        var numbers: [Int32: Int32] = [:]
        var labels = [Int32](repeating: 0, count: graph.n)
        for item in 0..<graph.n {
            let root = find(Int32(item))
            if numbers[root] == nil { numbers[root] = Int32(numbers.count) }
            labels[item] = numbers[root]!
        }
        return (numbers.count, labels)
    }

    /// The two lowest non-trivial eigenvectors of the graph's normalized Laplacian (the same as
    /// the highest of D^-½ A D^-½, below its top one), by Lanczos with full reorthogonalization.
    /// Only a starting point for the layout, so a little inexactness is harmless.
    static func spectral(_ graph: Graph, random: inout SeededRandom) -> [Double] {
        let n = graph.n
        var degree = [Double](repeating: 0, count: n)
        for edge in graph.head.indices { degree[Int(graph.head[edge])] += Double(graph.weight[edge]) }
        let root = degree.map { $0.squareRoot() }
        let inverse = root.map { $0 > 0 ? 1 / $0 : 0 }
        let rootLength = root.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let top = root.map { $0 / max(rootLength, 1e-300) }

        func multiply(_ x: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: n)
            x.withUnsafeBufferPointer { x in
                out.withUnsafeMutableBufferPointer { out in
                    for edge in graph.head.indices {
                        let from = Int(graph.head[edge]), to = Int(graph.tail[edge])
                        out[from] += Double(graph.weight[edge]) * inverse[from] * inverse[to] * x[to]
                    }
                }
            }
            return out
        }
        func dot(_ x: [Double], _ y: [Double]) -> Double {
            var sum = 0.0
            for index in 0..<n { sum += x[index] * y[index] }
            return sum
        }

        let steps = min(n - 1, max(60, min(300, Int(Double(n).squareRoot()) * 2)))
        var basis: [[Double]] = []
        var alpha: [Double] = [], beta: [Double] = []
        var current = (0..<n).map { _ in random.normal() }
        let projected = dot(current, top)
        for index in 0..<n { current[index] -= projected * top[index] }
        var length = dot(current, current).squareRoot()
        for index in 0..<n { current[index] /= max(length, 1e-300) }
        for step in 0..<steps {
            basis.append(current)
            var next = multiply(current)
            alpha.append(dot(next, current))
            // Twice through, against the top vector and every vector so far.
            for _ in 0..<2 {
                let onTop = dot(next, top)
                for index in 0..<n { next[index] -= onTop * top[index] }
                for vector in basis {
                    let along = dot(next, vector)
                    for index in 0..<n { next[index] -= along * vector[index] }
                }
            }
            length = dot(next, next).squareRoot()
            if length < 1e-10 || step == steps - 1 { break }
            beta.append(length)
            for index in 0..<n { next[index] /= length }
            current = next
        }
        let m = basis.count
        var table = [Double](repeating: 0, count: m * m)
        for i in 0..<m {
            table[i * m + i] = alpha[i]
            if i + 1 < m, i < beta.count {
                table[i * m + i + 1] = beta[i]
                table[(i + 1) * m + i] = beta[i]
            }
        }
        let (_, vectors) = VectorMath.symmetricEigen(table, n: m)
        var out = [Double](repeating: 0, count: n * 2)
        for dimension in 0..<2 where dimension < m {
            for step in 0..<m {
                let weight = vectors[step * m + dimension]
                let vector = basis[step]
                for index in 0..<n { out[index * 2 + dimension] += weight * vector[index] }
            }
        }
        return out
    }

    /// Where each connected group sits: pulled from the affinity of their centers, as
    /// `component_layout` does, or corners of a square when there are only a few.
    private static func groupPlaces(count: Int, labels: [Int32], vectors: Matrix) -> [Double] {
        if count <= 4 {
            let corners: [Double] = [1, 0, 0, 1, -1, 0, 0, -1]
            return Array(corners.prefix(count * 2))
        }
        var members = [[Int]](repeating: [], count: count)
        for item in labels.indices { members[Int(labels[item])].append(item) }
        let centers = Matrix(rows: count, columns: vectors.columns, values: members.flatMap { vectors.mean(of: $0) }).unitRows
        let similarity = centers.product(transposeOf: centers)
        var affinity = [Double](repeating: 0, count: count * count)
        for i in 0..<(count * count) {
            let distance = 1 - Double(similarity.values[i])
            affinity[i] = exp(-(distance * distance))
        }
        var degree = [Double](repeating: 0, count: count)
        for i in 0..<count { for j in 0..<count { degree[i] += affinity[i * count + j] } }
        var normalized = affinity
        for i in 0..<count { for j in 0..<count { normalized[i * count + j] /= (degree[i] * degree[j]).squareRoot() } }
        let (_, eigen) = VectorMath.symmetricEigen(normalized, n: count)
        var places = [Double](repeating: 0, count: count * 2)
        var largest = 1e-12
        for i in 0..<count {
            places[i * 2] = eigen[i * count + 1]
            places[i * 2 + 1] = eigen[i * count + 2]
            largest = max(largest, abs(places[i * 2]), abs(places[i * 2 + 1]))
        }
        return places.map { $0 / largest }
    }

    private static func initial(_ graph: Graph, vectors: Matrix, random: inout SeededRandom) -> [Float] {
        let (count, labels) = components(graph)
        let n = graph.n
        var coordinates: [Double]
        if count == 1 {
            coordinates = spectral(graph, random: &random)
        } else {
            let places = groupPlaces(count: count, labels: labels, vectors: vectors)
            var smallest = Double.infinity
            for i in 0..<count {
                for j in (i + 1)..<max(count, i + 1) {
                    let dx = places[i * 2] - places[j * 2], dy = places[i * 2 + 1] - places[j * 2 + 1]
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance > 0 { smallest = min(smallest, distance) }
                }
            }
            let range = smallest.isFinite ? smallest / 2 : 1
            coordinates = [Double](repeating: 0, count: n * 2)
            var members = [[Int]](repeating: [], count: count)
            for item in 0..<n { members[Int(labels[item])].append(item) }
            for group in 0..<count {
                let inside = members[group]
                if inside.count < 4 {
                    for item in inside {
                        coordinates[item * 2] = places[group * 2] + (random.uniform() * 2 - 1) * range
                        coordinates[item * 2 + 1] = places[group * 2 + 1] + (random.uniform() * 2 - 1) * range
                    }
                    continue
                }
                var position = [Int32: Int32]()
                for (index, item) in inside.enumerated() { position[Int32(item)] = Int32(index) }
                var part = Graph(n: inside.count, head: [], tail: [], weight: [])
                for edge in graph.head.indices where labels[Int(graph.head[edge])] == Int32(group) {
                    part.head.append(position[graph.head[edge]]!)
                    part.tail.append(position[graph.tail[edge]]!)
                    part.weight.append(graph.weight[edge])
                }
                let inner = spectral(part, random: &random)
                let widest = max(inner.map(abs).max() ?? 1, 1e-12)
                for (index, item) in inside.enumerated() {
                    coordinates[item * 2] = places[group * 2] + inner[index * 2] / widest * range
                    coordinates[item * 2 + 1] = places[group * 2 + 1] + inner[index * 2 + 1] / widest * range
                }
            }
        }
        // `noisy_scale_coords`, then into a 10 × 10 square.
        let expansion = 10 / max(coordinates.map(abs).max() ?? 1, 1e-12)
        var scaled = coordinates.map { $0 * expansion + random.normal() * 0.0001 }
        for dimension in 0..<2 {
            var low = Double.infinity, high = -Double.infinity
            for item in 0..<n {
                low = min(low, scaled[item * 2 + dimension])
                high = max(high, scaled[item * 2 + dimension])
            }
            let span = max(high - low, 1e-12)
            for item in 0..<n { scaled[item * 2 + dimension] = 10 * (scaled[item * 2 + dimension] - low) / span }
        }
        return scaled.map { Float($0) }
    }

    /// The layout: attraction along edges, repulsion from random others, on a falling step size.
    static func optimize(_ graph: Graph, embedding: inout [Float], epochs: Int, seed: UInt64, progress: (Int) -> Void) {
        let n = graph.n
        guard let largest = graph.weight.max(), largest > 0 else { return }
        // Edges too faint to be visited even once are dropped, and the rest are visited in
        // proportion to their weight.
        let keep = graph.weight.indices.filter { graph.weight[$0] >= largest / Float(epochs) }
        let head = keep.map { Int(graph.head[$0]) }, tail = keep.map { Int(graph.tail[$0]) }
        let edges = keep.count
        let perSample = keep.map { Double(largest / graph.weight[$0]) }
        let perNegative = perSample.map { $0 / Double(negativeSamples) }
        var nextSample = perSample, nextNegative = perNegative
        var random = SeededRandom(seed: seed)
        embedding.withUnsafeMutableBufferPointer { point in
            for epoch in 0..<epochs {
                let alpha = Float(1 - Double(epoch) / Double(epochs))
                let now = Double(epoch)
                for edge in 0..<edges where nextSample[edge] <= now {
                    let j = head[edge], k = tail[edge]
                    let dx = point[j * 2] - point[k * 2], dy = point[j * 2 + 1] - point[k * 2 + 1]
                    let squared = dx * dx + dy * dy
                    var coefficient: Float = 0
                    if squared > 0 {
                        coefficient = -2 * a * b * pow(squared, b - 1) / (a * pow(squared, b) + 1)
                    }
                    let gx = min(max(coefficient * dx, -4), 4) * alpha, gy = min(max(coefficient * dy, -4), 4) * alpha
                    point[j * 2] += gx
                    point[j * 2 + 1] += gy
                    point[k * 2] -= gx
                    point[k * 2 + 1] -= gy
                    nextSample[edge] += perSample[edge]

                    let negatives = Int((now - nextNegative[edge]) / perNegative[edge])
                    if negatives > 0 {
                        for _ in 0..<negatives {
                            let other = Int(random.next() % UInt64(n))
                            let nx = point[j * 2] - point[other * 2], ny = point[j * 2 + 1] - point[other * 2 + 1]
                            let distance = nx * nx + ny * ny
                            var push: Float = 0
                            if distance > 0 {
                                push = 2 * gamma * b / ((0.001 + distance) * (a * pow(distance, b) + 1))
                            } else if j == other {
                                continue
                            }
                            point[j * 2] += min(max(push * nx, -4), 4) * alpha
                            point[j * 2 + 1] += min(max(push * ny, -4), 4) * alpha
                        }
                        nextNegative[edge] += Double(negatives) * perNegative[edge]
                    }
                }
                progress(epoch + 1)
            }
        }
    }

    /// Items × 2. `neighbors` needs k = min(30, n − 1) + 1 counting each item itself, or fewer.
    public static func embed(_ vectors: Matrix, neighbors: VectorMath.Neighbors, seed: UInt64 = 42, progress: (Int, Int) -> Void = { _, _ in }) -> [Float] {
        let n = vectors.rows
        let graph = fuzzyGraph(neighbors, n: n)
        var random = SeededRandom(seed: seed)
        var embedding = initial(graph, vectors: vectors, random: &random)
        let epochs = n <= 10_000 ? 500 : 200
        optimize(graph, embedding: &embedding, epochs: epochs, seed: seed &+ 1) { progress($0, epochs) }
        return embedding
    }
}
