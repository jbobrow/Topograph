import Accelerate
import Foundation

/// Names for regions. Each is named by the phrase that best tells it apart from its siblings,
/// by two kinds of evidence: how much better a phrase fits its items than its siblings' in CLIP
/// space, in standard deviations, and how much more often the phrase appears in its text.
/// Tuned on the owner's real library; regions.py has the reasoning.
public enum RegionLabels {
    /// Words that make poor names on their own or at the ends of a phrase.
    static let stop: Set<String> = Set("""
a about above after again against all almost also am among an and any are aren't around as at be because
been before being below between both but by can can't cannot could couldn't did didn't do does doesn't
doing don't down during each either else even ever every few for from further had hadn't has hasn't have
haven't having he he'd he'll he's her here here's hers herself him himself his how how's however i i'd
i'll i'm i've if in into is isn't it it's its itself just let's like made make makes many may me might more
most much must mustn't my myself never new no nor not now of off often on once one only or other ought our
ours ourselves out over own per quite rather really same say says she she'd she'll she's should shouldn't
since so some still such than that that's the their theirs them themselves then there there's these they
they'd they'll they're they've thing things this those though through thus to too under until up upon us
very via was wasn't we we'd we'll we're we've well were weren't what what's when when's where where's
whether which while who who's whom whose why why's will with within without won't would wouldn't yet you
you'd you'll you're you've your yours yourself yourselves
amp rt http https www com org net html htm jpg jpeg png gif heic pdf mov mp4 psd ai svg tif tiff webp
img image images photo photos pic pics picture screenshot screen shot copy final draft untitled new old
file files folder version v1 v2 v3 edit edited export exported
im ive dont didnt cant wont thats youre theyre lol lmao omg wow yes yeah ok okay oh hey hi hello thanks
thank please today tonight tomorrow yesterday day days week weeks year years time times ago soon back
got get gets getting go goes going gone went come comes coming came see seen saw look looks looking
want wants need needs know think thought feel love loved loves good great nice best better cool awesome
amazing beautiful pretty fun happy little big lot lots way ways something anything everything nothing
someone anyone everyone people person guy guys thing stuff kind sort first last next right left
wearing wears wear worn sitting sits sit standing stands stand holding holds hold shown showing shows
front background foreground side top bottom near behind together large small two three four five
several various another others different part full whole half update updates added adding arrived
""".split(whereSeparator: \.isWhitespace).map(String.init))

    public static let templates = ["a photo of %@.", "an image of %@.", "%@"]
    private static let maxPhrases = 6000
    private static let weak = 0.5       // a larger region's name must fit it this much better (std devs)
    private static let shrink = 25.0    // picture evidence from n items is scaled by n / (n + 25)
    /// Parents that are a way of making things rather than things: "purple" isn't turned into
    /// "purple macro photography".
    private static let mediums: Set<String> = ["photography", "art", "design", "painting", "drawings", "drawing", "illustration", "prints", "printing", "sketches", "graphics", "renders", "styles"]

    private static func textWeight(_ depth: Int) -> Double {
        // Broad regions lean on what things look like, small ones on specific words found in them.
        depth == 0 ? 0.6 : depth == 1 ? 1.0 : 1.4
    }

    private static let url = PipelineText.regex(#"https?://\S+|www\.\S+"#)
    private static let mention = PipelineText.regex(#"(?<!\w)@\w+"#)
    private static let camel = PipelineText.regex("(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")
    private static let token = PipelineText.regex("[a-z0-9]+(?:'[a-z]+)?")
    private static let hashtag = PipelineText.regex(#"#(\w+)"#)

    private static func replace(_ regex: NSRegularExpression, _ text: String, _ template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func tokenList(_ text: String) -> [String] {
        token.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    public static func tokens(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var clean = replace(mention, replace(url, text, " "), " ")
        let tags = hashtag.matches(in: clean, range: NSRange(clean.startIndex..., in: clean))
        for match in tags.reversed() {
            guard let whole = Range(match.range, in: clean), let word = Range(match.range(at: 1), in: clean) else { continue }
            clean.replaceSubrange(whole, with: " " + replace(camel, String(clean[word]), " ") + " ")
        }
        if clean.reduce(0, { $0 + ($1 == " " ? 1 : 0) }) < 2 { clean = replace(camel, clean, " ") }  // file names like GlyphletSketch
        var out: [String] = []
        for var word in tokenList(clean.lowercased().replacingOccurrences(of: "_", with: " ")) {
            if word.hasSuffix("'s") { word.removeLast(2) }
            if word.utf8.count >= 2 { out.append(word) }
        }
        return out
    }

    private static func isDigits(_ word: String) -> Bool {
        !word.isEmpty && word.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    private static func usable(_ word: String) -> Bool {
        !stop.contains(word) && !isDigits(word) && word.utf8.count >= 2
    }

    /// Phrases of 1–3 words that don't start or end on a filler word.
    public static func ngrams(_ words: [String], longest: Int = 3) -> Set<String> {
        var out = Set<String>()
        guard !words.isEmpty else { return out }
        for length in 1...longest where length <= words.count {
            for start in 0...(words.count - length) {
                let gram = words[start..<(start + length)]
                guard usable(gram.first!), usable(gram.last!) else { continue }
                if gram.contains(where: { isDigits($0) && $0.utf8.count != 4 }) || (length == 1 && gram.first!.utf8.count < 3) { continue }
                out.insert(gram.joined(separator: " "))
            }
        }
        return out
    }

    /// Compare names loosely: case, punctuation and plurals don't make a name new.
    public static func key(_ phrase: String) -> String {
        tokenList(phrase.lowercased().replacingOccurrences(of: "-", with: " ")).map { word in
            word.utf8.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        }.joined(separator: " ")
    }

    /// Candidate names: the concept list plus phrases that recur in your own text.
    /// Returns match keys, what the map shows, and how many came from the concept list.
    static func vocabulary(docs: [Set<String>], concepts: [String]) -> (keys: [String], names: [String], fromConcepts: Int) {
        let withText = docs.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
        var frequency: [String: Int] = [:]
        for doc in docs { for gram in doc { frequency[gram, default: 0] += 1 } }
        let minimum = max(3, Int(Double(withText) * 0.0004))
        let maximum = max(minimum + 1, Int(Double(withText) * 0.12))
        var found = frequency.filter { $0.value >= minimum && $0.value <= maximum }
        // A word that almost only appears inside a longer phrase ("york" in "new york") is
        // better left to the phrase.
        var drop = Set<String>()
        for (gram, count) in found {
            let parts = gram.split(separator: " ")
            guard parts.count > 1 else { continue }
            for length in 1..<parts.count {
                for start in 0...(parts.count - length) {
                    let sub = parts[start..<(start + length)].joined(separator: " ")
                    if let other = found[sub], Double(other) <= Double(count) * 1.25 { drop.insert(sub) }
                }
            }
        }
        for gram in drop { found[gram] = nil }
        let data = found.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(maxPhrases).map(\.key)

        var keys: [String] = [], names: [String] = []
        var seen = Set<String>()
        for concept in concepts {
            let key = tokens(concept).joined(separator: " ")
            if !key.isEmpty, seen.insert(key).inserted {
                keys.append(key)
                names.append(concept)
            }
        }
        let fromConcepts = keys.count
        for gram in data where seen.insert(gram).inserted {
            keys.append(gram)
            names.append(gram)
        }
        return (keys, names, fromConcepts)
    }

    // MARK: Concepts

    private static var conceptsText: String {
        guard let url = Bundle.module.url(forResource: "concepts", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    public static func loadConcepts() -> [String] {
        conceptsText.components(separatedBy: .newlines).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let stripped = PipelineText.strip(line)
            return stripped.isEmpty ? nil : stripped
        }
    }

    /// Phrases in the "look and feel" section, which qualify a region's parent.
    public static func loadModifiers() -> Set<String> {
        var out = Set<String>()
        var inside = false, previous = ""
        for raw in conceptsText.components(separatedBy: .newlines) {
            let line = PipelineText.strip(raw)
            if line.hasPrefix("#") {
                // A section header follows a blank line.
                if previous.isEmpty { inside = line.lowercased().hasPrefix("# look and feel") }
            } else if !line.isEmpty, inside {
                out.insert(line)
            }
            previous = line
        }
        return out
    }

    // MARK: Naming

    /// A weighted mean minus the spread, per phrase. `values` holds one row per sub-region.
    private static func softMin(_ rows: [UnsafePointer<Double>], weights: [Double], count: Int) -> [Double] {
        var mean = [Double](repeating: 0, count: count), spread = mean
        for (row, weight) in zip(rows, weights) { for j in 0..<count { mean[j] += weight * row[j] } }
        for (row, weight) in zip(rows, weights) {
            for j in 0..<count {
                let difference = row[j] - mean[j]
                spread[j] += weight * difference * difference
            }
        }
        for j in 0..<count { mean[j] -= spread[j].squareRoot() }
        return mean
    }

    /// Fill in `label` and `terms` on every region. `phraseVectors` gives a unit vector per
    /// candidate name; without it, regions are named by their words alone.
    public static func name(regions: inout [Int: BuiltRegion], roots: [Int], vectors: Matrix, texts: [String?], hasImage: [Bool],
                            concepts: [String], modifiers: Set<String>, phraseVectors: (([String]) throws -> Matrix)?) throws {
        let n = texts.count
        let docs = texts.map { ngrams(tokens($0)) }
        let (keys, names, fromConceptCount) = vocabulary(docs: docs, concepts: concepts)
        guard !keys.isEmpty else {
            for id in regions.keys { regions[id]?.label = "region \(id + 1)" }
            return
        }
        let phrases = keys.count
        var column: [String: Int32] = [:]
        for (j, key) in keys.enumerated() { column[key] = Int32(j) }
        let docColumns = docs.map { doc in doc.compactMap { column[$0] } }

        let ids = regions.keys.sorted()
        let count = ids.count
        var position: [Int: Int] = [:]
        for (index, id) in ids.enumerated() { position[id] = index }
        let size = ids.map { Double(regions[$0]?.members.count ?? 0) }
        var df = [Double](repeating: 0, count: count * phrases)     // regions × phrases: items mentioning it
        for (index, id) in ids.enumerated() {
            for item in regions[id]?.members ?? [] {
                for j in docColumns[item] { df[index * phrases + Int(j)] += 1 }
            }
        }
        // The whole map stands as the parent of the top-level regions.
        var inAny = [Bool](repeating: false, count: n)
        for root in roots { for item in regions[root]?.members ?? [] { inAny[item] = true } }
        var allDF = [Double](repeating: 0, count: phrases)
        for item in 0..<n where inAny[item] { for j in docColumns[item] { allDF[Int(j)] += 1 } }
        let allSize = Double(inAny.reduce(0) { $0 + ($1 ? 1 : 0) })

        // Pictures: standardized difference in CLIP similarity.
        struct Pictures {
            var visSum: [Double], visAll: [Double], visMean: [Double]
            var imageSize: [Double], imageSum: [Double], imageAll: [Double], imageAllSize: Double, imageMean: [Double]
        }
        var pictures: Pictures?
        if let phraseVectors, vectors.rows > 0 {
            let phraseTable = try phraseVectors(names)
            let dimension = vectors.columns
            var centered = vectors
            // Pictures and text sit in different parts of CLIP space; center each so a region
            // isn't "about" a phrase just because it holds more of one kind.
            for wanted in [true, false] {
                let kind = (0..<n).filter { hasImage[$0] == wanted }
                guard !kind.isEmpty else { continue }
                let mean = vectors.mean(of: kind)
                for item in kind { for d in 0..<dimension { centered.values[item * dimension + d] -= mean[d] } }
            }
            let included = (0..<n).filter { inAny[$0] }
            // Spread of a phrase's similarity over the map: t' Σ t.
            var sigma = [Double](repeating: 1, count: phrases)
            if included.count > 2 {
                var table = centered.selecting(included)
                let mean = table.mean(of: Array(0..<included.count))
                for row in 0..<table.rows { for d in 0..<dimension { table.values[row * dimension + d] -= mean[d] } }
                let projected = table.product(transposeOf: phraseTable)     // items × phrases
                let divisor = Double(included.count - 1)
                for j in 0..<phrases {
                    var sum = 0.0
                    for row in 0..<table.rows {
                        let value = Double(projected.values[row * phrases + j])
                        sum += value * value
                    }
                    sigma[j] = max(sum / divisor, 1e-8).squareRoot()
                }
            }

            func sums(_ members: (Int) -> [Int], rows: Int, keep: (Int) -> Bool) -> [Double] {
                var table = [Double](repeating: 0, count: rows * dimension)
                for row in 0..<rows {
                    for item in members(row) where keep(item) {
                        for d in 0..<dimension { table[row * dimension + d] += Double(centered.values[item * dimension + d]) }
                    }
                }
                return table
            }
            func toPhrases(_ table: [Double], rows: Int) -> [Double] {
                var phraseDoubles = [Double](repeating: 0, count: phrases * dimension)
                for i in phraseDoubles.indices { phraseDoubles[i] = Double(phraseTable.values[i]) }
                var out = [Double](repeating: 0, count: rows * phrases)
                cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(phrases), Int32(dimension), 1, table, Int32(dimension),
                            phraseDoubles, Int32(dimension), 0, &out, Int32(phrases))
                for row in 0..<rows { for j in 0..<phrases { out[row * phrases + j] /= sigma[j] } }
                return out
            }
            let memberLists = ids.map { regions[$0]?.members ?? [] }
            let visSum = toPhrases(sums({ memberLists[$0] }, rows: count) { _ in true }, rows: count)
            let visAll = toPhrases(sums({ _ in included }, rows: 1) { _ in true }, rows: 1)
            var visMean = visSum
            for row in 0..<count { for j in 0..<phrases { visMean[row * phrases + j] /= max(size[row], 1) } }
            // The same, counting only items with pictures. Phrases lifted from your own text are
            // judged on pictures alone: on text items CLIP would mostly be finding the phrase in
            // the text, which the word count already measures.
            let imageSize = memberLists.map { Double($0.reduce(0) { $0 + (hasImage[$1] ? 1 : 0) }) }
            let imageSum = toPhrases(sums({ memberLists[$0] }, rows: count) { hasImage[$0] }, rows: count)
            let imageAll = toPhrases(sums({ _ in included }, rows: 1) { hasImage[$0] }, rows: 1)
            var imageMean = imageSum
            for row in 0..<count { for j in 0..<phrases { imageMean[row * phrases + j] /= max(imageSize[row], 1) } }
            pictures = Pictures(visSum: visSum, visAll: visAll, visMean: visMean, imageSize: imageSize, imageSum: imageSum, imageAll: imageAll,
                                imageAllSize: Double(included.reduce(0) { $0 + (hasImage[$1] ? 1 : 0) }), imageMean: imageMean)
        }

        let shapeBonus = keys.enumerated().map { j, key -> Double in
            let words = min(key.split(separator: " ").count, 3)
            return 0.04 * Double(words - 1) + (j < fromConceptCount ? 0.2 : 0)
        }
        let tooLong = names.map { $0.unicodeScalars.count > 30 }

        func scores(_ id: Int) -> (score: [Double], text: [Double], raw: [Double]) {
            guard let region = regions[id], let i = position[id] else { return ([], [], []) }
            var fIn = [Double](repeating: 0, count: phrases), fOut = fIn, rawIn = fIn
            let parentRow = region.parent.flatMap { position[$0] }
            let parentSize = parentRow.map { size[$0] } ?? allSize
            let rest = max(parentSize - size[i], 1)
            let ownSize = max(size[i], 1)
            for j in 0..<phrases {
                let parentDF = parentRow.map { df[$0 * phrases + j] } ?? allDF[j]
                let own = df[i * phrases + j]
                rawIn[j] = own / ownSize
                fIn[j] = rawIn[j]
                fOut[j] = max(parentDF - own, 0) / rest
            }
            var vIn: [Double]?, gIn: [Double]?
            if let pictures {
                vIn = Array(pictures.visMean[(i * phrases)..<((i + 1) * phrases)])
                gIn = Array(pictures.imageMean[(i * phrases)..<((i + 1) * phrases)])
            }
            if !region.children.isEmpty {
                // A larger region's name should fit all of it, not just its biggest part: judge
                // it by its sub-regions, discounting uneven fit.
                let kids = region.children.compactMap { position[$0] }
                let total = kids.reduce(0.0) { $0 + size[$1] }
                let weights = kids.map { size[$0] / max(total, 1) }
                var kidFractions = [Double](repeating: 0, count: kids.count * phrases)
                for (row, kid) in kids.enumerated() {
                    let kidSize = max(size[kid], 1)
                    for j in 0..<phrases { kidFractions[row * phrases + j] = df[kid * phrases + j] / kidSize }
                }
                let softest = kidFractions.withUnsafeBufferPointer { table in
                    softMin(kids.indices.map { table.baseAddress! + $0 * phrases }, weights: weights, count: phrases)
                }
                for j in 0..<phrases { fIn[j] = min(fIn[j], softest[j]) }
                if let pictures {
                    pictures.visMean.withUnsafeBufferPointer { table in
                        vIn = softMin(kids.map { table.baseAddress! + $0 * phrases }, weights: weights, count: phrases)
                    }
                    let imageTotal = kids.reduce(0.0) { $0 + pictures.imageSize[$1] }
                    let imageWeights = kids.map { pictures.imageSize[$0] / max(imageTotal, 1) }
                    pictures.imageMean.withUnsafeBufferPointer { table in
                        gIn = softMin(kids.map { table.baseAddress! + $0 * phrases }, weights: imageWeights, count: phrases)
                    }
                }
            }
            func arc(_ value: Double) -> Double { 2 * asin(min(max(value, 0), 1).squareRoot()) }
            var text = [Double](repeating: 0, count: phrases)
            var enough = [Bool](repeating: false, count: phrases)
            let needed = max(2, 0.02 * size[i])
            for j in 0..<phrases {
                enough[j] = df[i * phrases + j] >= needed
                if enough[j] { text[j] = max(arc(fIn[j]) - arc(fOut[j]), 0) }
            }
            var vis = [Double](repeating: 0, count: phrases)
            if let pictures, let vIn, let gIn {
                // Small regions' averages are noisy (a handful of near-duplicates fits many
                // phrases "well"), so their picture evidence is shrunk.
                let scale = size[i] / (size[i] + shrink)
                let imageSize = pictures.imageSize[i]
                let parentImageSize = parentRow.map { pictures.imageSize[$0] } ?? pictures.imageAllSize
                let imageRest = max(parentImageSize - imageSize, 1)
                let imageScale = imageSize / (imageSize + shrink) * min(1, imageSize / max(size[i], 1) * 1.5)
                for j in 0..<phrases {
                    if j < fromConceptCount {
                        let parentVis = parentRow.map { pictures.visSum[$0 * phrases + j] } ?? pictures.visAll[j]
                        let outMean = (parentVis - pictures.visSum[i * phrases + j]) / rest
                        vis[j] = (0.65 * (vIn[j] - outMean) + 0.35 * vIn[j]) * scale
                    } else if imageSize >= 5 {
                        let parentImage = parentRow.map { pictures.imageSum[$0 * phrases + j] } ?? pictures.imageAll[j]
                        let outMean = (parentImage - pictures.imageSum[i * phrases + j]) / imageRest
                        vis[j] = (0.65 * (gIn[j] - outMean) + 0.35 * gIn[j]) * imageScale
                    }
                }
            }
            var score = [Double](repeating: 0, count: phrases)
            let weight = textWeight(region.depth)
            for j in 0..<phrases {
                // Your own words only name a region they actually turn up in.
                let blocked = (j >= fromConceptCount && !(enough[j] && rawIn[j] > fOut[j])) || tooLong[j]
                score[j] = blocked ? -.infinity : weight * text[j] + vis[j] + shapeBonus[j]
            }
            return (score, text, vis)
        }

        var used = Set<String>()
        func ancestors(_ id: Int) -> [String] {
            var out: [String] = []
            var parent = regions[id]?.parent
            while let current = parent {
                out.append(regions[current]?.label ?? "")
                parent = regions[current]?.parent
            }
            return out
        }
        func clashes(_ name: String, _ id: Int) -> Bool {
            let own = key(name)
            if used.contains(own) { return true }
            for ancestor in ancestors(id) {
                let other = key(ancestor)
                if other.isEmpty { continue }
                if own == other || " \(own) ".contains(" \(other) ") || " \(other) ".contains(" \(own) ") { return true }
            }
            return false
        }
        // A look ("purple", "pastel colors") under a thing ("orchids") reads "purple orchids".
        func qualify(_ name: String, _ id: Int) -> String {
            guard modifiers.contains(name), let parentID = regions[id]?.parent else { return name }
            let parent = regions[parentID]?.label ?? ""
            let words = parent.split(separator: " ").map(String.init)
            if parent.isEmpty || modifiers.contains(parent) || parent.contains("+") || words.count > 2 || !mediums.isDisjoint(with: words) { return name }
            let word = name.hasSuffix(" colors") ? String(name.dropLast(" colors".count)) : name
            return "\(word) \(parent)"
        }
        func bestFirst(_ values: [Double], limit: Int) -> [Int] {
            var kept: [(value: Double, index: Int)] = []
            for (index, value) in values.enumerated() {
                if kept.count == limit, value <= kept[limit - 1].value { continue }
                var at = kept.count
                while at > 0, kept[at - 1].value < value { at -= 1 }
                kept.insert((value, index), at: at)
                if kept.count > limit { kept.removeLast() }
            }
            return kept.map(\.index)
        }

        let depths = Set(ids.compactMap { regions[$0]?.depth }).sorted()
        for depth in depths {
            let level = ids.filter { regions[$0]?.depth == depth }.sorted { (regions[$0]?.members.count ?? 0) > (regions[$1]?.members.count ?? 0) }
            var options: [(score: Double, id: Int, phrase: Int)] = []
            var textScores: [Int: [Double]] = [:], fit: [Int: [Double]] = [:]
            for id in level {
                let (score, text, raw) = scores(id)
                textScores[id] = text
                fit[id] = raw
                for j in bestFirst(score, limit: 80) where score[j].isFinite { options.append((score[j], id, j)) }
            }
            options.sort { $0.score > $1.score }
            var done = Set<Int>()
            for (score, id, j) in options where !done.contains(id) {
                let name = qualify(names[j], id)
                if used.contains(key(name)) || (name == names[j] && clashes(name, id)) { continue }
                if regions[id]?.children.isEmpty == false, (fit[id]?[j] ?? 0) < weak, (textScores[id]?[j] ?? 0) < 0.8 {
                    continue    // nothing in common enough: named after its parts below
                }
                regions[id]?.label = name
                regions[id]?.score = score
                used.insert(key(name))
                done.insert(id)
            }
            for id in level {
                if !done.contains(id) {
                    let hasParts = regions[id]?.children.isEmpty == false
                    regions[id]?.label = hasParts ? "" : "region \(id + 1)"
                    regions[id]?.score = -1
                }
                let text = textScores[id] ?? []
                let own = key(regions[id]?.label ?? "")
                let terms = bestFirst(text, limit: 12).filter { text[$0] > 0 && key(names[$0]) != own }.map { names[$0] }
                regions[id]?.terms = Array(terms.prefix(6))
            }
        }
        // A large region with nothing in common to name it by is called after its two largest parts.
        for id in ids.sorted(by: { (regions[$0]?.depth ?? 0) > (regions[$1]?.depth ?? 0) }) {
            guard let region = regions[id], !region.children.isEmpty, region.label.isEmpty else { continue }
            let current = regions
            let kids = region.children.sorted { (current[$0]?.members.count ?? 0) > (current[$1]?.members.count ?? 0) }.prefix(2)
            let label = kids.map { current[$0]?.label ?? "" }.joined(separator: " + ")
            regions[id]?.label = label
        }
    }
}
