import Accelerate
import Foundation
import GRDB

/// A theme that came back: activity, then at least nine months of near-silence, then
/// activity again.
public struct Echo: Sendable, Identifiable {
    public let region: Int
    /// Month indexes of the stretches either side of the silence.
    public let then: ClosedRange<Int>
    public let now: ClosedRange<Int>
    public let silentMonths: Int
    /// Most resonant first, pictures first.
    public let thenItems: [Int32]
    public let nowItems: [Int32]
    public var id: Int { region }
}

public enum Echoes {
    private static func peakLimit(_ busy: [Int]) -> Int { max(8, busy[busy.count / 2] * 8) }

    /// Finest regions only: a large region is almost never silent for long, and it's the
    /// specific interests whose return is worth noticing.
    public static func find(map: LibraryMap, visible: [Int32], axis: MonthAxis, minimumGap: Int = 9,
                            minimumItems: Int = 5, stripLength: Int = 10) -> [Echo] {
        var byRegion: [Int: [Int32]] = [:]
        for index in visible {
            if let region = map.items[Int(index)].region { byRegion[region, default: []].append(index) }
        }
        var found: [(score: Double, echo: Echo)] = []
        for (region, members) in byRegion where map.regions.regions[region] != nil {
            var months = [[Int32]](repeating: [], count: axis.count)
            for index in members {
                if let time = map.items[Int(index)].time, let month = axis.index(of: time) { months[month].append(index) }
            }
            // Near-silence, not perfect silence, judged against a typical month rather than
            // the busiest: one bulk import or big day shouldn't make normal months look quiet.
            let busy = months.map(\.count).filter { $0 > 0 }.sorted()
            guard !busy.isEmpty else { continue }
            let silence = max(1, busy[busy.count / 2] / 4)
            let active = months.indices.filter { months[$0].count > silence }
            guard active.count >= 2 else { continue }

            // The longest quiet stretch between two active months.
            var bestGap = 0, before = 0, after = 0
            for (a, b) in zip(active, active.dropFirst()) where b - a - 1 > bestGap {
                bestGap = b - a - 1
                before = a
                after = b
            }
            guard bestGap >= minimumGap else { continue }

            // A year either side at most, so a long history doesn't blur what came back.
            let first = active.first { $0 >= before - 11 } ?? before
            let last = active.last { $0 <= after + 11 } ?? after
            let thenItems = months[first...before].flatMap { $0 }
            let nowItems = months[after...last].flatMap { $0 }
            guard thenItems.count >= minimumItems, nowItems.count >= minimumItems else { continue }
            // A single busy month on one side is more likely a bulk import than a return.
            guard first < before || months[before].count < peakLimit(busy),
                  after < last || months[after].count < peakLimit(busy) else { continue }
            func strip(_ items: [Int32]) -> [Int32] {
                Array(items.sorted {
                    let a = map.items[Int($0)], b = map.items[Int($1)]
                    if (a.thumb != nil) != (b.thumb != nil) { return a.thumb != nil }
                    return a.resonance != b.resonance ? a.resonance > b.resonance : $0 < $1
                }.prefix(stripLength))
            }
            let echo = Echo(region: region, then: first...before, now: after...last, silentMonths: bestGap,
                            thenItems: strip(thenItems), nowItems: strip(nowItems))
            found.append((Double(bestGap) * Double(min(thenItems.count, nowItems.count)).squareRoot(), echo))
        }
        return found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.echo.region < $1.echo.region }.map(\.echo)
    }
}

/// Pictures by their strongest color: hue around a circle, lighter toward the middle.
public enum PaletteLayout {
    /// `seed` spreads out colors that would otherwise land on one spot or one spoke.
    public static func position(rgb: UInt32, seed: Int = 0) -> (x: Double, y: Double) {
        let r = Double((rgb >> 16) & 0xff) / 255, g = Double((rgb >> 8) & 0xff) / 255, b = Double(rgb & 0xff) / 255
        let high = max(r, g, b), low = min(r, g, b), chroma = high - low
        let lightness = (high + low) / 2
        var hue = 0.0
        if chroma > 0 {
            if high == r { hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6) }
            else if high == g { hue = (b - r) / chroma + 2 }
            else { hue = (r - g) / chroma + 4 }
        }
        // Grays have no hue of their own, so they gather near the middle in every direction.
        // Near-grays have only a rough one, which would otherwise show as hard spokes.
        let saturation = min(chroma / max(1 - abs(2 * lightness - 1), 0.001), 1)
        let scatterA = Double((seed &* 2654435761) & 0xffff) / 65535, scatterB = Double((seed &* 40503) & 0xffff) / 65535
        let certainty = min(saturation / 0.3, 1)
        let hueAngle = hue / 6 * 2 * .pi - .pi / 2
        let angle = hueAngle + (scatterA - 0.5) * 2 * .pi * (1 - certainty) + (scatterA - 0.5) * 0.28 * certainty
        let radius = (1 - lightness) * (0.25 + 0.75 * saturation) * (0.94 + 0.12 * scatterB)
        return (cos(angle) * radius, sin(angle) * radius)
    }
}

/// Every item's image-text vector, for comparing taste directly.
public struct EmbeddingStore: Sendable {
    public let dimensions: Int
    private let vectors: [Float]
    private let rowOfItem: [Int32: Int]
    /// The average of many short phrases, which `nearest` takes away from a query.
    private let everyday: [Float]

    public init(dimensions: Int, vectors: [Float], rowOfItem: [Int32: Int], everyday: [Float] = []) {
        self.dimensions = dimensions
        self.vectors = vectors
        self.rowOfItem = rowOfItem
        self.everyday = everyday
    }

    public func has(_ item: Int32) -> Bool { rowOfItem[item] != nil }

    /// Cosine similarity: the vectors are L2-normalized.
    public func similarity(_ a: Int32, _ b: Int32) -> Float? {
        guard let rowA = rowOfItem[a], let rowB = rowOfItem[b] else { return nil }
        var result: Float = 0
        vectors.withUnsafeBufferPointer { base in
            vDSP_dotpr(base.baseAddress! + rowA * dimensions, 1, base.baseAddress! + rowB * dimensions, 1, &result, vDSP_Length(dimensions))
        }
        return result
    }

    /// Items closest in meaning to a text vector, closest first.
    ///
    /// Plain cosine similarity gives poor results here, in two ways that showed on the real
    /// library. Text scores far above pictures against a text query, so no picture ever
    /// made the top 300. And a few items sit close to almost any query, so the same ones
    /// led every search. So each item is scored against the query minus the average
    /// phrase, which cancels the second, and judged in standard deviations among its own
    /// kind (pictures or text alone), which cancels the first.
    public func nearest(to query: [Float], items: [MapItem], count: Int) -> [Int32] {
        guard dimensions > 0, query.count == dimensions else { return [] }
        let rows = vectors.count / dimensions
        var target = query
        if everyday.count == dimensions { vDSP.subtract(query, everyday, result: &target) }
        var scores = [Float](repeating: 0, count: rows)
        vDSP_mmul(vectors, 1, target, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(dimensions))

        var itemOfRow = [Int32](repeating: -1, count: rows)
        for (item, row) in rowOfItem { itemOfRow[row] = item }
        let hasPicture = itemOfRow.map { $0 >= 0 && items[Int($0)].thumb != nil }
        for pictures in [true, false] {
            let rowsOfKind = hasPicture.indices.filter { hasPicture[$0] == pictures }
            guard rowsOfKind.count > 1 else { continue }
            let (mean, spread) = Self.meanAndSpread(rowsOfKind.map { scores[$0] })
            guard spread > 0 else { continue }
            for row in rowsOfKind { scores[row] = (scores[row] - mean) / spread }
        }
        return scores.indices
            .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : itemOfRow[$0] < itemOfRow[$1] }
            .lazy.map { itemOfRow[$0] }.filter { $0 >= 0 }.prefix(count).map { $0 }
    }

    private static func meanAndSpread(_ values: [Float]) -> (Float, Float) {
        var mean: Float = 0
        var spread: Float = 0
        vDSP_normalize(values, 1, nil, 1, &mean, &spread, vDSP_Length(values.count))
        return (mean, spread)
    }
}

extension Library {
    public func embeddings(map: LibraryMap) throws -> EmbeddingStore {
        try db.read { db in
            let model = try String.fetchOne(db, sql: "select value from meta where key = 'embedding_model'")
            var vectors: [Float] = []
            var dimensions = 0
            var rows: [Int32: Int] = [:]
            rows.reserveCapacity(map.items.count)
            let cursor = try Row.fetchCursor(db, sql: "select item_id, vector from embedding where model = ?", arguments: [model])
            while let row = try cursor.next() {
                guard let index = map.indexOfID[row[0] as String] else { continue }
                let blob: Data = row[1]
                let count = blob.count / MemoryLayout<Float>.size
                if dimensions == 0 {
                    dimensions = count
                    vectors.reserveCapacity(map.items.count * count)
                }
                guard count == dimensions else { continue }
                rows[index] = vectors.count / dimensions
                blob.withUnsafeBytes { vectors.append(contentsOf: $0.bindMemory(to: Float.self)) }
            }
            // The pipeline keeps a vector for every candidate region name.
            var everyday = [Float](repeating: 0, count: dimensions)
            var phrases = 0
            let phraseCursor = try Row.fetchCursor(db, sql: "select vector from phrase_vec where model = ?", arguments: [model])
            while let row = try phraseCursor.next() {
                let blob: Data = row[0]
                guard blob.count == dimensions * MemoryLayout<Float>.size else { continue }
                blob.withUnsafeBytes { bytes in
                    let phrase = bytes.bindMemory(to: Float.self)
                    for index in 0..<dimensions { everyday[index] += phrase[index] }
                }
                phrases += 1
            }
            if phrases > 0 { everyday = everyday.map { $0 / Float(phrases) } }
            return EmbeddingStore(dimensions: dimensions, vectors: vectors, rowOfItem: rows, everyday: phrases > 0 ? everyday : [])
        }
    }
}

public enum Tributaries {
    /// For something you made: what you kept in the months before it that sits nearest
    /// to it in taste. Only what you kept, since your own work isn't an influence here.
    public static func find(of item: Int32, map: LibraryMap, embeddings: EmbeddingStore,
                            months: Int = 6, count: Int = 12) -> [Int32] {
        guard let time = map.items[Int(item)].time, embeddings.has(item) else { return [] }
        let earliest = time - months * 30 * 86400
        var scored: [(Int32, Float)] = []
        for index in map.items.indices {
            let other = map.items[index]
            guard !other.mine, let when = other.time, when < time, when >= earliest,
                  let score = embeddings.similarity(item, Int32(index)) else { continue }
            scored.append((Int32(index), score))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(count).map(\.0)
    }
}

/// Versions of one piece: your own pictures that look nearly the same and were made
/// close together in time.
public enum ProcessSequences {
    public static func find(items: [MapItem], maximumDistance: Int = 8, window: Int = 30 * 86400,
                            minimumLength: Int = 3) -> [[Int32]] {
        let candidates = items.indices
            .filter { items[$0].mine && items[$0].phash != nil && items[$0].time != nil }
            .sorted { items[$0].time! < items[$1].time! }
        var parent = Array(candidates.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var start = 0
        for current in candidates.indices {
            let item = items[candidates[current]]
            while item.time! - items[candidates[start]].time! > window { start += 1 }
            for earlier in start..<current {
                let distance = (item.phash! ^ items[candidates[earlier]].phash!).nonzeroBitCount
                if distance <= maximumDistance { parent[root(current)] = root(earlier) }
            }
        }
        var groups: [Int: [Int32]] = [:]
        for current in candidates.indices { groups[root(current), default: []].append(Int32(candidates[current])) }
        return groups.values.filter { $0.count >= minimumLength }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0]
        }
    }
}
