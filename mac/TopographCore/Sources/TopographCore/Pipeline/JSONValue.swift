import Foundation

/// JSON that keeps its keys in order. `JSONSerialization` doesn't, and the Instagram importer
/// takes the first link or name it walks past, so order decides what an item ends up with.
public indirect enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public struct Malformed: Error, LocalizedError {
        public let offset: Int
        public var errorDescription: String? { "Malformed JSON at byte \(offset)." }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var text = text
        return try text.withUTF8 { bytes in
            var parser = Parser(bytes: bytes)
            let value = try parser.value()
            parser.skipSpace()
            guard parser.at == bytes.count else { throw Malformed(offset: parser.at) }
            return value
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.last { $0.key == key }?.value
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var isObject: Bool { if case .object = self { true } else { false } }
    public var pairs: [(key: String, value: JSONValue)] { if case .object(let value) = self { value } else { [] } }

    /// A number, never a true or false.
    public var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// What Python's `value or ...` would count as there.
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .int(let value): value != 0
        case .double(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        }
    }

    /// Non-empty string under a key.
    public func text(_ key: String) -> String? {
        guard let value = self[key]?.string, !value.isEmpty else { return nil }
        return value
    }

    /// Every object in here, parents before children, the way `_walk` goes.
    public func walk(_ visit: (JSONValue) throws -> Void) rethrows {
        switch self {
        case .object(let pairs):
            try visit(self)
            for pair in pairs { try pair.value.walk(visit) }
        case .array(let values):
            for value in values { try value.walk(visit) }
        default:
            break
        }
    }

    /// Instagram's and Facebook's exports hold UTF-8 that was read as Latin-1, keys and all.
    public var withRepairedText: JSONValue {
        switch self {
        case .string(let value): .string(PipelineText.fixMojibake(value))
        case .array(let values): .array(values.map(\.withRepairedText))
        case .object(let pairs): .object(pairs.map { (PipelineText.fixMojibake($0.key), $0.value.withRepairedText) })
        default: self
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var at = 0

        mutating func skipSpace() {
            while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x0D || bytes[at] == 0x09 { at += 1 }
        }

        mutating func value() throws -> JSONValue {
            skipSpace()
            guard at < bytes.count else { throw Malformed(offset: at) }
            switch bytes[at] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "N"): try expect("NaN"); return .double(.nan)
            default: return try number()
            }
        }

        private mutating func expect(_ word: StaticString) throws {
            let count = word.utf8CodeUnitCount
            guard at + count <= bytes.count, memcmp(bytes.baseAddress! + at, word.utf8Start, count) == 0 else { throw Malformed(offset: at) }
            at += count
        }

        private mutating func object() throws -> JSONValue {
            at += 1
            var pairs: [(key: String, value: JSONValue)] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw Malformed(offset: at) }
                let key = try string()
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw Malformed(offset: at) }
                at += 1
                pairs.append((key, try value()))
                skipSpace()
                guard at < bytes.count else { throw Malformed(offset: at) }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(pairs) }
                throw Malformed(offset: at)
            }
        }

        private mutating func array() throws -> JSONValue {
            at += 1
            var values: [JSONValue] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(values) }
            while true {
                values.append(try value())
                skipSpace()
                guard at < bytes.count else { throw Malformed(offset: at) }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(values) }
                throw Malformed(offset: at)
            }
        }

        private mutating func number() throws -> JSONValue {
            let start = at
            var isInteger = true
            if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
            while at < bytes.count {
                let byte = bytes[at]
                if byte >= 0x30, byte <= 0x39 { at += 1 } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
                    isInteger = false
                    at += 1
                } else { break }
            }
            guard at > start else { throw Malformed(offset: at) }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
            if isInteger, let value = Int(text) { return .int(value) }
            guard let value = Double(text) else { throw Malformed(offset: start) }
            return .double(value)
        }

        private mutating func hex4() throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw Malformed(offset: at) }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[at]
                let digit: UInt8
                switch byte {
                case 0x30...0x39: digit = byte - 0x30
                case 0x41...0x46: digit = byte - 0x41 + 10
                case 0x61...0x66: digit = byte - 0x61 + 10
                default: throw Malformed(offset: at)
                }
                value = value << 4 | UInt32(digit)
                at += 1
            }
            return value
        }

        private mutating func string() throws -> String {
            at += 1
            let start = at
            // Most strings have no escapes.
            while at < bytes.count, bytes[at] != UInt8(ascii: "\""), bytes[at] != UInt8(ascii: "\\") { at += 1 }
            guard at < bytes.count else { throw Malformed(offset: start) }
            if bytes[at] == UInt8(ascii: "\"") {
                let out = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
                at += 1
                return out
            }
            var out = Array(bytes[start..<at])
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                guard byte == UInt8(ascii: "\\") else { out.append(byte); continue }
                guard at < bytes.count else { break }
                let escape = bytes[at]
                at += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if code >= 0xD800, code < 0xDC00, at + 6 <= bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                        let mark = at
                        at += 2
                        let low = try hex4()
                        if low >= 0xDC00, low < 0xE000 {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            at = mark
                        }
                    }
                    // A surrogate left on its own can't be held in a String.
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(scalar).utf8))
                default: throw Malformed(offset: at)
                }
            }
            throw Malformed(offset: start)
        }
    }
}
