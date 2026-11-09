import Foundation
import GRDB
import TopographCore

// Comparisons with what the Python pipeline stored, on a copy of a real library. They print
// numbers and region names only.

/// How much two labelings agree, 1 being the same division whatever the numbers.
func adjustedRandIndex(_ a: [Int], _ b: [Int]) -> Double {
    var table: [Int: [Int: Int]] = [:], rowTotals: [Int: Int] = [:], columnTotals: [Int: Int] = [:]
    for (x, y) in zip(a, b) {
        table[x, default: [:]][y, default: 0] += 1
        rowTotals[x, default: 0] += 1
        columnTotals[y, default: 0] += 1
    }
    func pairs(_ count: Int) -> Double { Double(count) * Double(count - 1) / 2 }
    let index = table.values.reduce(0.0) { $0 + $1.values.reduce(0.0) { $0 + pairs($1) } }
    let rows = rowTotals.values.reduce(0.0) { $0 + pairs($1) }, columns = columnTotals.values.reduce(0.0) { $0 + pairs($1) }
    let expected = rows * columns / pairs(a.count)
    return (index - expected) / ((rows + columns) / 2 - expected)
}

/// Regions and names from the positions Python stored, against what it stored.
func checkRegions(library: LibraryWriter, map: String) throws {
    let database = try DatabaseQueue(path: library.root.appending(path: "topograph.sqlite").path)
    let stored = "clip-vit-b-32" + (map == "pictures" ? "" : "+" + map)
    var xy: [Float] = [], ids: [String] = [], labels: [Int] = []
    var clip: [Float] = []
    var texts: [String?] = [], pictures: [Bool] = []
    var names: [Int: String] = [:]
    try database.read { db in
        let vectors = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "select item_id, vector from embedding where model = 'clip-vit-b-32'").map { ($0["item_id"] as String, $0["vector"] as Data) })
        let hasPicture = Set(try String.fetchAll(db, sql: "select distinct item_id from media where status = 'ok'"))
        let text = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "select id, text from item").map { ($0["id"] as String, $0["text"] as String?) })
        for row in try Row.fetchAll(db, sql: "select item_id, x, y, cluster from layout where model = ?", arguments: [stored]) {
            let id = row["item_id"] as String
            guard let vector = vectors[id] else { continue }
            ids.append(id)
            xy += [Float(row["x"] as Double), Float(row["y"] as Double)]
            labels.append(row["cluster"])
            clip += vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            texts.append(text[id] ?? nil)
            pictures.append(hasPicture.contains(id))
        }
        for row in try Row.fetchAll(db, sql: "select id, label from cluster where model = ?", arguments: [stored]) { names[row["id"]] = row["label"] }
    }
    print("\(ids.count) items, \(Set(labels).count) fine regions stored")
    var start = Date()
    let found = HDBSCAN.regions(xy)
    print("HDBSCAN: \(Set(found).count) fine regions, agreement \(adjustedRandIndex(found, labels)), \(Date().timeIntervalSince(start)) s")

    start = Date()
    var (regions, roots) = RegionNesting.build(xy: xy, leaf: labels)
    print("Nesting: \(regions.count) regions, \(roots.count) at the top; stored \(names.count)")
    let clipMatrix = Matrix(rows: ids.count, columns: clip.count / max(ids.count, 1), values: clip)
    let concepts = RegionLabels.loadConcepts()
    print("Concepts \(concepts.count), modifiers \(RegionLabels.loadModifiers().count)")
    let phrases = try DatabaseQueue(path: library.root.appending(path: "topograph.sqlite").path)
    try RegionLabels.name(regions: &regions, roots: roots, vectors: clipMatrix, texts: texts, hasImage: pictures, concepts: concepts, modifiers: RegionLabels.loadModifiers()) { wanted in
        var table = Matrix(rows: wanted.count, columns: clipMatrix.columns)
        var missing = 0
        try phrases.read { db in
            for (row, name) in wanted.enumerated() {
                if let data = try Data.fetchOne(db, sql: "select vector from phrase_vec where model = 'clip-vit-b-32' and phrase = ?", arguments: [name]) {
                    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    for (column, value) in values.enumerated() { table.values[row * table.columns + column] = value }
                } else {
                    missing += 1
                }
            }
        }
        print("Candidate names: \(wanted.count), \(missing) without a stored vector")
        return table
    }
    print("Named in \(Date().timeIntervalSince(start)) s")
    let storedLabels = Set(names.values)
    let mine = Set(regions.values.map(\.label))
    print("Names in common: \(storedLabels.intersection(mine).count) of \(storedLabels.count) stored, \(mine.count) mine")
    let top = roots.sorted { (regions[$0]?.members.count ?? 0) > (regions[$1]?.members.count ?? 0) }.compactMap { regions[$0]?.label }
    print("Top level, mine: \(top.joined(separator: " | "))")
}

/// Text-model vectors against the ones Python stored, on a sample of items.
func checkWords(library: LibraryWriter) throws {
    let encoder = try WordsEncoder()
    let database = try DatabaseQueue(path: library.root.appending(path: "topograph.sqlite").path)
    let rows = try database.read { db in
        try Row.fetchAll(db, sql: """
            select i.platform, i.text, e.vector from item i join embedding e on e.item_id = i.id
            where e.model = 'minilm-l6-v2' order by random() limit 2000
            """)
    }
    var cosines: [Float] = []
    let start = Date()
    for row in rows {
        let text = MapVectors.cleanText(platform: row["platform"], text: row["text"])
        let stored = (row["vector"] as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let mine = try encoder.embed(text)
        cosines.append(zip(stored, mine).reduce(0) { $0 + $1.0 * $1.1 })
    }
    cosines.sort()
    print("\(cosines.count) items in \(Date().timeIntervalSince(start)) s: lowest cosine \(cosines[0]), 1st percentile \(cosines[cosines.count / 100]), median \(cosines[cosines.count / 2])")
}

/// Colors and hashes from Python's display copies, against what it stored. Its thumbnails came
/// straight from the original, so this is close to, not the same as, what an import does.
func checkPalette(library: LibraryWriter) throws {
    let database = try DatabaseQueue(path: library.root.appending(path: "topograph.sqlite").path)
    let rows = try database.read { db in
        try Row.fetchAll(db, sql: "select local_path, palette, phash from media where status = 'ok' and palette is not null order by random() limit 1500")
    }
    var first: [Int] = [], weight: [Double] = []
    var bits = 0, hashed = 0
    func parts(_ hex: String) -> [Int] { [1, 3, 5].map { Int(hex.dropFirst($0).prefix(2), radix: 16) ?? 0 } }
    for row in rows {
        guard let data = FileManager.default.contents(atPath: library.root.appending(path: row["local_path"] as String).path),
              let image = MediaIngest.decode(data),
              let stored = try JSONValue.parse(row["palette"] as String).array,
              let mine = try JSONValue.parse(MediaIngest.palette(image)).array,
              let a = stored.first?.array, let b = mine.first?.array else { continue }
        first.append(zip(parts(a[0].string ?? ""), parts(b[0].string ?? "")).reduce(0) { $0 + abs($1.0 - $1.1) })
        weight.append(abs((a[1].number ?? 0) - (b[1].number ?? 0)))
        if let old = UInt64(row["phash"] as String, radix: 16), let new = UInt64(MediaIngest.perceptualHash(image), radix: 16) {
            bits += (old ^ new).nonzeroBitCount
            hashed += 1
        }
    }
    first.sort()
    weight.sort()
    print("\(first.count) pictures. Leading color, summed channel difference: median \(first[first.count / 2]), 90th \(first[first.count * 9 / 10]); weight difference: median \(weight[weight.count / 2]), 90th \(weight[weight.count * 9 / 10]). Hash: \(Double(bits) / Double(max(hashed, 1))) bits apart on average")
}

/// The biggest clouds of a season and their themes, for judging the themes on real searches.
/// The season ends at the given day (yyyy-mm-dd), or at the latest search.
func checkClouds(endingAt day: String?) throws {
    let library = try Library()
    let map = try library.map()
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd"
    guard let end = day.flatMap({ format.date(from: $0) }).map({ Int($0.timeIntervalSince1970) }) ?? map.clouds.searches.last?.time,
          let weather = map.clouds.weather(endingAt: end) else { return print("no weather then") }
    var seen = Set<String>()
    var clouds: [Clouds.Cloud] = []
    for y in stride(from: 0.0, through: 1000, by: 8) {
        for x in stride(from: 0.0, through: 1000, by: 8) {
            guard Clouds.isCloudy(weather, at: x, y), let cloud = map.clouds.cloud(at: x, y, weather: weather, endingAt: end),
                  let first = cloud.searches.first, !seen.contains(first.id) else { continue }
            seen.formUnion(cloud.searches.map(\.id))
            clouds.append(cloud)
        }
    }
    print("season ending \(format.string(from: Date(timeIntervalSince1970: TimeInterval(end)))): \(clouds.count) clouds")
    for cloud in clouds.sorted(by: { $0.searches.count > $1.searches.count }).prefix(5) {
        let started = Date()
        let vectors = try library.textVectors(of: cloud.searches.map(\.id))
        let (themes, rest) = CloudThemes.find(cloud.searches, vectors: vectors)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("\n\(cloud.searches.count) searches (\(ms) ms)")
        for theme in themes {
            let examples = theme.searches.map(\.text).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(4)
            print("  \(theme.name) [\(theme.searches.count)]: \(examples.joined(separator: " | "))")
        }
        print("  and \(rest.count) others")
    }
}
