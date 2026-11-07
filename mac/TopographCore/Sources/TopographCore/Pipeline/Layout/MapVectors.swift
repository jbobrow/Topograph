import Foundation

/// What each map is laid out from: the same items, arranged different ways. See maps.py.
///
///   pictures  The CLIP vectors alone: mostly how things look.
///   words     CLIP plus a text model. CLIP puts text and pictures in different parts of its
///             space, so each kind's own average is taken away first.
///   blended   Words, then your files are moved toward posts about the same thing. Without
///             this, files gather in their own regions: a screenshot or a CAD render looks
///             unlike anything posted.
public enum MapVectors {
    /// Filename parts that say nothing about what a file is.
    private static let generic: Set<String> = Set("img image images dsc dscn photo photos pic screenshot simulator screen shot untitled copy final crop draft render export pxl mov video assets asset".split(separator: " ").map(String.init))
    private static let camel = PipelineText.regex("([a-z])([A-Z])")
    private static let separators = PipelineText.regex(#"[\s_\-.,()\[\]]+"#)
    private static let links = PipelineText.regex(#"https?://\S+"#)
    private static let repost = PipelineText.regex(#"^RT @\w+:?"#)
    private static let handles = PipelineText.regex(#"[.]?@\w+"#)
    private static let spaces = PipelineText.regex(#"\s+"#)

    private static func replace(_ regex: NSRegularExpression, _ text: String, _ template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func fileWords(_ part: String) -> [String] {
        let spaced = replace(camel, part, "$1 $2")
        let pieces = replace(separators, spaced, "\u{0}").components(separatedBy: "\u{0}")
        return pieces.filter { word in
            !word.isEmpty && !generic.contains(word.lowercased()) && !word.contains(where: \.isNumber)
        }
    }

    /// A file's text is "<name>, in <folder>". Keep the words in it that mean something.
    static func cleanFileText(_ text: String) -> String {
        let parts = text.components(separatedBy: ", in ")
        let name = parts[0]
        let folder = parts.count > 1 ? parts.dropFirst().joined(separator: ", in ") : ""
        return (fileWords(name) + fileWords(folder)).joined(separator: " ")
    }

    /// A post's words, without the links and handles that don't say what it's about.
    static func cleanPostText(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&lt;", with: "<")
        out = replace(links, out, " ")
        out = replace(repost, out, " ")
        out = replace(handles, out, " ")
        out = out.replacingOccurrences(of: "#", with: " ")
        return PipelineText.strip(replace(spaces, out, " "))
    }

    public static func cleanText(platform: String, text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return platform == "files" ? cleanFileText(text) : cleanPostText(text)
    }

    /// A sentence says more than a filename, and a word or two says too little to count.
    static func wordsWeight(wordCount: Int, isFile: Bool) -> Float {
        if wordCount < 2 { return 0 }
        let weight = min(1, 0.3 + Double(wordCount - 2) / 18 * 0.7)
        return Float(isFile ? min(weight, 0.6) : weight)
    }

    /// Move files toward posts about the same thing, leaving posts where they are. Where a
    /// file and a post each count the other among their closest, they're taken to be about
    /// the same thing. Each file then moves by the average of the differences of the pairs near
    /// it, so what's shared lines up, and what only your files have keeps its shape.
    static func pullFilesToPosts(_ vectors: Matrix, isFile: [Bool], k: Int = 20, near: Int = 50) -> Matrix {
        let files = isFile.indices.filter { isFile[$0] }, posts = isFile.indices.filter { !isFile[$0] }
        let k = min(k, files.count, posts.count)
        guard k >= 1 else { return vectors }
        let dimension = vectors.columns
        let fileRows = vectors.selecting(files), postRows = vectors.selecting(posts)

        func closest(_ from: Matrix, _ to: Matrix) -> [Int32] {
            var out = [Int32](repeating: 0, count: from.rows * k)
            var start = 0
            while start < from.rows {
                let end = min(start + 2000, from.rows)
                let similarity = from.selecting(Array(start..<end)).product(transposeOf: to)
                similarity.values.withUnsafeBufferPointer { table in
                    out.withUnsafeMutableBufferPointer { out in
                        nonisolated(unsafe) let target = out.baseAddress!
                        nonisolated(unsafe) let source = table.baseAddress!
                        let columns = to.rows
                        DispatchQueue.concurrentPerform(iterations: end - start) { row in
                            let top = VectorMath.largest(UnsafeBufferPointer(start: source + row * columns, count: columns), k: k)
                            for (position, index) in top.enumerated() { target[(start + row) * k + position] = index }
                        }
                    }
                }
                start = end
            }
            return out
        }
        let fromFiles = closest(fileRows, postRows), fromPosts = closest(postRows, fileRows)
        var shift = [Float](repeating: 0, count: files.count * dimension)
        var pairs = [Int32](repeating: 0, count: files.count)
        for file in files.indices {
            for position in 0..<k {
                let post = Int(fromFiles[file * k + position])
                let back = fromPosts[(post * k)..<((post + 1) * k)]
                guard back.contains(Int32(file)) else { continue }
                for d in 0..<dimension {
                    shift[file * dimension + d] += postRows.values[post * dimension + d] - fileRows.values[file * dimension + d]
                }
                pairs[file] += 1
            }
        }
        let anchors = files.indices.filter { pairs[$0] > 0 }
        guard !anchors.isEmpty else { return vectors }
        var shifts = Matrix(rows: anchors.count, columns: dimension)
        for (row, anchor) in anchors.enumerated() {
            for d in 0..<dimension { shifts.values[row * dimension + d] = shift[anchor * dimension + d] / Float(pairs[anchor]) }
        }
        let places = fileRows.selecting(anchors)
        let nearCount = min(near, anchors.count)
        var moved = vectors
        var start = 0
        while start < files.count {
            let end = min(start + 2000, files.count)
            let similarity = fileRows.selecting(Array(start..<end)).product(transposeOf: places)
            var additions = [Float](repeating: 0, count: (end - start) * dimension)
            similarity.values.withUnsafeBufferPointer { table in
                additions.withUnsafeMutableBufferPointer { additions in
                    shifts.values.withUnsafeBufferPointer { shifts in
                        nonisolated(unsafe) let source = table.baseAddress!
                        nonisolated(unsafe) let target = additions.baseAddress!
                        nonisolated(unsafe) let shiftTable = shifts.baseAddress!
                        let columns = places.rows
                        DispatchQueue.concurrentPerform(iterations: end - start) { row in
                            let line = UnsafeBufferPointer(start: source + row * columns, count: columns)
                            let nearest = VectorMath.largest(line, k: nearCount)
                            let best = line[Int(nearest[0])]
                            var weights = nearest.map { exp((line[Int($0)] - best) / 0.05) }
                            let sum = weights.reduce(0, +)
                            for index in weights.indices { weights[index] /= sum }
                            for (index, anchor) in nearest.enumerated() {
                                for d in 0..<dimension {
                                    target[row * dimension + d] += shiftTable[Int(anchor) * dimension + d] * weights[index]
                                }
                            }
                        }
                    }
                }
            }
            for row in 0..<(end - start) {
                let item = files[start + row]
                for d in 0..<dimension { moved.values[item * dimension + d] += additions[row * dimension + d] }
            }
            start = end
        }
        return moved.unitRows
    }

    public struct ItemInfo: Sendable {
        public var platform: String
        public var text: String?
        public var hasPicture: Bool
        public var words: ArraySlice<Float>?

        public init(platform: String, text: String?, hasPicture: Bool, words: ArraySlice<Float>?) {
            self.platform = platform
            self.text = text
            self.hasPicture = hasPicture
            self.words = words
        }
    }

    /// What a map is laid out from, in the same order as `clip`.
    public static func arrange(recipe: MapRecipe, clip: Matrix, items: [ItemInfo], wordDimensions: Int) -> Matrix {
        if recipe == .pictures { return clip }
        let n = clip.rows, dimension = clip.columns
        var aligned = clip
        for wanted in [true, false] {
            let kind = (0..<n).filter { items[$0].hasPicture == wanted }
            guard !kind.isEmpty else { continue }
            let mean = clip.mean(of: kind)
            for item in kind { for d in 0..<dimension { aligned.values[item * dimension + d] -= mean[d] } }
        }
        aligned = aligned.unitRows
        var mixed = Matrix(rows: n, columns: dimension + wordDimensions)
        for item in 0..<n {
            let target = item * mixed.columns
            for d in 0..<dimension { mixed.values[target + d] = aligned.values[item * dimension + d] }
            guard let words = items[item].words else { continue }
            let count = cleanText(platform: items[item].platform, text: items[item].text).split(whereSeparator: \.isWhitespace).count
            let weight = wordsWeight(wordCount: count, isFile: items[item].platform == "files")
            for (d, value) in words.enumerated() { mixed.values[target + dimension + d] = value * weight }
        }
        mixed = mixed.unitRows
        return recipe == .blended ? pullFilesToPosts(mixed, isFile: items.map { $0.platform == "files" }) : mixed
    }
}
