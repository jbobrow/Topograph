import Foundation

/// What each archive importer offers. Importers hand records over one at a time, so a long
/// import can be paused between any two.
public protocol ArchiveImporter {
    static var name: String { get }
    static var title: String { get }
    static func detect(_ archive: Archive) -> Bool
    static func parse(_ archive: Archive, emit: (ImportRecord) throws -> Void) throws
}

public enum ArchiveImporters {
    public static let all: [any ArchiveImporter.Type] = [XImporter.self, InstagramImporter.self, FacebookImporter.self, YouTubeImporter.self, GoogleImporter.self]

    public static func detect(_ archive: Archive) -> [any ArchiveImporter.Type] {
        all.filter { $0.detect(archive) }
    }
}
