import Accelerate
import Foundation
import GRDB

/// The gist of a cloud: its searches grouped by what they're about, using the text model's
/// vectors, and each group named by the words that set it apart from the rest of the cloud.
/// Searches are short and full of proper names, so their own words name them better than a
/// vocabulary would.
public struct CloudTheme: Sendable {
    public let name: String
    /// The most typical of it first.
    public let searches: [Clouds.Search]
}

public enum CloudThemes {
    /// Fewer different searches than this is a list, not themes.
    static let fewest = 8
    /// A group of fewer searches than this isn't a theme.
    static let smallest = 3
    public static let most = 7

    /// Themes, biggest first, and the searches in none of them.
    public static func find(_ searches: [Clouds.Search], vectors: [String: [Float]]) -> (themes: [CloudTheme], rest: [Clouds.Search]) {
        // The same search made again is one point, weighed by how often.
        var order: [String] = []
        var same: [String: [Clouds.Search]] = [:]
        for search in searches {
            let key = search.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if same[key] == nil { order.append(key) }
            same[key, default: []].append(search)
        }
        let groups = order.map { same[$0]! }
        let usable = groups.indices.filter { i in groups[i].contains { vectors[$0.id] != nil } }
        guard usable.count >= fewest else { return ([], searches) }

        // Centered on the cloud, so what every search here shares doesn't pull them together.
        let dimensions = groups[usable[0]].lazy.compactMap { vectors[$0.id] }.first!.count
        var points = [[Float]]()
        for i in usable {
            let v = groups[i].lazy.compactMap { vectors[$0.id] }.first!
            points.append(v.count == dimensions ? v : [Float](repeating: 0, count: dimensions))
        }
        let weights = usable.map { Float(groups[$0].count) }
        var mean = [Float](repeating: 0, count: dimensions)
        for (p, w) in zip(points, weights) { vDSP.add(multiplication: (p, w), mean, result: &mean) }
        mean = vDSP.divide(mean, vDSP.sum(weights))
        points = points.map { normalized(vDSP.subtract($0, mean)) }

        // Tight groups name better than broad ones; the biggest are shown, the rest are "others".
        let k = min(max(Int(Double(usable.count).squareRoot().rounded()), 2), 24)
        let (assigned, centers) = cluster(points, weights: weights, k: k)

        var members = [[Int]](repeating: [], count: k)
        var typical = [Float](repeating: 0, count: groups.count)
        for (position, i) in usable.enumerated() {
            members[assigned[position]].append(i)
            typical[i] = vDSP.dot(points[position], centers[assigned[position]])
        }
        let words = groups.map { RegionLabels.ngrams(RegionLabels.tokens($0[0].text)) }
        let total = groups.reduce(0) { $0 + $1.count }

        var themes: [(name: String, groups: [Int])] = []
        for group in members {
            let size = group.reduce(0) { $0 + groups[$1].count }
            guard size > 0 else { continue }
            let name = self.name(of: group, groups: groups, words: words, size: size, total: total, typical: typical)
            // One subject split in two, like "eurorack" and "eurorack case", is one theme, under
            // the broader name.
            let lead = Set(name.components(separatedBy: " · ")[0].split(separator: " "))
            if let same = themes.firstIndex(where: { theme in
                let other = Set(theme.name.components(separatedBy: " · ")[0].split(separator: " "))
                return lead.isSubset(of: other) || other.isSubset(of: lead)
            }) {
                if lead.count < Set(themes[same].name.components(separatedBy: " · ")[0].split(separator: " ")).count { themes[same].name = name }
                themes[same].groups += group
            } else {
                themes.append((name, group))
            }
        }
        func size(_ g: [Int]) -> Int { g.reduce(0) { $0 + groups[$1].count } }
        themes = themes.filter { size($0.groups) >= smallest }.sorted { size($0.groups) > size($1.groups) }
        let kept = themes.prefix(most)
        let inThemes = Set(kept.flatMap(\.groups))
        let rest = groups.indices.filter { !inThemes.contains($0) }.flatMap { groups[$0] }
        return (kept.map { theme in
            let ranked = theme.groups.sorted { typical[$0] > typical[$1] }
            return CloudTheme(name: theme.name, searches: ranked.flatMap { groups[$0] })
        }, rest.sorted { $0.time > $1.time })
    }

    /// The words found in many of a group's searches and few of the cloud's others: up to
    /// three, each in at least a sixth of the group. When none are, the group's most typical
    /// search stands for it.
    static func name(of group: [Int], groups: [[Clouds.Search]], words: [Set<String>], size: Int, total: Int,
                     typical: [Float]) -> String {
        var inside: [String: Int] = [:], outside: [String: Int] = [:]
        let members = Set(group)
        for i in groups.indices {
            for phrase in words[i] {
                if members.contains(i) { inside[phrase, default: 0] += groups[i].count } else { outside[phrase, default: 0] += groups[i].count }
            }
        }
        let rest = Double(max(total - size, 1))
        func share(_ phrase: String) -> Double { Double(inside[phrase] ?? 0) / Double(size) }
        func score(_ phrase: String) -> Double {
            // Longer phrases win ties: "eurorack case" over "eurorack" when both cover the same.
            let length = Double(phrase.split(separator: " ").count)
            return (share(phrase) - Double(outside[phrase] ?? 0) / rest) * (1 + 0.1 * (length - 1))
        }
        let ranked = inside.keys.filter { (inside[$0] ?? 0) >= 2 && share($0) >= 1.0 / 6 && score($0) > 0 }
            .sorted { score($0) != score($1) ? score($0) > score($1) : $0 < $1 }
        var chosen: [String] = []
        var used = Set<Substring>()
        for phrase in ranked where chosen.count < 3 {
            let parts = phrase.split(separator: " ")
            guard used.isDisjoint(with: parts) else { continue }
            chosen.append(phrase)
            used.formUnion(parts)
        }
        if !chosen.isEmpty { return chosen.joined(separator: " · ") }
        let top = group.max { typical[$0] < typical[$1] }!
        let text = groups[top][0].text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    /// Spherical k-means, seeded the same way every time, so a cloud's themes don't shuffle
    /// as the timeline moves.
    static func cluster(_ points: [[Float]], weights: [Float], k: Int) -> (assigned: [Int], centers: [[Float]]) {
        var random = SplitMix(seed: 0x5EA5_0115)
        var centers: [[Float]] = [points[weights.indices.max { weights[$0] < weights[$1] }!]]
        var nearest = points.map { 1 - vDSP.dot($0, centers[0]) }
        while centers.count < k {
            let reach = zip(nearest, weights).map { max($0, 0) * $1 }
            let sum = vDSP.sum(reach)
            guard sum > 0 else { break }
            var pick = Float(random.unit()) * sum, chosen = reach.count - 1
            for (i, r) in reach.enumerated() {
                pick -= r
                if pick <= 0 { chosen = i; break }
            }
            centers.append(points[chosen])
            nearest = zip(nearest, points).map { min($0, 1 - vDSP.dot($1, centers[centers.count - 1])) }
        }
        var assigned = [Int](repeating: 0, count: points.count)
        for _ in 0..<20 {
            var changed = false
            for (i, p) in points.enumerated() {
                let best = centers.indices.max { vDSP.dot(p, centers[$0]) < vDSP.dot(p, centers[$1]) }!
                if best != assigned[i] { assigned[i] = best; changed = true }
            }
            var sums = [[Float]](repeating: [Float](repeating: 0, count: points[0].count), count: centers.count)
            for (i, p) in points.enumerated() { vDSP.add(multiplication: (p, weights[i]), sums[assigned[i]], result: &sums[assigned[i]]) }
            for c in centers.indices where vDSP.sum(vDSP.absolute(sums[c])) > 0 { centers[c] = normalized(sums[c]) }
            if !changed { break }
        }
        return (assigned, centers)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let length = vDSP.sumOfSquares(v).squareRoot()
        return length > 0 ? vDSP.divide(v, length) : v
    }
}

/// A small random number generator that starts the same way every time.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

extension Library {
    /// The text model's vectors for some items, by id.
    public func textVectors(of ids: [String]) throws -> [String: [Float]] {
        try db.read { db in
            var out: [String: [Float]] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchCursor(db, sql: "select item_id, vector from embedding where model = ? and item_id in (\(marks))",
                                               arguments: StatementArguments([WordsEncoder.modelName] + chunk))
                while let row = try rows.next() {
                    let blob: Data = row[1]
                    out[row[0]] = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
            }
            return out
        }
    }
}
