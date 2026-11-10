import CoreGraphics
import Foundation
import GRDB
import ImageIO

/// Items that show the same picture from different places: a post shared to Instagram and
/// Facebook, the file it came from, a copy in another folder. They stay separate items, each
/// with its own link and history, and are drawn as one point on the map, led by the largest
/// picture. Same as `same.py`.
///
/// Perceptual hashes find the candidates, and the pixels decide: a flat frame (black, white,
/// a blank page) hashes like every other flat frame, and a burst shot or an edit hashes like
/// its neighbor, so both pictures need detail and their small copies have to all but match.
public enum SamePictures {
    /// Hashes this many bits apart or closer are worth a look.
    static let nearBits = 8
    /// A hash band shared by more than this many pictures is flat frames, not a match.
    static let crowded = 300
    /// A video's picture is its poster, and two videos can share one and still be two videos.
    static let unmatched = "'youtube'"
    /// The small copies compared, a side.
    static let side = 32
    /// Gray spread, 0–1, a picture needs to be told apart from another.
    static let leastDetail: Float = 0.06
    /// The most the small copies can differ, per channel on average, 0–1.
    static let mostDifference: Float = 0.01
    /// How far apart the shapes can be, as log of the aspect ratio.
    static let aspectSlack = 0.15

    struct Picture {
        let id: String
        let hash: UInt64
        let thumb: String
        let pixels: Int
        let aspect: Double
        let time: Int
    }

    /// Finds the sets afresh and stores them. Returns how many sets.
    @discardableResult
    public static func find(library: LibraryWriter, reporter: PipelineReporter) throws -> Int {
        reporter.progress("Finding the same picture in different places")
        let pictures = try library.db.read { db -> [Picture] in
            let times = try Row.fetchAll(db, sql: "select item_id, min(at) from interaction where at != 0 group by item_id")
                .reduce(into: [String: Int]()) { $0[$1[0] as String] = $1[1] as Int }
            let searches = Set(try String.fetchAll(db, sql: LibraryWriter.searchOnlySQL))
            return try Row.fetchAll(db, sql: """
                select m.item_id, m.phash, m.thumb_path, m.width, m.height from media m join item on item.id = m.item_id
                where m.status = 'ok' and m.phash is not null and m.thumb_path is not null and not (\(LibraryWriter.goneSQL))
                  and item.platform not in (\(unmatched))
                  and m.ord = (select min(ord) from media f where f.item_id = m.item_id and f.status = 'ok')
                order by m.item_id
                """).compactMap { row in
                let id: String = row[0]
                guard !searches.contains(id), let hash = UInt64(row[1] as String, radix: 16) else { return nil }
                let width = row[3] as Int? ?? 0, height = row[4] as Int? ?? 0
                return Picture(id: id, hash: hash, thumb: row[2], pixels: width * height,
                               aspect: width > 0 && height > 0 ? Double(width) / Double(height) : 1, time: times[id] ?? Int.max)
            }
        }
        var small: [Int: [Float]?] = [:]
        func pixels(_ index: Int) -> [Float]? {
            if let known = small[index] { return known }
            let found = Self.small(library.root.appending(path: pictures[index].thumb))
            small[index] = found
            return found
        }
        var matches: [Int: [Int]] = [:]
        for (a, b) in candidates(pictures.map(\.hash)) {
            guard abs(log(pictures[a].aspect / pictures[b].aspect)) <= aspectSlack,
                  let x = pixels(a), let y = pixels(b), same(x, y) else { continue }
            matches[a, default: []].append(b)
            matches[b, default: []].append(a)
        }
        let found = sets(pictures, matches: matches)
        try library.db.write { db in
            try db.execute(sql: "delete from same_picture")
            let insert = try db.makeStatement(sql: "insert into same_picture(item_id, lead) values (?, ?)")
            for members in found {
                for member in members { try insert.execute(arguments: [pictures[member].id, pictures[members[0]].id]) }
            }
        }
        reporter.say("\(found.count.formatted()) pictures found in more than one place, \(found.reduce(0) { $0 + $1.count }.formatted()) items")
        return found.count
    }

    /// Sets, each led by its first member, which every other member matches itself. Matching
    /// isn't passed along: frames of a video each like the next would otherwise chain into one.
    static func sets(_ pictures: [Picture], matches: [Int: [Int]]) -> [[Int]] {
        var taken = Set<Int>()
        var out: [[Int]] = []
        for index in pictures.indices.sorted(by: { lead(pictures[$0], before: pictures[$1]) }) where !taken.contains(index) {
            let mates = (matches[index] ?? []).filter { !taken.contains($0) }.sorted()
            guard !mates.isEmpty else { continue }
            out.append([index] + mates)
            taken.insert(index)
            taken.formUnion(mates)
        }
        return out
    }

    /// The largest picture leads, then the one you had first, then by id so it's always the same.
    static func lead(_ a: Picture, before b: Picture) -> Bool {
        if a.pixels != b.pixels { return a.pixels > b.pixels }
        if a.time != b.time { return a.time < b.time }
        return a.id < b.id
    }

    /// Pairs whose hashes are close. Split into four 16-bit bands, two hashes within 3 bits
    /// share at least one, and most pairs further apart that matter do too.
    static func candidates(_ hashes: [UInt64]) -> [(Int, Int)] {
        var bands: [UInt64: [Int]] = [:]
        for (index, hash) in hashes.enumerated() {
            for band in 0..<4 { bands[UInt64(band) << 16 | (hash >> (16 * UInt64(band))) & 0xFFFF, default: []].append(index) }
        }
        var seen = Set<Int>()
        var out: [(Int, Int)] = []
        for members in bands.values where members.count > 1 && members.count <= crowded {
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    let a = members[i], b = members[j]
                    guard (hashes[a] ^ hashes[b]).nonzeroBitCount <= nearBits, seen.insert(a * hashes.count + b).inserted else { continue }
                    out.append((a, b))
                }
            }
        }
        return out.sorted { $0 < $1 }
    }

    /// Two small copies show the same picture: both have detail, and they all but match.
    static func same(_ x: [Float], _ y: [Float]) -> Bool {
        guard detail(x) >= leastDetail, detail(y) >= leastDetail else { return false }
        var difference: Float = 0
        for index in x.indices { difference += abs(x[index] - y[index]) }
        return difference / Float(x.count) < mostDifference
    }

    /// The spread of gray in a small copy.
    static func detail(_ rgb: [Float]) -> Float {
        let count = rgb.count / 3
        var sum: Float = 0, squares: Float = 0
        for index in 0..<count {
            let gray = (rgb[index * 3] + rgb[index * 3 + 1] + rgb[index * 3 + 2]) / 3
            sum += gray
            squares += gray * gray
        }
        let mean = sum / Float(count)
        return max(squares / Float(count) - mean * mean, 0).squareRoot()
    }

    /// A picture squeezed to `side` × `side`, as RGB from 0 to 1.
    static func small(_ file: URL) -> [Float]? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var out = [Float](repeating: 0, count: side * side * 3)
        for pixel in 0..<(side * side) {
            for channel in 0..<3 { out[pixel * 3 + channel] = Float(bytes[pixel * 4 + channel]) / 255 }
        }
        return out
    }
}
