import Foundation

/// One view over any number of export ZIPs and unzipped folders. Instagram splits large
/// exports across several ZIPs, so they're merged here. Names always use forward slashes.
public final class Archive: @unchecked Sendable {
    private enum Member {
        case file(URL)
        case zipped(ZipReader, ZipReader.Entry)
    }

    private var members: [String: Member] = [:]

    public init(_ paths: [URL]) throws {
        for path in paths {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isFolder) else {
                throw ZipReader.Failure.notAZip(path)
            }
            if isFolder.boolValue {
                let root = path.standardizedFileURL.path + "/"
                let walker = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey])
                while let file = walker?.nextObject() as? URL {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    add(String(file.standardizedFileURL.path.dropFirst(root.count)), .file(file))
                }
            } else {
                let zip = try ZipReader(url: path)
                for entry in zip.entries where !entry.name.hasSuffix("/") {
                    add(entry.name, .zipped(zip, entry))
                }
            }
        }
    }

    /// Instagram and Facebook keep private messages under `messages/`. They're left out here,
    /// so no importer can reach them, even by a path named inside another file.
    private func add(_ name: String, _ member: Member) {
        if name.split(separator: "/").dropLast().contains("messages") { return }
        if members[name] == nil { members[name] = member }
    }

    public var names: [String] { Array(members.keys) }

    /// Names matching a pattern (searched, not anchored), sorted the way Python sorts them.
    public func find(_ pattern: String) -> [String] {
        let regex = PipelineText.regex(pattern)
        return members.keys.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// Exports are sometimes zipped inside a top folder, so paths are matched by their ends.
    public func find(suffix: String) -> String? {
        let suffix = suffix.hasPrefix("/") ? String(suffix.drop { $0 == "/" }) : suffix
        if members[suffix] != nil { return suffix }
        return members.keys.first { $0.hasSuffix("/" + suffix) }
    }

    public func read(_ name: String) throws -> Data {
        switch members[name] {
        case .file(let url): try Data(contentsOf: url)
        case .zipped(let zip, let entry): try zip.read(entry)
        case nil: throw CocoaError(.fileNoSuchFile)
        }
    }

    public func readText(_ name: String) throws -> String {
        String(decoding: try read(name), as: UTF8.self)
    }

    public func readJSON(_ name: String) throws -> JSONValue {
        try JSONValue.parse(try readText(name))
    }
}
