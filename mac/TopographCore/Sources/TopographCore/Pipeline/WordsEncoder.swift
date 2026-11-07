import CoreML
import Foundation

/// BERT's tokenizer for all-MiniLM-L6-v2: lowercased, accents gone, split at spaces and
/// punctuation, then each word into the longest pieces the vocabulary knows.
public struct WordsTokenizer: Sendable {
    public static let maxTokens = 256
    private static let maxWordLength = 100
    private let vocabulary: [String: Int32]
    private let unknown: Int32
    private let start: Int32
    private let end: Int32

    public init(vocabulary text: String) {
        var table: [String: Int32] = [:]
        table.reserveCapacity(31000)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            table[String(line)] = Int32(index)
        }
        vocabulary = table
        unknown = table["[UNK]"] ?? 100
        start = table["[CLS]"] ?? 101
        end = table["[SEP]"] ?? 102
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
        let category = scalar.properties.generalCategory
        return category == .control || category == .format
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar.properties.generalCategory == .spaceSeparator
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F: true
        default: false
        }
    }

    private func words(_ text: String) -> [String] {
        // Clean first, then accents, then case, as BertNormalizer goes.
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || Self.isControl(scalar) { continue }
            if Self.isSpace(scalar) {
                cleaned.append(" ")
            } else if Self.isCJK(scalar) {
                cleaned.append(" ")
                cleaned.append(scalar)
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        let decomposed = String(cleaned).decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }
        let lowered = String(String.UnicodeScalarView(decomposed)).lowercased()
        var out: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                out.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        for scalar in lowered.unicodeScalars {
            if Self.isSpace(scalar) {
                flush()
            } else if Self.isPunctuation(scalar) {
                flush()
                out.append(String(scalar))
            } else {
                current.append(scalar)
            }
        }
        flush()
        return out
    }

    /// With [CLS] and [SEP], at most 256 in all.
    public func tokens(_ text: String) -> [Int32] {
        var out: [Int32] = [start]
        for word in words(text) {
            let scalars = Array(word.unicodeScalars)
            if scalars.count > Self.maxWordLength {
                out.append(unknown)
            } else {
                var pieces: [Int32] = []
                var position = 0
                var failed = false
                while position < scalars.count {
                    var finish = scalars.count
                    var found: Int32?
                    while finish > position {
                        var piece = String(String.UnicodeScalarView(scalars[position..<finish]))
                        if position > 0 { piece = "##" + piece }
                        if let token = vocabulary[piece] {
                            found = token
                            break
                        }
                        finish -= 1
                    }
                    guard let found else {
                        failed = true
                        break
                    }
                    pieces.append(found)
                    position = finish
                }
                if failed { out.append(unknown) } else { out += pieces }
            }
            if out.count >= Self.maxTokens - 1 { break }
        }
        return Array(out.prefix(Self.maxTokens - 1)) + [end]
    }
}

/// The text model for the maps that read words. CLIP reads text too, but it's built to match
/// captions to pictures, not to tell what a sentence is about. Vectors are comparable with the
/// ones the Python pipeline stores under `minilm-l6-v2`.
public final class WordsEncoder: @unchecked Sendable {
    public static let modelName = "minilm-l6-v2"
    public static let dimensions = 384

    public static var defaultFolder: URL {
        CLIPEncoder.defaultFolder.deletingLastPathComponent().appending(path: modelName, directoryHint: .isDirectory)
    }

    public static func isInstalled(at folder: URL = defaultFolder) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: folder.appending(path: "text.mlmodelc").path)
            && manager.fileExists(atPath: folder.appending(path: "vocab.txt").path)
    }

    public let tokenizer: WordsTokenizer
    private let model: MLModel

    public init(folder: URL = WordsEncoder.defaultFolder, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard Self.isInstalled(at: folder) else { throw CLIPError.modelNotFound(folder) }
        tokenizer = WordsTokenizer(vocabulary: try String(contentsOf: folder.appending(path: "vocab.txt"), encoding: .utf8))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: folder.appending(path: "text.mlmodelc"), configuration: configuration)
    }

    /// A unit vector for some text.
    public func embed(_ text: String) throws -> [Float] {
        let tokens = tokenizer.tokens(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        array.withUnsafeMutableBufferPointer(ofType: Int32.self) { out, _ in
            for index in tokens.indices { out[index] = tokens[index] }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: array)])
        guard let output = try model.prediction(from: provider).featureValue(for: "embedding")?.multiArrayValue else { throw CLIPError.noOutput }
        var vector = [Float](repeating: 0, count: Self.dimensions)
        output.withUnsafeBufferPointer(ofType: Float.self) { source in
            for index in vector.indices { vector[index] = source[index] }
        }
        return vector
    }
}
