import Accelerate
import Foundation

/// A table of 32-bit floats, one row per item.
public struct Matrix: Sendable {
    public var rows: Int
    public var columns: Int
    public var values: [Float]

    public init(rows: Int, columns: Int, values: [Float]? = nil) {
        self.rows = rows
        self.columns = columns
        self.values = values ?? [Float](repeating: 0, count: rows * columns)
    }

    public func row(_ index: Int) -> ArraySlice<Float> {
        values[(index * columns)..<((index + 1) * columns)]
    }

    public func selecting(_ indices: [Int]) -> Matrix {
        var out = Matrix(rows: indices.count, columns: columns)
        values.withUnsafeBufferPointer { source in
            out.values.withUnsafeMutableBufferPointer { target in
                for (position, index) in indices.enumerated() {
                    memcpy(target.baseAddress! + position * columns, source.baseAddress! + index * columns, columns * MemoryLayout<Float>.size)
                }
            }
        }
        return out
    }

    /// Every row at unit length.
    public var unitRows: Matrix {
        var out = self
        out.values.withUnsafeMutableBufferPointer { values in
            for row in 0..<rows {
                let start = values.baseAddress! + row * columns
                let length = max(cblas_snrm2(Int32(columns), start, 1), 1e-9)
                cblas_sscal(Int32(columns), 1 / length, start, 1)
            }
        }
        return out
    }

    /// The average row of some rows.
    public func mean(of indices: [Int]) -> [Float] {
        var sum = [Double](repeating: 0, count: columns)
        for index in indices {
            for column in 0..<columns { sum[column] += Double(values[index * columns + column]) }
        }
        let count = Double(max(indices.count, 1))
        return sum.map { Float($0 / count) }
    }

    /// `self · other.T`, a table of similarities when rows are unit length.
    public func product(transposeOf other: Matrix) -> Matrix {
        var out = Matrix(rows: rows, columns: other.rows)
        guard rows > 0, other.rows > 0 else { return out }
        values.withUnsafeBufferPointer { a in
            other.values.withUnsafeBufferPointer { b in
                out.values.withUnsafeMutableBufferPointer { c in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(other.rows), Int32(columns), 1,
                                a.baseAddress, Int32(columns), b.baseAddress, Int32(columns), 0, c.baseAddress, Int32(other.rows))
                }
            }
        }
        return out
    }
}

public enum VectorMath {
    /// The largest `k` of `values`, as positions, largest first.
    static func largest(_ values: UnsafeBufferPointer<Float>, k: Int) -> [Int32] {
        // A small sorted list beats a heap at the k used here.
        var kept = [(value: Float, index: Int32)]()
        kept.reserveCapacity(k + 1)
        var floor = -Float.infinity
        for index in 0..<values.count {
            let value = values[index]
            if kept.count == k, value <= floor { continue }
            var position = kept.count
            while position > 0, kept[position - 1].value < value { position -= 1 }
            kept.insert((value, Int32(index)), at: position)
            if kept.count > k { kept.removeLast() }
            if kept.count == k { floor = kept[k - 1].value }
        }
        return kept.map(\.index)
    }

    public struct Neighbors: Sendable {
        public var k: Int
        public var indices: [Int32]     // items × k, closest first
        public var distances: [Float]   // items × k
    }

    /// The exact `k` closest rows by cosine distance, each row's own first. Rows are unit
    /// length. Exact rather than approximate, since matrix multiplication is quick enough.
    public static func nearest(_ vectors: Matrix, k: Int, chunk: Int = 1024, progress: (Int) -> Void = { _ in }) -> Neighbors {
        let n = vectors.rows
        var indices = [Int32](repeating: 0, count: n * k)
        var distances = [Float](repeating: 0, count: n * k)
        var start = 0
        while start < n {
            let end = min(start + chunk, n)
            let similarity = vectors.selecting(Array(start..<end)).product(transposeOf: vectors)
            similarity.values.withUnsafeBufferPointer { table in
                indices.withUnsafeMutableBufferPointer { indices in
                    distances.withUnsafeMutableBufferPointer { distances in
                        // Safe across threads: each row writes only its own part.
                        nonisolated(unsafe) let indexOut = indices.baseAddress!
                        nonisolated(unsafe) let distanceOut = distances.baseAddress!
                        nonisolated(unsafe) let source = table.baseAddress!
                        let rows = end - start
                        DispatchQueue.concurrentPerform(iterations: rows) { row in
                            let line = UnsafeBufferPointer(start: source + row * n, count: n)
                            var found = largest(line, k: k)
                            // An exact duplicate can come ahead of the row itself.
                            let me = Int32(start + row)
                            if let at = found.firstIndex(of: me) {
                                found.remove(at: at)
                                found.insert(me, at: 0)
                            } else {
                                found.removeLast()
                                found.insert(me, at: 0)
                            }
                            for (position, index) in found.enumerated() {
                                indexOut[(start + row) * k + position] = index
                                distanceOut[(start + row) * k + position] = index == me ? 0 : max(0, 1 - line[Int(index)])
                            }
                        }
                    }
                }
            }
            start = end
            progress(end)
        }
        return Neighbors(k: k, indices: indices, distances: distances)
    }

    /// Eigenvalues and eigenvectors of a small symmetric table, largest first, by Jacobi
    /// rotations. Each column of `vectors` (row-major, n × n) belongs to an eigenvalue.
    static func symmetricEigen(_ table: [Double], n: Int) -> (values: [Double], vectors: [Double]) {
        var a = table
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }
        for _ in 0..<64 {
            var off = 0.0
            for i in 0..<n { for j in 0..<n where i != j { off += a[i * n + j] * a[i * n + j] } }
            if off < 1e-22 { break }
            for p in 0..<n {
                for q in (p + 1)..<max(n, p + 1) {
                    let apq = a[p * n + q]
                    if abs(apq) < 1e-300 { continue }
                    let theta = (a[q * n + q] - a[p * n + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = a[k * n + p], akq = a[k * n + q]
                        a[k * n + p] = c * akp - s * akq
                        a[k * n + q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p * n + k], aqk = a[q * n + k]
                        a[p * n + k] = c * apk - s * aqk
                        a[q * n + k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k * n + p], vkq = v[k * n + q]
                        v[k * n + p] = c * vkp - s * vkq
                        v[k * n + q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let order = (0..<n).sorted { a[$0 * n + $0] > a[$1 * n + $1] }
        var values = [Double](repeating: 0, count: n), vectors = [Double](repeating: 0, count: n * n)
        for (out, source) in order.enumerated() {
            values[out] = a[source * n + source]
            for row in 0..<n { vectors[row * n + out] = v[row * n + source] }
        }
        return (values, vectors)
    }

    /// `np.percentile` with its default, linear, interpolation.
    static func percentile(_ values: [Float], _ percent: Double) -> Float {
        let sorted = values.sorted()
        guard let last = sorted.last else { return 0 }
        let position = percent / 100 * Double(sorted.count - 1)
        let low = Int(position), high = min(low + 1, sorted.count - 1)
        guard low != high else { return last == sorted[low] ? last : sorted[low] }
        let fraction = Float(position - Double(low))
        return sorted[low] + (sorted[high] - sorted[low]) * fraction
    }

    static func median(_ values: [Float]) -> Float {
        percentile(values, 50)
    }
}

/// A small, seeded random number source, so the same vectors always draw the same map.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func normal() -> Double {
        let radius = (-2 * log(max(uniform(), 1e-300))).squareRoot()
        return radius * cos(2 * .pi * uniform())
    }
}
