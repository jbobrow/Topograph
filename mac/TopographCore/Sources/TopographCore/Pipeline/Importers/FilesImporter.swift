import CryptoKit
import Darwin
import Foundation
import GRDB
import ImageIO

/// Which files on this Mac may be read, and why. Most images on a disk were never made or seen
/// by you (app assets, icon sets, code dependencies), so a file is kept only when macOS recorded
/// a sign it's yours. Sensitive places are skipped, and the patterns were tuned on real names:
/// change them only with their tests. Files are read in place; only previews are stored.
public enum FilesRules {
    static let imageExtensions: Set<String> = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp", ".svg"]
    static let designExtensions: Set<String> = [".psd", ".psb", ".ai", ".sketch", ".fig", ".xd", ".afdesign", ".afphoto", ".procreate", ".indd", ".pxd", ".blend", ".c4d", ".key"]
    static let fabricationExtensions: Set<String> = [".stl", ".3mf", ".obj", ".step", ".stp", ".f3d", ".dxf"]
    static let videoExtensions: Set<String> = [".mp4", ".mov", ".m4v"]

    static let pruneFolders: Set<String> = ["node_modules", ".git", "Pods", "DerivedData", ".build", "build", "dist", "venv", ".venv", "__pycache__", "site-packages", "vendor", ".next", ".cache", "bower_components", ".gradle", "target", ".dropbox.cache", "Library", ".Trash"]
    static let pruneSuffixes = [".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace", ".photoslibrary", ".lproj", ".plugin", ".kext", ".docset", ".opvault", ".agilekeychain", ".xcassets", ".imageset", ".appiconset", ".sparsebundle"]
    /// A folder that is itself a project (has one of these) holds project assets.
    static let projectMarkers = [".git", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "Podfile", "platformio.ini", "Gemfile", "composer.json", "go.mod"]

    private static let sensitivePath = PipelineText.regex(
        // Letter boundaries rather than \b: in "JAMIE_CT_Scan" the underscore is a separator.
        #"(?<![A-Za-z])(medical|health records?|ct[ _-]?scans?|cat[ _-]?scans?|mri|x-?rays?|ultrasounds?|radiology|dicom|lab[ _-]?results?|prescriptions?|patient|diagnos[ie]s|identification|passports?|id cards?|driver'?s? licen[cs]e|tax(es)?|bank(ing)?|statements?|insurance|legal|lease|payroll|invoices?|receipts?|1password|keychain|private|passwords?)(?![A-Za-z])"#
        // Tax form numbers need number boundaries too, or "3410992.jpg" would match 1099.
        + #"|(?<![A-Za-z0-9])(w-?9s?|w-?2s?|1099(-?(k|misc|nec|int|div|b|r|g|s))?s?)(?![A-Za-z0-9])"#, .caseInsensitive)
    private static let sensitiveHost = PipelineText.regex(
        #"(\.gov$|\.gov\.|chase|bankofamerica|wellsfargo|citi|amex|americanexpress|capitalone|syf\.com|synchrony|discover\.com|intuit|turbotax|irs\.|paypal|venmo|schwab|fidelity|vanguard|etrade|robinhood|coinbase|mint\.com|healthcare|mychart|patient|insurance)"#, .caseInsensitive)
    private static let exportFolder = PipelineText.regex(#"^(twitter-\d{4}-\d{2}-\d{2}|instagram-|facebook-|takeout)"#, .caseInsensitive)
    private static let screenshotName = PipelineText.regex("^(Screen ?Shot|Screenshot|CleanShot|Screen Recording|Capture d’écran)", .caseInsensitive)
    private static let unnamed = PipelineText.regex(#"^([0-9a-f]{16,}|[0-9A-F-]{30,}|IMG_\d+|DSC_?\d+|image\d*|unnamed|download(\s*\(\d+\))?|\d{10,}[-_].*|[0-9_\-]{8,})$"#, .caseInsensitive)
    /// Quarantine agents that mean "from your own camera or devices".
    private static let ownAgents: Set<String> = ["Photos", "PhotosFileProvider", "Image Capture", "Screenshot", "screencaptureui"]

    private static let dataless: UInt32 = 0x4000_0000   // the file's content lives only in the cloud

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func isSensitivePath(_ path: String) -> Bool { matches(sensitivePath, path) }
    public static func isSensitiveHost(_ host: String) -> Bool { matches(sensitiveHost, host) }
    static func isExportFolder(_ name: String) -> Bool { matches(exportFolder, name) }

    /// The host of a web address, as Python's `urlparse(url).hostname` reads it. Parsed by hand:
    /// `URL` refuses addresses with odd characters, and a host it missed would get past the check.
    public static func host(ofURL url: String) -> String? {
        guard let scheme = url.range(of: "//") else { return nil }
        var rest = url[scheme.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            return String(rest[rest.index(after: rest.startIndex)..<close]).lowercased()
        }
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        return rest.isEmpty ? nil : rest.lowercased()
    }

    // MARK: Extended attributes

    static func attribute(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read > 0 ? data.prefix(read) : nil
    }

    static func whereFrom(_ path: String) -> [String] {
        guard let raw = attribute(path, "com.apple.metadata:kMDItemWhereFroms"),
              let value = try? PropertyListSerialization.propertyList(from: raw, format: nil) else { return [] }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return (value as? String).map { [$0] } ?? []
    }

    struct Quarantine {
        var agent: String?
        var at: Int?
    }

    static func quarantine(_ path: String) -> Quarantine? {
        guard let raw = attribute(path, "com.apple.quarantine") else { return nil }
        let parts = String(decoding: raw, as: UTF8.self).components(separatedBy: ";")
        var out = Quarantine()
        if parts.count > 2, !parts[2].isEmpty { out.agent = parts[2] }
        if parts.count > 1, let time = Int(parts[1], radix: 16), (PipelineText.minTime...PipelineText.maxTime).contains(time) { out.at = time }
        return out
    }

    static func lastUsed(_ path: String) -> Int? {
        guard let raw = attribute(path, "com.apple.lastuseddate#PS"), raw.count >= 8 else { return nil }
        let time = Array(raw.prefix(8)).withUnsafeBytes { Int(Int64(littleEndian: $0.loadUnaligned(as: Int64.self))) }
        return (PipelineText.minTime...PipelineText.maxTime).contains(time) ? time : nil
    }

    // MARK: Decisions

    public struct Options: Sendable, Equatable {
        public var includeCode = false      // images inside code projects
        public var includePDF = false
        public var includeCloudOnly = false // reading these downloads them from the cloud
        public var minBytes = 12_000
        public var minUnsignaledBytes = 40_000  // an image with no signal at all must be at least this big
        public var exclude: [String] = []   // folders to leave out entirely

        public init(includeCode: Bool = false, includePDF: Bool = false, includeCloudOnly: Bool = false, exclude: [String] = []) {
            self.includeCode = includeCode
            self.includePDF = includePDF
            self.includeCloudOnly = includeCloudOnly
            self.exclude = exclude
        }
    }

    public struct FileStat: Sendable {
        var size: Int
        var flags: UInt32
        var birth: Double
        var modified: Double

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            size = Int(info.st_size)
            flags = info.st_flags
            birth = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9
            modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        }

        init(size: Int, flags: UInt32 = 0, birth: Double = 0, modified: Double = 0) {
            self.size = size
            self.flags = flags
            self.birth = birth
            self.modified = modified
        }
    }

    public struct Details: Sendable {
        public var family = ""
        public var url: String?
        public var host: String?
        public var agent: String?
        public var downloadedAt: Int?
        public var used: Int?
    }

    /// What to do with a file: nil if it isn't a kind of file that's read at all, a `skip:`
    /// reason, or one of the kinds that's kept.
    public static func classify(path: String, stat info: FileStat, inProject: Bool, options: Options) -> (decision: String, details: Details)? {
        let name = (path as NSString).lastPathComponent
        let suffix = PipelineText.suffix(name)
        let family: String
        if imageExtensions.contains(suffix) { family = "image"
        } else if designExtensions.contains(suffix) { family = "design"
        } else if fabricationExtensions.contains(suffix) { family = "3d"
        } else if videoExtensions.contains(suffix) { family = "video"
        } else if suffix == ".pdf" { family = "pdf"
        } else { return nil }

        let none = Details()
        if family == "pdf", !options.includePDF { return ("skip: PDF (use --include-pdf)", none) }
        if isSensitivePath(path) { return ("skip: sensitive folder or name", none) }
        if !options.includeCloudOnly, info.flags & dataless != 0 { return ("skip: only in the cloud", none) }
        if info.size < options.minBytes, family == "image" { return ("skip: tiny (icons, sprites)", none) }

        let froms = whereFrom(path)
        let quarantined = quarantine(path)
        let used = lastUsed(path)
        let shot = matches(screenshotName, name) || attribute(path, "com.apple.metadata:kMDItemIsScreenCapture") != nil
        let url = froms.first { $0.hasPrefix("http") }
        let host = url.flatMap(Self.host(ofURL:))
        if let host, isSensitiveHost(host) { return ("skip: download from a bank or government site", none) }
        let details = Details(family: family, url: url, host: host, agent: quarantined?.agent, downloadedAt: quarantined?.at, used: used)

        if shot { return ("screenshot", details) }
        if let agent = quarantined?.agent, ownAgents.contains(agent), url == nil { return ("your photo", details) }
        if url != nil || quarantined != nil { return ("download", details) }
        if inProject, !options.includeCode, used == nil { return ("skip: asset inside a code project", none) }
        if ["design", "3d", "video"].contains(family) { return ("working file", details) }
        if used != nil { return ("opened image", details) }
        if info.size >= options.minUnsignaledBytes { return ("image, no signal", details) }
        return ("skip: small image nobody opened", none)
    }

    static let interactionType = ["screenshot": "capture", "your photo": "made", "download": "download",
                                  "working file": "made", "opened image": "made", "image, no signal": "made"]

    // MARK: Dates

    static func created(_ info: FileStat) -> Int? {
        let now = Date().timeIntervalSince1970
        for time in [info.birth, info.modified] where time != 0 && time >= Double(PipelineText.minTime) && time <= Double(PipelineText.maxTime) && time <= now + 86400 {
            return Int(time)
        }
        return nil
    }

    /// When a picture was taken, by its own record of it.
    static func cameraTime(_ path: String) -> Int? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = [exif?[kCGImagePropertyExifDateTimeOriginal], exif?[kCGImagePropertyExifDateTimeDigitized], tiff?[kCGImagePropertyTIFFDateTime]]
            .lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
        guard let raw else { return nil }
        let text = String(PipelineText.strip(raw).prefix(19))
        guard let groups = PipelineText.firstGroups(cameraDate, text), let time = cameraSeconds(groups) else { return nil }
        guard (PipelineText.minTime...PipelineText.maxTime).contains(time), Double(time) <= Date().timeIntervalSince1970 + 86400 else { return nil }
        return time
    }

    private static let cameraDate = PipelineText.regex(#"^(\d{4}):(\d{1,2}):(\d{1,2}) (\d{1,2}):(\d{1,2}):(\d{1,2})$"#)

    private static func cameraSeconds(_ groups: [String?]) -> Int? {
        func two(_ index: Int) -> String { String(format: "%02d", Int(groups[index] ?? "") ?? 0) }
        return PipelineText.isoTime("\(groups[1] ?? "")-\(two(2))-\(two(3))T\(two(4)):\(two(5)):\(two(6))")
    }

    /// (made or kept, created, opened), read from the file. A download's arrival is when you
    /// kept it. For something of yours it only says when it got here: exporting from Photos
    /// stamps every file with that day, even a photo from 2012, and marks each as used, which
    /// isn't you opening it either.
    static func dates(path: String, stat info: FileStat, decision: String, details: Details) -> (at: Int?, created: Int?, used: Int?) {
        if interactionType[decision] == "made" {
            let made = (details.family == "image" ? cameraTime(path) : nil) ?? created(info)
            let arrived = decision == "your photo" ? details.downloadedAt : nil
            if let used = details.used, let arrived, abs(used - arrived) < 86400 { return (made, made, nil) }
            return (made, made, details.used)
        }
        let made = created(info)
        return (details.downloadedAt ?? made, made, details.used)
    }

    static func displayName(path: String) -> String? {
        let nsPath = path as NSString
        let raw = PipelineText.stem(nsPath.lastPathComponent)
        var stem: String? = PipelineText.strip(PipelineText.regex("_+").stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: " "))
        if stem?.isEmpty == true || matches(unnamed, raw) || matches(screenshotName, raw) { stem = nil }
        let parent = (nsPath.deletingLastPathComponent as NSString).lastPathComponent
        let folder = parent == "/" ? "" : parent
        if let stem, !folder.isEmpty { return "\(stem), in \(folder)" }
        return stem ?? (folder.isEmpty ? nil : "in \(folder)")
    }

    static func fileID(path: String, size: Int) throws -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data(String(size).utf8))
        guard let file = FileHandle(forReadingAtPath: path) else { throw CocoaError(.fileReadUnknown) }
        defer { try? file.close() }
        hash.update(data: try file.read(upToCount: 256 * 1024) ?? Data())
        return hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    /// `urllib.parse.quote`, for the item's link back to the file.
    static func fileLink(_ path: String) -> String {
        let resolved = realpath(path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
        var out = "file://"
        for byte in resolved.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"), UInt8(ascii: "/"):
                out.append(Character(Unicode.Scalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

/// `.topographignore`: one path or glob per line, relative to its folder. `*` and `?` stay within
/// one folder, `**` crosses folders, a trailing / means folders only, # starts a comment and !
/// keeps what an earlier line left out. Later lines win.
public struct IgnoreRules {
    public static let fileName = ".topographignore"
    private var rules: [(base: String, patterns: [String])] = []
    private var compiled: [String: NSRegularExpression] = [:]

    public init() {}

    public var isEmpty: Bool { rules.isEmpty }

    static func read(folder: String) -> [String] {
        let file = folder + "/" + fileName
        var info = stat()
        guard stat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let data = FileManager.default.contents(atPath: file) else { return [] }
        return String(decoding: data, as: UTF8.self).unicodeScalars.split { CharacterSet.newlines.contains($0) || $0 == "\u{0B}" || $0 == "\u{0C}" }
            .map { PipelineText.strip(String($0)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public mutating func add(base: String, patterns: [String]) {
        if !patterns.isEmpty { rules.append((base, patterns)) }
    }

    private mutating func regex(_ pattern: String) -> NSRegularExpression {
        if let found = compiled[pattern] { return found }
        var out = ""
        let scalars = Array(pattern.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "*", index + 1 < scalars.count, scalars[index + 1] == "*" {
                out += ".*"
                index += 2
                continue
            }
            switch scalar {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            default: out += NSRegularExpression.escapedPattern(for: String(scalar))
            }
            index += 1
        }
        let made = PipelineText.regex("\\A(?:\(out))\\z")
        compiled[pattern] = made
        return made
    }

    public mutating func isIgnored(path: String, isFolder: Bool) -> Bool {
        let name = (path as NSString).lastPathComponent
        for (base, patterns) in rules where path.hasPrefix(base + "/") {
            let relative = String(path.dropFirst(base.count + 1))
            var verdict: Bool?
            for raw in patterns {
                let keep = raw.hasPrefix("!")
                var pattern = keep ? String(raw.dropFirst()) : raw
                let foldersOnly = pattern.hasSuffix("/")
                while pattern.hasSuffix("/") { pattern.removeLast() }
                while pattern.hasPrefix("/") { pattern.removeFirst() }
                if foldersOnly, !isFolder { continue }
                let regex = regex(pattern)
                func full(_ text: String) -> Bool { regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
                if full(relative) || (!pattern.contains("/") && full(name)) { verdict = !keep }
            }
            if verdict == true { return true }
        }
        return false
    }
}

/// A count of things by name that remembers the order they first came in, like `Counter`.
public struct OrderedCounter<Key: Hashable>: Sendable where Key: Sendable {
    private(set) var order: [Key] = []
    private(set) var counts: [Key: Int] = [:]

    public init() {}

    public subscript(key: Key) -> Int {
        get { counts[key] ?? 0 }
        set {
            if counts[key] == nil { order.append(key) }
            counts[key] = newValue
        }
    }

    public var isEmpty: Bool { order.isEmpty }
    public var total: Int { counts.values.reduce(0, +) }

    /// Most first, and in the order they arrived among equals.
    public var mostCommon: [(key: Key, count: Int)] {
        order.enumerated().sorted { (counts[$0.element]!, $1.offset) > (counts[$1.element]!, $0.offset) }.map { ($0.element, counts[$0.element]!) }
    }
}

/// What a look through the folders found.
public struct FilesReport: Sendable {
    public var kept = OrderedCounter<String>()
    public var skipped = OrderedCounter<String>()
    public var archives: [String] = []
    public var sources = OrderedCounter<String>()
    public var unsignaledFolders = OrderedCounter<[String]>()   // the ones worth a human look before importing
    public var leftOut: [String] = []
    public var already = OrderedCounter<String>()

    public init() {}

    public var checked: Int { kept.total + skipped.total }

    private static func group(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: "en_US"))) }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = group(value)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    public var text: String {
        var lines: [String] = []
        let kept = kept.mostCommon.filter { $0.count > 0 }
        lines.append("Would keep \(Self.group(kept.reduce(0) { $0 + $1.count })) files:")
        for (key, count) in kept { lines.append("  \(Self.pad(count, 7))  \(key)") }
        if !already.isEmpty { lines.append("  (\(Self.group(already.total)) of these were already imported)") }
        lines.append("Skipping \(Self.group(skipped.total)):")
        for (key, count) in skipped.mostCommon { lines.append("  \(Self.pad(count, 7))  \(key.dropFirst(6))") }
        if !sources.isEmpty {
            lines.append("Most common download sources: " + sources.mostCommon.prefix(8).map { "\($0.key) (\($0.count))" }.joined(separator: ", "))
        }
        if !leftOut.isEmpty {
            var parents = OrderedCounter<String>()
            for folder in leftOut { parents[(folder as NSString).deletingLastPathComponent] += 1 }
            lines.append("Left out \(Self.group(leftOut.count)) folder(s) you excluded:")
            lines += parents.mostCommon.prefix(8).map { "  \(Self.pad($0.count, 5)) in \($0.key)" }
        }
        if !unsignaledFolders.isEmpty {
            lines.append("Images with no sign of being yours, by folder. If one isn't your work, list it in a .topographignore file in a folder above it:")
            lines += Self.reviewGroups(unsignaledFolders).prefix(15).map { "  \(Self.pad($0.count, 7))  \($0.folder)" }
        }
        if !archives.isEmpty {
            lines.append("Platform exports found (drop these on Sources to import them):")
            lines += archives.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Folders to review, split until each line is something a person can judge. The counts are
    /// keyed by root and folder names. A big group splits into its subfolders when no single
    /// subfolder holds nearly all of it.
    static func reviewGroups(_ counts: OrderedCounter<[String]>, big: Int = 250, maxDepth: Int = 6) -> [(folder: String, count: Int)] {
        func total(_ prefix: [String]) -> Int {
            counts.order.reduce(0) { $0 + ($1.starts(with: prefix) ? counts[$1] : 0) }
        }
        func expand(_ prefix: [String]) -> [(key: [String], count: Int)] {
            let all = total(prefix)
            var children = OrderedCounter<[String]>()
            for key in counts.order where key.starts(with: prefix) && key.count > prefix.count {
                children[Array(key.prefix(prefix.count + 1))] += counts[key]
            }
            let here = all - children.total
            let shallow = prefix.count < 3     // always at least two folders below the root
            if children.isEmpty || prefix.count - 1 >= maxDepth || (all <= big && !shallow) { return [(prefix, all)] }
            // One child holding nearly everything: go down without listing the parent.
            let top = children.mostCommon[0]
            if !shallow, children.order.count == 1 || Double(top.count) >= 0.9 * Double(all) {
                let rest = all - top.count > 0 ? [(key: prefix + ["(other)"], count: all - top.count)] : []
                return expand(top.key) + rest
            }
            var out: [(key: [String], count: Int)] = []
            for child in children.order { out += expand(child) }
            if here > 0 { out.append((prefix, here)) }
            return out
        }
        var result: [(key: [String], count: Int)] = []
        var roots: [String] = []
        for key in counts.order where !roots.contains(key[0]) { roots.append(key[0]) }
        for root in roots { result += expand([root]) }
        return result.map { key, count in
            let parts = key.filter { $0 != "(other)" }
            let path = parts.dropFirst().reduce(parts[0]) { ($0 as NSString).appendingPathComponent($1) }
            return (path + (key.last == "(other)" ? " (other files)" : ""), count)
        }.enumerated().sorted { ($0.element.1, $1.offset) > ($1.element.1, $0.offset) }.map(\.element)
    }
}

/// Your own files, read where they are. See importers/files.py.
public enum FilesImporter {
    public struct Candidate: Sendable {
        public let path: String
        let stat: FilesRules.FileStat
        public let decision: String
        let details: FilesRules.Details
    }

    private static func expanded(_ path: String) -> String {
        var out = (path as NSString).expandingTildeInPath
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }

    private static func listing(_ folder: String) -> (folders: [String], files: [String])? {
        guard let handle = opendir(folder) else { return nil }
        defer { closedir(handle) }
        var folders: [String] = [], files: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var kind = entry.pointee.d_type
            if kind == DT_UNKNOWN {
                var info = stat()
                guard lstat(folder + "/" + name, &info) == 0 else { continue }
                kind = info.st_mode & S_IFMT == S_IFDIR ? UInt8(DT_DIR) : UInt8(DT_REG)
            }
            if kind == DT_DIR { folders.append(name) } else { files.append(name) }
        }
        return (folders.sorted(), files.sorted())
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    private static func isFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// The files to keep from under these folders, so the import knows its total. Skipped ones
    /// are only counted. `onFolder` hears each folder as it's entered and how many files have
    /// been checked, and a true from `stop` ends the walk.
    public static func collect(roots: [String], options: FilesRules.Options, report: inout FilesReport,
                               onFolder: (String, Int) -> Void = { _, _ in }, onDecision: (String, String) -> Void = { _, _ in },
                               stop: () -> Bool = { false }) -> [Candidate] {
        var candidates: [Candidate] = []
        let excluded = Set(options.exclude.map(expanded))
        for rawRoot in roots {
            let root = expanded(rawRoot)
            var rules = IgnoreRules()
            var projectFolders = Set<String>()
            var stack = [root]
            while let here = stack.popLast() {
                if stop() { return candidates }
                guard let (folders, files) = listing(here) else { continue }
                onFolder(here, report.checked)
                rules.add(base: here, patterns: IgnoreRules.read(folder: here))
                // A folder is part of a code project if it, or any folder above it, has a marker.
                let parent = (here as NSString).deletingLastPathComponent
                let inProject = projectFolders.contains(parent) || FilesRules.projectMarkers.contains { exists(here + "/" + $0) }
                if inProject { projectFolders.insert(here) }
                let hereName = (here as NSString).lastPathComponent
                var keep: [String] = []
                for name in folders {
                    if FilesRules.pruneFolders.contains(name) || name.hasPrefix(".") || FilesRules.pruneSuffixes.contains(where: name.hasSuffix) || name.hasSuffix("_files") {
                        continue    // "_files": the assets folder of a saved web page
                    }
                    if name == "wp-admin" || name == "wp-includes" || (hereName == "wp-content" && name != "uploads") {
                        continue    // a WordPress backup: only uploads are yours, the rest is theme code
                    }
                    let path = here + "/" + name
                    if excluded.contains(path) || (!rules.isEmpty && rules.isIgnored(path: path, isFolder: true)) {
                        report.leftOut.append(path)
                        continue
                    }
                    if FilesRules.isExportFolder(name) {
                        report.archives.append(path)
                        continue
                    }
                    keep.append(path)
                }
                stack.append(contentsOf: keep.reversed())
                for name in files where name != IgnoreRules.fileName {
                    let path = here + "/" + name
                    guard let info = FilesRules.FileStat(path: path), isFile(path) else { continue }
                    if !rules.isEmpty, rules.isIgnored(path: path, isFolder: false) { continue }
                    guard let (decision, details) = FilesRules.classify(path: path, stat: info, inProject: inProject, options: options) else { continue }
                    onDecision(path, decision)
                    if decision.hasPrefix("skip") {
                        report.skipped[decision] += 1
                        continue
                    }
                    report.kept[decision] += 1
                    if let host = details.host {
                        report.sources[host.split(separator: ".", omittingEmptySubsequences: false).suffix(2).joined(separator: ".")] += 1
                    }
                    if decision == "image, no signal" {
                        let relative = String(here.dropFirst(root.count)).split(separator: "/").map(String.init)
                        report.unsignaledFolders[[root] + relative] += 1
                    }
                    candidates.append(Candidate(path: path, stat: info, decision: decision, details: details))
                }
            }
        }
        return candidates
    }

    /// The record for one file from `collect`, or nil if it's already in the library or has no
    /// preview. One odd file never stops the import.
    public static func record(for candidate: Candidate, report: inout FilesReport, finished: Set<String>,
                              preview: (URL) -> (data: Data?, kind: String) = MediaIngest.preview(of:)) -> ImportRecord? {
        let path = candidate.path, details = candidate.details
        guard let id = try? FilesRules.fileID(path: path, size: candidate.stat.size) else {
            report.skipped["skip: unreadable"] += 1
            return nil
        }
        if finished.contains("file:\(id)") {
            report.already[candidate.decision] += 1
            return nil
        }
        let dates = FilesRules.dates(path: path, stat: candidate.stat, decision: candidate.decision, details: details)
        guard let data = preview(URL(fileURLWithPath: path)).data else {
            report.skipped["skip: no preview available"] += 1
            report.kept[candidate.decision] -= 1
            return nil
        }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var interactions = [ImportInteraction(type: FilesRules.interactionType[candidate.decision] ?? "made", at: dates.at, collection: parent, source: path)]
        if let used = dates.used { interactions.append(ImportInteraction(type: "open", at: used, source: path)) }
        let name = (path as NSString).lastPathComponent
        return ImportRecord(id: "file:\(id)", platform: "files", kind: details.family == "video" ? "video" : "image",
                            url: FilesRules.fileLink(path), author: details.host, text: FilesRules.displayName(path: path),
                            createdAt: dates.created, hydrated: 1, interactions: interactions,
                            media: [ImportMedia(ord: 0, url: details.url, name: nil, isPoster: FilesRules.videoExtensions.contains(PipelineText.suffix(name))) { data }])
    }

    /// Correct the dates of your own files already in the library, adding nothing. `candidates`
    /// comes from `collect`, so this reads only what an import may read. A file that's moved or
    /// now left out isn't read at all: for those, a date that differs from the stored creation
    /// date can only be an arrival date, so the stored one takes its place. Downloads keep theirs.
    public static func fixDates(library: LibraryWriter, candidates: [Candidate], onFile: (String) -> Void = { _ in }) throws -> (corrected: Int, dropped: Int) {
        var corrected = 0, dropped = 0
        var seen = Set<String>()
        func apply(_ id: String, made: Int, created: Int?, arrived: Int?) throws {
            try library.db.write { db in
                try db.execute(sql: "update or replace interaction set at = ? where item_id = ? and type = 'made' and at != ?", arguments: [made, id, made])
                if db.changesCount > 0 { corrected += 1 }
                if let created { try db.execute(sql: "update item set created_at = ? where id = ?", arguments: [created, id]) }
                if let arrived {
                    try db.execute(sql: "delete from interaction where item_id = ? and type = 'open' and abs(at - ?) < 86400", arguments: [id, arrived])
                    dropped += db.changesCount
                }
            }
        }
        for candidate in candidates {
            onFile(candidate.path)
            guard FilesRules.interactionType[candidate.decision] == "made",
                  let raw = try? FilesRules.fileID(path: candidate.path, size: candidate.stat.size) else { continue }
            let id = "file:\(raw)"
            let known = try library.db.read { try Bool.fetchOne($0, sql: "select exists(select 1 from interaction where item_id = ? and type = 'made')", arguments: [id]) ?? false }
            guard known else { continue }
            seen.insert(id)
            if let made = FilesRules.dates(path: candidate.path, stat: candidate.stat, decision: candidate.decision, details: candidate.details).at {
                try apply(id, made: made, created: made, arrived: candidate.decision == "your photo" ? candidate.details.downloadedAt : nil)
            }
        }
        let rows = try library.db.read { db in
            try Row.fetchAll(db, sql: """
                select ix.item_id, ix.at, i.created_at from interaction ix join item i on i.id = ix.item_id
                where i.platform = 'files' and ix.type = 'made' and i.created_at is not null and ix.at != 0 and ix.at != i.created_at
                """)
        }
        for row in rows where !seen.contains(row["item_id"]) {
            try apply(row["item_id"], made: row["created_at"], created: nil, arrived: row["at"])
        }
        return (corrected, dropped)
    }
}
