import Foundation

/// Text to the 77 token numbers CLIP reads, the way OpenCLIP's SimpleTokenizer does it.
///
/// The one thing left out is ftfy's repair of mis-decoded text (mojibake), which is large
/// and rarely matters; everything else ftfy does by default is here.
public struct CLIPTokenizer: Sendable {
    public static let contextLength = 77
    private static let startOfText: Int32 = 49406
    private static let endOfText: Int32 = 49407

    private struct Merge: Sendable {
        let rank: Int32
        let token: Int32
    }

    /// A byte's token mid-word; the token at the end of a word is 256 higher.
    private let tokenOfByte: [Int32]
    /// Two adjacent tokens, packed into one number, and what they merge into.
    private let merges: [UInt64: Merge]
    private let entities: [String: [Unicode.Scalar]]

    public init() throws {
        guard let mergesURL = Bundle.module.url(forResource: "clip-merges", withExtension: "txt"),
              let entitiesURL = Bundle.module.url(forResource: "html-entities", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Printable characters stand for bytes, so the vocabulary is plain text.
        var bytes = Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var characters = bytes
        var extra = 0
        for byte in 0..<256 where !bytes.contains(byte) {
            bytes.append(byte)
            characters.append(256 + extra)
            extra += 1
        }
        var tokenOfByte = [Int32](repeating: 0, count: 256)
        var tokenOfSymbol: [String: Int32] = [:]
        tokenOfSymbol.reserveCapacity(50000)
        for (position, byte) in bytes.enumerated() {
            let symbol = String(Unicode.Scalar(UInt32(characters[position]))!)
            tokenOfByte[byte] = Int32(position)
            tokenOfSymbol[symbol] = Int32(position)
            tokenOfSymbol[symbol + "</w>"] = Int32(position + 256)
        }

        var merges: [UInt64: Merge] = [:]
        merges.reserveCapacity(50000)
        var next = Int32(512)
        for (rank, line) in try String(contentsOf: mergesURL, encoding: .utf8).split(separator: "\n").enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let first = tokenOfSymbol[String(parts[0])], let second = tokenOfSymbol[String(parts[1])] else { continue }
            tokenOfSymbol[String(parts[0] + parts[1])] = next
            merges[Self.pair(first, second)] = Merge(rank: Int32(rank), token: next)
            next += 1
        }
        self.tokenOfByte = tokenOfByte
        self.merges = merges

        var entities: [String: [Unicode.Scalar]] = [:]
        entities.reserveCapacity(2300)
        for line in try String(contentsOf: entitiesURL, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            entities[String(parts[0])] = parts[1].split(separator: " ").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        }
        self.entities = entities
    }

    private static func pair(_ first: Int32, _ second: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: first)) << 32 | UInt64(UInt32(bitPattern: second))
    }

    /// Always `contextLength` numbers, padded with zeros.
    public func tokens(_ text: String) -> [Int32] {
        var out: [Int32] = [Self.startOfText]
        encode(clean(text), into: &out)
        out.append(Self.endOfText)
        if out.count > Self.contextLength {
            out.removeLast(out.count - Self.contextLength)
            out[Self.contextLength - 1] = Self.endOfText
        }
        out.append(contentsOf: repeatElement(0, count: Self.contextLength - out.count))
        return out
    }

    // MARK: Splitting into words

    private func encode(_ text: [Unicode.Scalar], into out: inout [Int32]) {
        var at = 0
        while at < text.count {
            let scalar = text[at]
            if Self.isSpace(scalar) {
                at += 1
            } else if let special = Self.specialToken(in: text, at: at) {
                out.append(special.token)
                at += special.length
            } else if let length = Self.contraction(in: text, at: at) {
                bpe(text[at..<(at + length)], into: &out)
                at += length
            } else if Self.isLetter(scalar) {
                let start = at
                while at < text.count, Self.isLetter(text[at]) { at += 1 }
                bpe(text[start..<at], into: &out)
            } else if Self.isNumber(scalar) {
                bpe(text[at..<(at + 1)], into: &out)
                at += 1
            } else {
                let start = at
                while at < text.count, !Self.isSpace(text[at]), !Self.isLetter(text[at]), !Self.isNumber(text[at]) { at += 1 }
                bpe(text[start..<at], into: &out)
            }
        }
    }

    private static let specials: [(name: [Unicode.Scalar], token: Int32)] = [
        (Array("<start_of_text>".unicodeScalars), startOfText),
        (Array("<end_of_text>".unicodeScalars), endOfText),
    ]

    private static func specialToken(in text: [Unicode.Scalar], at: Int) -> (token: Int32, length: Int)? {
        guard text[at] == "<" else { return nil }
        for special in specials where text[at...].starts(with: special.name) {
            return (special.token, special.name.count)
        }
        return nil
    }

    private static let contractions: [[Unicode.Scalar]] = ["'s", "'t", "'re", "'ve", "'m", "'ll", "'d"].map { Array($0.unicodeScalars) }

    private static func contraction(in text: [Unicode.Scalar], at: Int) -> Int? {
        guard text[at] == "'" else { return nil }
        return contractions.first { text[at...].starts(with: $0) }?.count
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return (scalar.value | 0x20) >= 0x61 && (scalar.value | 0x20) <= 0x7A }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return scalar.value >= 0x30 && scalar.value <= 0x39 }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// What Python's `str.split()` splits on, which is a little more than Unicode's White_Space.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (scalar.value >= 0x1C && scalar.value <= 0x1F)
    }

    // MARK: Byte-pair encoding

    /// Start from one token per byte, then keep merging the adjacent pair learned earliest.
    private func bpe(_ word: ArraySlice<Unicode.Scalar>, into out: inout [Int32]) {
        var symbols: [Int32] = []
        for scalar in word {
            for byte in UTF8.encode(scalar)! { symbols.append(tokenOfByte[Int(byte)]) }
        }
        symbols[symbols.count - 1] += 256
        while symbols.count > 1 {
            var best: Merge?
            for index in 0..<(symbols.count - 1) {
                if let merge = merges[Self.pair(symbols[index], symbols[index + 1])], merge.rank < best?.rank ?? .max {
                    best = merge
                }
            }
            guard let best else { break }
            var merged: [Int32] = []
            merged.reserveCapacity(symbols.count)
            var index = 0
            while index < symbols.count {
                if index + 1 < symbols.count, merges[Self.pair(symbols[index], symbols[index + 1])]?.token == best.token {
                    merged.append(best.token)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }
        out.append(contentsOf: symbols)
    }

    // MARK: Cleaning, as ftfy and html.unescape do

    private func clean(_ text: String) -> [Unicode.Scalar] {
        var scalars = fixText(Array(text.unicodeScalars))
        scalars = unescapeHTML(unescapeHTML(scalars))
        // Collapse runs of space and lowercase, like " ".join(text.split()).lower().
        var words = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in scalars {
            if Self.isSpace(scalar) {
                pendingSpace = !words.isEmpty
            } else {
                if pendingSpace { words.append(" ") }
                pendingSpace = false
                words.append(scalar)
            }
        }
        return Array(Self.lowered(String(words)).unicodeScalars)
    }

    /// Like Python's `lower()`, which unlike Swift's also spells a word-final sigma as ς.
    private static func lowered(_ text: String) -> String {
        guard text.unicodeScalars.contains("Σ") else { return text.lowercased() }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            guard scalar == "Σ" else {
                out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
                continue
            }
            func cased(_ indices: some Sequence<Int>) -> Bool {
                for other in indices {
                    if scalars[other].properties.isCaseIgnorable { continue }
                    return scalars[other].properties.isCased
                }
                return false
            }
            let isFinal = cased((0..<index).reversed()) && !cased((index + 1)..<scalars.count)
            out.append(isFinal ? "ς" : "σ")
        }
        return String(out)
    }

    /// ftfy's default fixes, repeated until they change nothing.
    private func fixText(_ start: [Unicode.Scalar]) -> [Unicode.Scalar] {
        // ftfy leaves entities alone in text that looks like HTML; html.unescape still gets them.
        let unescapes = !start.contains("<")
        var text = start
        while true {
            var next = unescapes ? unescapeHTML(text, semicolonsOnly: true) : text
            next = Self.removeTerminalEscapes(next)
            var fixed: [Unicode.Scalar] = []
            fixed.reserveCapacity(next.count)
            var index = 0
            while index < next.count {
                let scalar = next[index]
                index += 1
                if scalar == "\r" {
                    if index < next.count, next[index] == "\n" { index += 1 }
                    fixed.append("\n")
                } else {
                    Self.fix(scalar, into: &fixed)
                }
            }
            let composed = Array(String(String.UnicodeScalarView(fixed)).precomposedStringWithCanonicalMapping.unicodeScalars)
            if composed == text { return composed }
            text = composed
        }
    }

    private static func removeTerminalEscapes(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard text.contains("\u{1B}") else { return text }
        var out: [Unicode.Scalar] = []
        var index = 0
        while index < text.count {
            if text[index] == "\u{1B}", index + 1 < text.count, text[index + 1] == "[" {
                var end = index + 2
                while end < text.count, text[end] == ";" || (text[end].value >= 0x30 && text[end].value <= 0x39) { end += 1 }
                if end < text.count, text[end].isASCII, (text[end].value | 0x20) >= 0x61, (text[end].value | 0x20) <= 0x7A {
                    index = end + 1
                    continue
                }
            }
            out.append(text[index])
            index += 1
        }
        return out
    }

    /// Windows-1252's characters for C1 controls that have one (U+0080–U+009F).
    private static let windows1252: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160, 0x2039, 0x152, 0x8D, 0x17D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178,
    ]

    private static let ligatures: [UInt32: String] = [
        0x132: "IJ", 0x133: "ij", 0x149: "ʼn", 0x1F1: "DZ", 0x1F2: "Dz", 0x1F3: "dz", 0x1C4: "DŽ", 0x1C5: "Dž", 0x1C6: "dž",
        0x1C7: "LJ", 0x1C8: "Lj", 0x1C9: "lj", 0x1CA: "NJ", 0x1CB: "Nj", 0x1CC: "nj",
        0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi", 0xFB04: "ffl", 0xFB05: "ſt", 0xFB06: "st",
    ]

    private static func fix(_ start: Unicode.Scalar, into out: inout [Unicode.Scalar]) {
        var scalar = start
        if scalar.value >= 0x80, scalar.value <= 0x9F {
            scalar = Unicode.Scalar(windows1252[Int(scalar.value - 0x80)])!
        }
        let value = scalar.value
        if let ligature = ligatures[value] {
            out.append(contentsOf: ligature.unicodeScalars)
        } else if value == 0x3000 {
            out.append(" ")
        } else if value >= 0xFF01, value < 0xFFF0 {
            // Halfwidth and fullwidth forms.
            out.append(contentsOf: String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars)
        } else if value == 0x2BC || (value >= 0x2018 && value <= 0x201B) {
            out.append("'")
        } else if value >= 0x201C, value <= 0x201F {
            out.append("\"")
        } else if value == 0x2028 || value == 0x2029 || value == 0x85 {
            out.append("\n")
        } else if value <= 0x08 || value == 0x0B || (value >= 0x0E && value <= 0x1F) || value == 0x7F
                    || (value >= 0x206A && value <= 0x206F) || value == 0xFEFF || (value >= 0xFFF9 && value <= 0xFFFC) {
            // Control characters are dropped.
        } else {
            out.append(scalar)
        }
    }

    /// Python's `html.unescape` on a whole string, for pages fetched when hydrating.
    func unescaped(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: unescapeHTML(Array(text.unicodeScalars)))
        return String(out)
    }

    /// Python's `html.unescape`; ftfy's stricter version takes only entities that end in `;`.
    private func unescapeHTML(_ text: [Unicode.Scalar], semicolonsOnly: Bool = false) -> [Unicode.Scalar] {
        guard text.contains("&") else { return text }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(text.count)
        var index = 0
        while index < text.count {
            let scalar = text[index]
            index += 1
            guard scalar == "&", index < text.count else {
                out.append(scalar)
                continue
            }
            if text[index] == "#" {
                if let (number, end) = Self.numericReference(text, after: index + 1), !semicolonsOnly || text[end - 1] == ";" {
                    out.append(contentsOf: Self.character(forReference: number))
                    index = end
                } else {
                    out.append(scalar)
                }
                continue
            }
            var end = index
            while end < text.count, end - index < 32, !Self.endsEntityName(text[end]) { end += 1 }
            if end < text.count, text[end] == ";" { end += 1 }
            guard end > index else {
                out.append(scalar)
                continue
            }
            let name = String(String.UnicodeScalarView(text[index..<end]))
            if let value = entities[name], !semicolonsOnly || name.hasSuffix(";") {
                out.append(contentsOf: value)
                index = end
            } else if !semicolonsOnly, let (value, used) = longestEntity(in: text[index..<end]) {
                out.append(contentsOf: value)
                index += used
            } else {
                out.append(scalar)
            }
        }
        return out
    }

    private static func endsEntityName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\n", "\u{0C}", " ", "<", "&", "#", ";": return true
        default: return false
        }
    }

    /// A name with no `;` can still begin with one of the old entities: `&para=3` is ¶=3.
    private func longestEntity(in name: ArraySlice<Unicode.Scalar>) -> ([Unicode.Scalar], Int)? {
        var length = name.count - 1
        while length > 1 {
            let prefix = String(String.UnicodeScalarView(name.prefix(length)))
            if let value = entities[prefix] { return (value, length) }
            length -= 1
        }
        return nil
    }

    private static func numericReference(_ text: [Unicode.Scalar], after start: Int) -> (UInt32, Int)? {
        var at = start
        var radix: UInt64 = 10
        if at < text.count, text[at] == "x" || text[at] == "X" {
            radix = 16
            at += 1
        }
        let digits = at
        var number: UInt64 = 0
        while at < text.count, text[at].isASCII, let digit = Character(text[at]).hexDigitValue, UInt64(digit) < radix {
            number = min(number * radix + UInt64(digit), 0x200000)
            at += 1
        }
        guard at > digits else { return nil }
        if at < text.count, text[at] == ";" { at += 1 }
        return (UInt32(number), at)
    }

    private static func character(forReference number: UInt32) -> [Unicode.Scalar] {
        switch number {
        case 0: return ["\u{FFFD}"]
        case 0x0D: return ["\r"]
        case 0x80...0x9F:
            return [Unicode.Scalar(windows1252[Int(number - 0x80)])!]
        case 0xD800...0xDFFF, 0x110000...: return ["\u{FFFD}"]
        case 0x1...0x8, 0xB, 0xE...0x1F, 0x7F, 0xFDD0...0xFDEF: return []
        default:
            if number & 0xFFFE == 0xFFFE { return [] }
            return Unicode.Scalar(number).map { [$0] } ?? []
        }
    }
}
