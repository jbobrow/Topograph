import Compression
import Foundation

/// Reads a ZIP without unpacking it, ZIP64 included, since exports run to many gigabytes.
/// The file is mapped, so only the members asked for are touched.
final class ZipReader: @unchecked Sendable {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    enum Failure: Error, LocalizedError {
        case notAZip(URL)
        case unsupported(String)
        case damaged(String)

        var errorDescription: String? {
            switch self {
            case .notAZip(let url): "Not a folder or ZIP: \(url.path)"
            case .unsupported(let name): "\(name) is compressed in a way this can't read."
            case .damaged(let name): "\(name) is damaged in the archive."
            }
        }
    }

    private let data: Data
    private(set) var entries: [Entry] = []

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try readDirectory(url)
    }

    private func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
    private func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    private func u64(_ at: Int) -> Int { u32(at) | u32(at + 4) << 32 }

    private func readDirectory(_ url: URL) throws {
        let count = data.count
        guard count >= 22 else { throw Failure.notAZip(url) }
        // The end record is near the end, after a comment of up to 64 KB.
        var end = count - 22
        let earliest = max(0, count - 22 - 65535)
        while end >= earliest, u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= earliest else { throw Failure.notAZip(url) }

        var total = u16(end + 10)
        var offset = u32(end + 16)
        if end >= 20, u32(end - 20) == 0x0706_4B50 {
            let zip64 = u64(end - 12)
            if zip64 + 56 <= count, u32(zip64) == 0x0606_4B50 {
                total = u64(zip64 + 32)
                offset = u64(zip64 + 48)
            }
        }

        entries.reserveCapacity(total)
        var at = offset
        for _ in 0..<total {
            guard at + 46 <= count, u32(at) == 0x0201_4B50 else { throw Failure.notAZip(url) }
            let method = UInt16(u16(at + 10))
            var compressed = u32(at + 20)
            var size = u32(at + 24)
            let nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32)
            var header = u32(at + 42)
            let nameBytes = data[(at + 46)..<(at + 46 + nameLength)]
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            // Sizes too large for 32 bits move to an extra field, in this order.
            var extra = at + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = u16(extra), length = u16(extra + 2)
                if id == 1 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF { size = u64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = u64(field); field += 8 }
                    if header == 0xFFFF_FFFF { header = u64(field) }
                }
                extra += 4 + length
            }
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, headerOffset: header))
            at = extraEnd + commentLength
        }
    }

    func read(_ entry: Entry) throws -> Data {
        let at = entry.headerOffset
        guard at + 30 <= data.count, u32(at) == 0x0403_4B50 else { throw Failure.damaged(entry.name) }
        let start = at + 30 + u16(at + 26) + u16(at + 28)
        guard start + entry.compressedSize <= data.count else { throw Failure.damaged(entry.name) }
        switch entry.method {
        case 0:
            return data.subdata(in: start..<(start + entry.size))
        case 8:
            if entry.size == 0 { return Data() }
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { target in
                data.withUnsafeBytes { source in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              source.bindMemory(to: UInt8.self).baseAddress! + start, entry.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.damaged(entry.name) }
            return out
        default:
            throw Failure.unsupported(entry.name)
        }
    }
}
