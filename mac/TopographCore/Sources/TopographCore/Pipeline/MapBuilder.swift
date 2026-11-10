import Accelerate
import Foundation
import GRDB

/// Embed what's new, lay out and name one map. Other maps in the library are left alone.
public enum MapBuilder {
    private static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    private static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Run `work` over each input across all cores, in small batches so that a pause is quick
    /// and what's done stays done.
    private static func forEachBatch<Input, Output>(_ inputs: [Input], size: Int, reporter: PipelineReporter, work: @escaping @Sendable (Input) -> Output?,
                                                    store: ([(Input, Output)]) throws -> Void, progress: (Int) -> Void) throws where Input: Sendable, Output: Sendable {
        var start = 0
        while start < inputs.count {
            if reporter.isCancelled() { throw PipelinePaused() }
            let part = Array(inputs[start..<min(start + size, inputs.count)])
            let results = LockedResults<Output>(count: part.count)
            DispatchQueue.concurrentPerform(iterations: part.count) { index in
                results.set(index, work(part[index]))
            }
            try store(zip(part, results.values).compactMap { input, output in output.map { (input, $0) } })
            start += part.count
            progress(part.count)
        }
    }

    private final class LockedResults<Output>: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [Output?]
        init(count: Int) { values = [Output?](repeating: nil, count: count) }
        func set(_ index: Int, _ value: Output?) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }
    }

    /// A CLIP vector for every item that has anything to read. Resumable. Returns how many.
    @discardableResult
    public static func embedLibrary(library: LibraryWriter, encoder: CLIPEncoder, force: Bool = false, reporter: PipelineReporter) throws -> Int {
        let gone = try library.markUnavailable()
        if gone > 0 { reporter.say("Leaving \(gone.formatted()) posts that are no longer online off the map.") }
        let model = CLIPEncoder.modelName
        struct Work: Sendable {
            let id: String
            let text: String?
            let pictures: [URL]
        }
        let work: [Work] = try library.db.write { db in
            if force { try db.execute(sql: "delete from embedding where model = ?", arguments: [model]) }
            let rows = try Row.fetchAll(db, sql: """
                select i.id, i.text from item i where i.kind != 'trace' and not exists
                (select 1 from embedding e where e.item_id = i.id and e.model = ?)
                """, arguments: [model])
            var media: [String: [URL]] = [:]
            for row in try Row.fetchAll(db, sql: "select item_id, local_path from media where status = 'ok' order by ord") {
                let id = row["item_id"] as String
                if media[id, default: []].count < 4 { media[id, default: []].append(library.root.appending(path: row["local_path"] as String)) }
            }
            var out: [Work] = []
            for row in rows {
                let id = row["id"] as String, text = row["text"] as String?
                if let pictures = media[id] {
                    out.append(Work(id: id, text: text, pictures: pictures))
                } else if PipelineText.hasWords(text) {
                    out.append(Work(id: id, text: text, pictures: []))
                }
            }
            return out
        }
        guard !work.isEmpty else {
            try library.setMeta("embedding_model", model)
            return 0
        }
        let line = ProgressLine("Reading images and captions", total: work.count, unit: "items", reporter: reporter)
        try forEachBatch(work, size: 64, reporter: reporter) { item -> [Float]? in
            // One picture that won't open shouldn't stop the others.
            try? encoder.embedItem(pictures: item.pictures, caption: item.text)
        } store: { results in
            try library.db.write { db in
                for (item, vector) in results {
                    try db.execute(sql: "insert or replace into embedding(item_id, model, vector) values (?,?,?)", arguments: [item.id, model, data(vector)])
                }
            }
        } progress: { line.advance($0) }
        try library.setMeta("embedding_model", model)
        line.close("\(work.count.formatted()) items")
        return work.count
    }

    /// A text-model vector for every mapped item with words. Resumable, and hydrating clears
    /// them when an item's text arrives.
    @discardableResult
    public static func embedWords(library: LibraryWriter, encoder: WordsEncoder, base: String, reporter: PipelineReporter) throws -> Int {
        let rows = try library.db.read { db in
            try Row.fetchAll(db, sql: """
                select i.id, i.platform, i.text from item i where exists (select 1 from embedding e where e.item_id = i.id and e.model = ?)
                and not exists (select 1 from embedding e where e.item_id = i.id and e.model = ?)
                """, arguments: [base, WordsEncoder.modelName])
        }
        struct Work: Sendable {
            let id: String
            let text: String
        }
        let work = rows.compactMap { row -> Work? in
            let text = MapVectors.cleanText(platform: row["platform"], text: row["text"])
            return text.isEmpty ? nil : Work(id: row["id"], text: text)
        }
        guard !work.isEmpty else { return 0 }
        let line = ProgressLine("Reading the words", total: work.count, unit: "items", reporter: reporter)
        try forEachBatch(work, size: 256, reporter: reporter) { item -> [Float]? in
            try? encoder.embed(item.text)
        } store: { results in
            try library.db.write { db in
                for (item, vector) in results {
                    try db.execute(sql: "insert or replace into embedding(item_id, model, vector) values (?,?,?)", arguments: [item.id, WordsEncoder.modelName, data(vector)])
                }
            }
        } progress: { line.advance($0) }
        line.close("\(work.count.formatted()) items")
        return work.count
    }

    /// CLIP vectors for candidate names, cached in the library since they never change.
    public static func phraseVectors(_ names: [String], library: LibraryWriter, encoder: CLIPEncoder, reporter: PipelineReporter) throws -> Matrix {
        let model = CLIPEncoder.modelName
        var have: [String: [Float]] = [:]
        try library.db.read { db in
            var start = 0
            while start < names.count {
                let chunk = Array(names[start..<min(start + 500, names.count)])
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "select phrase, vector from phrase_vec where model = ? and phrase in (\(marks))",
                                            arguments: StatementArguments([model] + chunk)) {
                    have[row["phrase"]] = floats(row["vector"])
                }
                start += 500
            }
        }
        let todo = names.filter { have[$0] == nil }
        if !todo.isEmpty {
            let line = ProgressLine("Reading candidate names", total: todo.count, unit: "names", reporter: reporter)
            try forEachBatch(todo, size: 128, reporter: reporter) { name -> [Float]? in
                var sum = [Float](repeating: 0, count: CLIPEncoder.dimensions)
                for template in RegionLabels.templates {
                    guard let vector = try? encoder.embed(text: template.replacingOccurrences(of: "%@", with: name)) else { return nil }
                    for index in sum.indices { sum[index] += vector[index] }
                }
                let length = max(sum.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
                return sum.map { $0 / length }
            } store: { results in
                try library.db.write { db in
                    for (name, vector) in results {
                        have[name] = vector
                        try db.execute(sql: "insert or replace into phrase_vec(model, phrase, vector) values (?,?,?)", arguments: [model, name, data(vector)])
                    }
                }
            } progress: { line.advance($0) }
        }
        var table = Matrix(rows: names.count, columns: CLIPEncoder.dimensions)
        for (row, name) in names.enumerated() {
            for (column, value) in (have[name] ?? []).enumerated() { table.values[row * table.columns + column] = value }
        }
        return table
    }

    /// `project` in layout.py: UMAP, or something simpler for too few items for it.
    static func project(_ vectors: Matrix, reporter: PipelineReporter) -> [Float] {
        let n = vectors.rows
        if n < 4 { return (0..<n).flatMap { [Float($0), 0] } }
        if n < 16 {
            // PCA, from the table of similarities between the items.
            var centered = vectors
            let mean = vectors.mean(of: Array(0..<n))
            for row in 0..<n { for d in 0..<vectors.columns { centered.values[row * vectors.columns + d] -= mean[d] } }
            let (values, axes) = VectorMath.symmetricEigen(centered.product(transposeOf: centered).values.map(Double.init), n: n)
            var out = [Float](repeating: 0, count: n * 2)
            for row in 0..<n {
                for axis in 0..<2 { out[row * 2 + axis] = Float(axes[row * n + axis] * max(values[axis], 0).squareRoot()) }
            }
            return out
        }
        let k = min(30, n - 1)
        let finding = ProgressLine("Finding what's near what", total: n, unit: "items", reporter: reporter)
        let neighbors = VectorMath.nearest(vectors, k: k + (k == n - 1 ? 1 : 0)) { finding.advance($0 - finding.done) }
        let moving = ProgressLine("Laying out \(n.formatted()) items on the map", total: n <= 10_000 ? 500 : 200, unit: "rounds", reporter: reporter)
        return UMAP.embed(vectors, neighbors: neighbors) { epoch, _ in moving.advance(epoch - moving.done) }
    }

    /// Where each search floats: over the pictures nearest it in meaning, averaged with the
    /// closest counting most, so a search between two subjects hangs between them.
    /// `place_clouds` in layout.py.
    ///
    /// Scored as search by meaning scores (`EmbeddingStore.nearest`), for the same reasons: by
    /// plain similarity every search sat over the land made of words, whatever it was about. So
    /// each search is taken minus the average search, the land under it is pictures alone (the
    /// blended map still keeps words and pictures apart), and scores are in standard deviations.
    /// CLIP vectors, unit length. `near` is positions in `land`, closest first.
    static func placeClouds(_ sky: Matrix, over land: Matrix, hasPicture: [Bool], xy: [Float], k: Int = 8) -> [(x: Float, y: Float, near: [Int32])] {
        let pictures = hasPicture.indices.filter { hasPicture[$0] }
        let under = pictures.isEmpty ? Array(0..<land.rows) : pictures
        guard !under.isEmpty, sky.rows > 0 else { return [] }
        let candidates = land.selecting(under), n = under.count, k = min(k, n)
        let everyday = sky.mean(of: Array(0..<sky.rows))
        var targets = sky
        for row in 0..<sky.rows { for d in 0..<sky.columns { targets.values[row * sky.columns + d] -= everyday[d] } }
        var out = [(x: Float, y: Float, near: [Int32])](repeating: (0, 0, []), count: sky.rows)
        let chunk = 512
        var start = 0
        while start < sky.rows {
            let end = min(start + chunk, sky.rows)
            var scores = targets.selecting(Array(start..<end)).product(transposeOf: candidates)
            let found = LockedResults<(x: Float, y: Float, near: [Int32])>(count: end - start)
            scores.values.withUnsafeMutableBufferPointer { table in
                nonisolated(unsafe) let source = table.baseAddress!
                DispatchQueue.concurrentPerform(iterations: end - start) { row in
                    let line = source + row * n
                    var mean: Float = 0, spread: Float = 0
                    vDSP_normalize(line, 1, line, 1, &mean, &spread, vDSP_Length(n))
                    let scored = UnsafeBufferPointer(start: line, count: n)
                    let near = VectorMath.largest(scored, k: k)
                    let top = scored[Int(near[0])]
                    var (x, y, total) = (Float(0), Float(0), Float(0))
                    for index in near {
                        let item = under[Int(index)]
                        let weight = exp((scored[Int(index)] - top) / 0.3)
                        x += weight * xy[item * 2]
                        y += weight * xy[item * 2 + 1]
                        total += weight
                    }
                    found.set(row, (x / total, y / total, near.map { Int32(under[Int($0)]) }))
                }
            }
            for (row, value) in found.values.enumerated() { out[start + row] = value! }
            start = end
        }
        return out
    }

    /// Lay out and name one map from vectors already in the library. Returns how many items.
    /// Searches stay out of the land and float over it as clouds (`placeClouds`).
    @discardableResult
    public static func computeLayout(library: LibraryWriter, recipe: MapRecipe, clip clipEncoder: CLIPEncoder?, reporter: PipelineReporter) throws -> Int {
        let model = CLIPEncoder.modelName
        try SamePictures.find(library: library, reporter: reporter)
        reporter.progress("Arranging the \(recipe.rawValue) map")
        let (allIDs, allClip, allInfos, wordDimensions, searches, followers) = try library.db.read { db -> ([String], Matrix, [MapVectors.ItemInfo], Int, Set<String>, Set<String>) in
            let searches = Set(try String.fetchAll(db, sql: LibraryWriter.searchOnlySQL))
            // The same picture from elsewhere goes where the one leading it goes.
            let followers = Set(try String.fetchAll(db, sql: "select item_id from same_picture where item_id != lead"))
            var ids: [String] = []
            var values: [Float] = []
            var words: [String: [Float]] = [:]
            var details: [String: (platform: String, text: String?)] = [:]
            for row in try Row.fetchAll(db, sql: "select item_id, vector from embedding where model = ?", arguments: [model]) {
                ids.append(row["item_id"])
                values += floats(row["vector"])
            }
            for row in try Row.fetchAll(db, sql: "select id, platform, text from item") { details[row["id"]] = (row["platform"], row["text"]) }
            let pictures = Set(try String.fetchAll(db, sql: "select distinct item_id from media where status = 'ok'"))
            if recipe.readsWords {
                for row in try Row.fetchAll(db, sql: "select item_id, vector from embedding where model = ?", arguments: [WordsEncoder.modelName]) {
                    words[row["item_id"]] = floats(row["vector"])
                }
            }
            let dimensions = values.count / max(ids.count, 1)
            let infos = ids.map { id in
                MapVectors.ItemInfo(platform: details[id]?.platform ?? "", text: details[id]?.text, hasPicture: pictures.contains(id), words: words[id].map { ArraySlice($0) })
            }
            return (ids, Matrix(rows: ids.count, columns: dimensions, values: values), infos, words.first?.value.count ?? 0, searches, followers)
        }
        let sky = allIDs.indices.filter { searches.contains(allIDs[$0]) }
        let land = allIDs.indices.filter { !searches.contains(allIDs[$0]) && !followers.contains(allIDs[$0]) }
        let ids = land.map { allIDs[$0] }, infos = land.map { allInfos[$0] }
        let clip = land.count == allIDs.count ? allClip : allClip.selecting(land)
        guard !ids.isEmpty else {
            reporter.say("Nothing to map yet.")
            return 0
        }
        if reporter.isCancelled() { throw PipelinePaused() }
        let arranged = MapVectors.arrange(recipe: recipe, clip: clip, items: infos, wordDimensions: wordDimensions)
        var xy = project(arranged, reporter: reporter)
        if reporter.isCancelled() { throw PipelinePaused() }

        // Fit into a 1000 × 1000 square, keeping the aspect ratio (distances on the map mean
        // something) with a margin for the terrain.
        let n = ids.count
        var low = (x: Float.infinity, y: Float.infinity), high = (x: -Float.infinity, y: -Float.infinity)
        for item in 0..<n {
            low = (min(low.x, xy[item * 2]), min(low.y, xy[item * 2 + 1]))
            high = (max(high.x, xy[item * 2]), max(high.y, xy[item * 2 + 1]))
        }
        let span = max(max(high.x - low.x, high.y - low.y), 1e-9)
        for item in 0..<n {
            xy[item * 2] = (xy[item * 2] - (low.x + high.x) / 2) / span * 900 + 500
            xy[item * 2 + 1] = (xy[item * 2 + 1] - (low.y + high.y) / 2) / span * 900 + 500
        }

        reporter.progress("Finding regions")
        let labels = HDBSCAN.regions(xy)
        reporter.progress("Finding nearest neighbors")
        let closest = n > 1 ? VectorMath.nearest(arranged, k: min(9, n)) : VectorMath.Neighbors(k: 1, indices: [0], distances: [0])
        reporter.progress("Nesting regions")
        var (regions, roots) = RegionNesting.build(xy: xy, leaf: labels)
        reporter.progress("Naming \(regions.count.formatted()) regions")
        try RegionLabels.name(regions: &regions, roots: roots, vectors: clip, texts: infos.map(\.text), hasImage: infos.map(\.hasPicture),
                              concepts: RegionLabels.loadConcepts(), modifiers: RegionLabels.loadModifiers(),
                              phraseVectors: clipEncoder.map { encoder in
                                  { try phraseVectors($0, library: library, encoder: encoder, reporter: reporter) }
                              })

        let stored = recipe.layoutModel(base: model)
        try library.db.write { db in
            try db.execute(sql: "delete from layout where model = ?", arguments: [stored])
            try db.execute(sql: "delete from cluster where model = ?", arguments: [stored])
            let insert = try db.makeStatement(sql: "insert into layout(item_id, model, x, y, cluster, neighbors) values (?,?,?,?,?,?)")
            for item in 0..<n {
                let near = (0..<closest.k).compactMap { position -> String? in
                    let other = Int(closest.indices[item * closest.k + position])
                    return other == item ? nil : ids[other]
                }
                try insert.execute(arguments: [ids[item], stored, Double(xy[item * 2]), Double(xy[item * 2 + 1]), labels[item], Pipeline.jsonList(near)])
            }
            for (id, region) in regions {
                let place = RegionNesting.anchor(xy: xy, members: region.members)
                try db.execute(sql: "insert into cluster(model, id, label, terms, parent, depth, x, y, r) values (?,?,?,?,?,?,?,?,?)",
                               arguments: [stored, id, region.label, Pipeline.jsonList(region.terms), region.parent, region.depth, place.x, place.y, place.r])
            }
            try db.execute(sql: "insert into meta(key, value) values('map', ?) on conflict(key) do update set value = excluded.value", arguments: [recipe.rawValue])
        }
        if !sky.isEmpty { reporter.progress("Setting \(sky.count.formatted()) searches over the land") }
        let placed = placeClouds(allClip.selecting(sky), over: clip, hasPicture: infos.map(\.hasPicture), xy: xy)
        try library.db.write { db in
            try db.execute(sql: "delete from cloud where model = ?", arguments: [stored])
            let insert = try db.makeStatement(sql: "insert into cloud(item_id, model, x, y, region, near) values (?,?,?,?,?,?)")
            for (cloud, item) in zip(placed, sky) {
                try insert.execute(arguments: [allIDs[item], stored, Double(cloud.x), Double(cloud.y),
                                               labels[Int(cloud.near[0])], Pipeline.jsonList(cloud.near.map { ids[Int($0)] })])
            }
        }
        let top = roots.sorted { (regions[$0]?.members.count ?? 0) > (regions[$1]?.members.count ?? 0) }.prefix(8).map { regions[$0]?.label ?? "" }
        reporter.say("\(regions.count) regions in \((regions.values.map(\.depth).max() ?? -1) + 1) levels; largest: \(top.joined(separator: ", "))")
        if !sky.isEmpty { reporter.say("\(sky.count.formatted()) searches float over it as clouds.") }
        return n
    }

    /// The map to build: the one asked for, then the one built last. A library mapped before
    /// there was a choice keeps its map until you pick another. A new one gets the suggested one.
    public static func chosenMap(_ asked: MapRecipe?, library: LibraryWriter) throws -> MapRecipe {
        if let asked { return asked }
        if let stored = try library.meta("map"), let recipe = MapRecipe(rawValue: stored) { return recipe }
        let mapped = try library.db.read { try Bool.fetchOne($0, sql: "select exists(select 1 from layout limit 1)") ?? false }
        return WordsEncoder.isInstalled() && !mapped ? .suggested : .pictures
    }

    /// `topograph build`: everything needed to bring one map up to date.
    public static func build(recipe asked: MapRecipe? = nil, library: LibraryWriter, force: Bool = false, reporter: PipelineReporter) throws {
        let recipe = try chosenMap(asked, library: library)
        reporter.progress("Loading the image model (CLIP)")
        let clip = try CLIPEncoder()
        try embedLibrary(library: library, encoder: clip, force: force, reporter: reporter)
        if recipe.readsWords {
            reporter.progress("Loading the text model")
            try embedWords(library: library, encoder: try WordsEncoder(), base: CLIPEncoder.modelName, reporter: reporter)
        }
        try computeLayout(library: library, recipe: recipe, clip: clip, reporter: reporter)
    }
}

extension LibraryWriter {
    /// Clear X's "this post is unavailable" notices stored as text. Returns how many items
    /// turned out to be gone; their stale vectors go, so they leave the map on the next layout.
    @discardableResult
    public func markUnavailable() throws -> Int {
        try db.write { db in
            var ids: [String] = []
            for row in try Row.fetchAll(db, sql: """
                select id, text from item where text like '%{learnmore}%' or text like '%unable to view this%'
                or text like 'This Post %' or text like 'This Tweet %'
                """) where PipelineText.isUnavailable(row["text"]) {
                ids.append(row["id"])
            }
            // Unreachable posts whose only text is a link: nothing left to show.
            for row in try Row.fetchAll(db, sql: """
                select id, text from item where hydrated = -1 and coalesce(text, '') != '' and not exists
                (select 1 from media m where m.item_id = item.id and m.status = 'ok')
                """) where !PipelineText.hasWords(row["text"]) {
                ids.append(row["id"])
            }
            for id in ids {
                try db.execute(sql: """
                    update item set text = null, hydrated = case when exists (select 1 from media m where m.item_id = item.id and m.status = 'ok')
                    then hydrated else -1 end where id = ?
                    """, arguments: [id])
            }
            let gone = try String.fetchAll(db, sql: "select id from item where \(Self.goneSQL)")
            for id in gone {
                try db.execute(sql: "delete from embedding where item_id = ?", arguments: [id])
                try db.execute(sql: "delete from layout where item_id = ?", arguments: [id])
                try db.execute(sql: "delete from cloud where item_id = ?", arguments: [id])
            }
            return gone.count
        }
    }
}
