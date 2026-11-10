import CoreGraphics
import Darwin
import Foundation
import GRDB
import ImageIO
@testable import TopographCore
import XCTest

private let silent = PipelineReporter(progress: { _ in }, say: { _ in })

/// A picture with some detail in it, as PNG or JPEG bytes.
private func picture(seed: Int, width: Int = 480, height: Int = 360, type: String = "public.jpeg", date: String? = nil) -> Data {
    var random = SeededRandom(seed: UInt64(seed + 1))
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = UInt8(truncatingIfNeeded: random.next())
        pixels[index + 1] = UInt8(truncatingIfNeeded: random.next())
        pixels[index + 2] = UInt8(truncatingIfNeeded: index / 4 + seed)
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = context.makeImage()!
    let out = NSMutableData()
    let target = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if let date { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
    CGImageDestinationAddImage(target, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(target))
    return out as Data
}

/// A temp folder with no sensitive word in its path, since the rules read the whole path.
private func neutralFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "tg-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    XCTAssertFalse(FilesRules.isSensitivePath(root.path), root.path)
    return root
}

private func write(_ data: Data, _ folder: URL, _ path: String) throws {
    let file = folder.appending(path: path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
}

private func setAttribute(_ file: URL, _ name: String, _ value: Data) {
    _ = value.withUnsafeBytes { setxattr(file.path, name, $0.baseAddress, value.count, 0, 0) }
}

private func decisions(_ root: URL, options: FilesRules.Options = .init()) -> (seen: [String: String], report: FilesReport) {
    var report = FilesReport()
    var seen: [String: String] = [:]
    _ = FilesImporter.collect(roots: [root.path], options: options, report: &report, onDecision: { path, decision in
        seen[(path as NSString).lastPathComponent] = decision
    })
    return (seen, report)
}

final class PipelineTextTests: XCTestCase {
    func testDatesAndIDs() {
        XCTAssertEqual(PipelineText.parseTwitterDate("Wed Jul 03 14:23:01 +0000 2024"), 1720016581)
        XCTAssertNil(PipelineText.snowflakeTime("12345"), "pre-snowflake ids carry no time")
        XCTAssertEqual(PipelineText.instagramShortcode("https://www.instagram.com/reel/CVa1b2c3d4E/?igsh=x"), "CVa1b2c3d4E")
        XCTAssertEqual(PipelineText.instagramShortcode("https://www.instagram.com/someone/p/CK3x9QmnAbC/"), "CK3x9QmnAbC")
        let time = PipelineText.instagramShortcodeTime("CK3x9QmnAbC")!
        XCTAssertTrue((1_577_836_800...1_640_995_200).contains(time))
        XCTAssertEqual(PipelineText.takeoutTime("2024-01-02T03:04:05.000Z"), 1704164645)
        XCTAssertEqual(PipelineText.takeoutTime("2024-02-01T00:00:00+00:00"), 1706745600)
    }

    func testMojibake() {
        XCTAssertEqual(PipelineText.fixMojibake("Ferns after rain ð\u{9F}\u{8C}¿"), "Ferns after rain 🌿")
        XCTAssertEqual(PipelineText.fixMojibake("plain"), "plain")
        XCTAssertEqual(PipelineText.fixMojibake("already fine ✨"), "already fine ✨")
    }

    func testUnavailable() {
        XCTAssertTrue(PipelineText.isUnavailable("You’re unable to view this Post because this account owner limits who can view their Posts. {learnmore}"))
        XCTAssertTrue(PipelineText.isUnavailable("This Post is from a suspended account. {learnmore}"))
        XCTAssertTrue(PipelineText.isUnavailable("This Tweet was deleted by the Tweet author. Learn more"))
        XCTAssertFalse(PipelineText.isUnavailable("This post is about suspended ceilings"))
    }

    func testJSONKeepsItsOrderAndCopesWithExports() throws {
        let value = try JSONValue.parse(#"{"z": 1, "a": [true, null, 2.5, "\u00f0\u009f\u008c\u00bf"], "e": "\ud83c\udf3f"}"#)
        XCTAssertEqual(value.pairs.map(\.key), ["z", "a", "e"])
        XCTAssertEqual(value["e"]?.string, "🌿")
        XCTAssertEqual(value.withRepairedText["a"]?.array?[3].string, "🌿")
        XCTAssertNil(value["a"]?.array?[0].number, "true isn't a number")
        XCTAssertThrowsError(try JSONValue.parse("{not json"))
    }

    func testCSVHandlesQuotesAndABOM() {
        let rows = CSVTable.rows("\u{FEFF}Video ID,Title\r\nabc,\"A, \"\"quoted\"\" one\"\nxyz,\"two\nlines\"\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["Video ID"], "abc")
        XCTAssertEqual(rows[0]["Title"], "A, \"quoted\" one")
        XCTAssertEqual(rows[1]["Title"], "two\nlines")
    }
}

final class ArchiveTests: XCTestCase {
    func testPrivateMessagesAreNeverListed() throws {
        let root = try neutralFolder()
        try write(Data("{}".utf8), root, "your_instagram_activity/messages/inbox/someone/message_1.json")
        try write(Data("{}".utf8), root, "your_instagram_activity/likes/liked_posts.json")
        let archive = try Archive([root])
        XCTAssertEqual(archive.names, ["your_instagram_activity/likes/liked_posts.json"])
        XCTAssertNil(archive.find(suffix: "inbox/someone/message_1.json"))
    }

    func testReadsAZipIncludingCompressedMembers() throws {
        let root = try neutralFolder()
        try write(Data(repeating: 65, count: 100_000), root, "folder/data.txt")
        try write(Data("short".utf8), root, "folder/small.txt")
        let zip = root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent).zip")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = root
        task.arguments = ["-qr", zip.path, "folder"]
        try task.run()
        task.waitUntilExit()
        let archive = try Archive([zip])
        XCTAssertEqual(try archive.read("folder/data.txt"), Data(repeating: 65, count: 100_000))
        XCTAssertEqual(try archive.readText("folder/small.txt"), "short")
        XCTAssertThrowsError(try Archive([root.appending(path: "folder/small.txt")]), "not a ZIP")
    }
}

final class FilesRulesTests: XCTestCase {
    func testSensitiveNamesTunedOnRealOnes() {
        for path in ["/d/JAMIE_CT_Scan/a.jpg", "/d/PATIENT_CT_Scan_2026.04.01/slice.jpg", "/d/Taxes 2023/x.png", "/d/w2.png", "/d/W-9.pdf", "/d/1099-misc.png",
                     "/d/x-ray.jpg", "/d/MRI/knee.jpg", "/d/Passport.jpg", "/d/lab results/a.jpg", "/d/1password/a.png", "/d/bank_statement.png"] {
            XCTAssertTrue(FilesRules.isSensitivePath(path), path)
        }
        for path in ["/d/3410992.jpg", "/d/tax1099k2.png".replacingOccurrences(of: "1099k2", with: "x"), "/d/taxidermy.jpg", "/d/embankment.jpg", "/d/CT.png", "/d/legally blonde poster.png"] {
            XCTAssertFalse(FilesRules.isSensitivePath(path), path)
        }
    }

    func testBankAndGovernmentHosts() {
        XCTAssertEqual(FilesRules.host(ofURL: "https://user@secure.Chase.com:443/statement.jpg?x=1"), "secure.chase.com")
        XCTAssertEqual(FilesRules.host(ofURL: "https://images.example.com/a b.jpg"), "images.example.com", "an odd address still has a host")
        XCTAssertTrue(FilesRules.isSensitiveHost("secure.chase.com"))
        XCTAssertTrue(FilesRules.isSensitiveHost("www.irs.gov"))
        XCTAssertFalse(FilesRules.isSensitiveHost("images.example.com"))
    }

    func testClassificationUsesWhatMacOSRecorded() throws {
        let root = try neutralFolder()
        let big = picture(seed: 1, width: 900, height: 700, type: "public.png")
        try write(picture(seed: 5, width: 900, height: 700, type: "public.png"), root, "Screenshots/Screenshot 2024-05-01 at 10.00.00.png")
        try write(picture(seed: 6, width: 900, height: 700, type: "public.png"), root, "Poster Drafts/poster v2.png")
        try write(picture(seed: 7, width: 900, height: 700), root, "Poster Drafts/from-web.jpg")
        try write(big, root, "Poster Drafts/pattern.jpg")
        try write(big, root, "Taxes 2023/w2.png")
        try write(big, root, "my-app/assets/hero.png")
        try write(Data("{}".utf8), root, "my-app/package.json")
        try write(big, root, "Saved Page_files/banner.png")
        try write(picture(seed: 2, width: 16, height: 16, type: "public.png"), root, "icon.png")

        let web = root.appending(path: "Poster Drafts/from-web.jpg")
        let froms = try PropertyListSerialization.data(fromPropertyList: ["https://images.example.com/a.jpg", "https://example.com/post"], format: .binary, options: 0)
        setAttribute(web, "com.apple.metadata:kMDItemWhereFroms", froms)
        setAttribute(web, "com.apple.quarantine", Data("0081;6316bc7c;Chrome;ABC".utf8))
        let bank = try PropertyListSerialization.data(fromPropertyList: ["https://secure.chase.com/statement.jpg"], format: .binary, options: 0)
        setAttribute(root.appending(path: "Poster Drafts/pattern.jpg"), "com.apple.metadata:kMDItemWhereFroms", bank)
        var used = Int64(1_714_557_600)
        setAttribute(root.appending(path: "Poster Drafts/poster v2.png"), "com.apple.lastuseddate#PS", Data(bytes: &used, count: 8) + Data(count: 8))

        let (seen, _) = decisions(root)
        XCTAssertEqual(seen["Screenshot 2024-05-01 at 10.00.00.png"], "screenshot")
        XCTAssertEqual(seen["poster v2.png"], "opened image")
        XCTAssertEqual(seen["from-web.jpg"], "download")
        XCTAssertTrue(seen["pattern.jpg"]?.hasPrefix("skip: download from a bank") == true)
        XCTAssertEqual(seen["w2.png"], "skip: sensitive folder or name")
        XCTAssertEqual(seen["hero.png"], "skip: asset inside a code project")
        XCTAssertTrue(seen["icon.png"]?.hasPrefix("skip: tiny") == true)
        XCTAssertNil(seen["banner.png"], "a saved web page's assets are pruned")

        // Excluding a folder is honored.
        let excluded = decisions(root, options: .init(exclude: [root.appending(path: "Poster Drafts").path]))
        XCTAssertNil(excluded.seen["poster v2.png"])

        // Importing: a download keeps where it came from.
        let library = try LibraryWriter(root: try neutralFolder())
        try Pipeline.readFiles([root.path], library: library, reporter: silent)
        let source = try library.db.read { db in
            try String.fetchOne(db, sql: "select original_url from media m join item i on i.id = m.item_id where i.text = 'from-web, in Poster Drafts'")
        }
        XCTAssertEqual(source, "https://images.example.com/a.jpg")
        let types = Set(try library.db.read { try String.fetchAll($0, sql: "select type from interaction") })
        XCTAssertTrue(types.isSuperset(of: ["capture", "made", "download", "open"]), "\(types)")
    }

    func testIgnoreFile() throws {
        let root = try neutralFolder().appending(path: "Dropbox")
        try write(picture(seed: 8, width: 900, height: 700), root, "napkin/class/people/someone/their-work.png")
        try write(picture(seed: 9, width: 900, height: 700), root, "napkin/class/mine/my-work.png")
        try write(picture(seed: 10, width: 900, height: 700), root, "napkin/class/mine/scratch.tmp.png")
        try write(picture(seed: 11, width: 900, height: 700), root, "napkin/class/people/me/projects/my-page.png")
        try write(Data("# classmates' pages, not mine\nclass/people/*/\n!class/people/me/\n*.tmp.png\n".utf8), root, "napkin/.topographignore")
        let (seen, report) = decisions(root)
        XCTAssertEqual(Set(seen.keys), ["my-work.png", "my-page.png"])
        XCTAssertEqual(report.leftOut, [root.appending(path: "napkin/class/people/someone").path])
    }

    func testDoubleStarCrossesFoldersAndOneStarDoesNot() {
        var rules = IgnoreRules()
        rules.add(base: "/d", patterns: ["a/*/x.png", "b/**/y.png"])
        XCTAssertTrue(rules.isIgnored(path: "/d/a/1/x.png", isFolder: false))
        XCTAssertFalse(rules.isIgnored(path: "/d/a/1/2/x.png", isFolder: false))
        XCTAssertTrue(rules.isIgnored(path: "/d/b/1/2/y.png", isFolder: false))
    }

    func testScanAndSiteRules() throws {
        let root = try neutralFolder().appending(path: "Dropbox")
        try write(picture(seed: 30, width: 600, height: 500), root, "Family/Scans/PATIENT_CT_Scan_2026.04.01/slice001.jpg")
        try write(picture(seed: 31, width: 600, height: 500), root, "site/wordpress/wp-content/uploads/2014/board.jpg")
        try write(picture(seed: 32, width: 600, height: 500), root, "site/wordpress/wp-content/themes/twenty/header.jpg")
        try write(picture(seed: 33, width: 600, height: 500), root, "site/wordpress/wp-includes/bg.jpg")
        let (seen, _) = decisions(root)
        XCTAssertEqual(seen["slice001.jpg"], "skip: sensitive folder or name")
        XCTAssertEqual(seen["board.jpg"], "image, no signal")
        XCTAssertNil(seen["header.jpg"])
        XCTAssertNil(seen["bg.jpg"])
    }

    func testReviewGroupsSplitBigFoldersAndCountOnce() {
        var counts = OrderedCounter<[String]>()
        counts[["/D", "napkin", "MIT", "site", "wp"]] = 1800
        counts[["/D", "napkin", "MIT", "Process"]] = 1400
        counts[["/D", "napkin", "MIT", "people", "me", "projects"]] = 400
        counts[["/D", "Personal", "Family", "2015"]] = 300
        counts[["/D", "Personal", "Family", "2016"]] = 310
        let groups = Dictionary(uniqueKeysWithValues: FilesReport.reviewGroups(counts).map { ($0.folder, $0.count) })
        XCTAssertEqual(groups["/D/napkin/MIT/site/wp"], 1800)
        XCTAssertEqual(groups["/D/napkin/MIT/Process"], 1400)
        XCTAssertEqual(groups["/D/napkin/MIT/people/me/projects"], 400)
        XCTAssertEqual(groups["/D/Personal/Family/2016"], 310)

        var again = OrderedCounter<[String]>()
        again[["/D", "Portfolio"]] = 5
        again[["/D", "Portfolio", "Old Site"]] = 225
        again[["/D"]] = 48
        let list = FilesReport.reviewGroups(again)
        XCTAssertEqual(list.reduce(0) { $0 + $1.count }, 278)
        XCTAssertEqual(Set(list.map(\.folder)).count, list.count)
    }

    private func arrived(_ file: URL, exportAt: Int, agent: String, usedAt: Int? = nil) {
        setAttribute(file, "com.apple.quarantine", Data("0083;\(String(exportAt, radix: 16));\(agent);".utf8))
        if var used = usedAt.map(Int64.init) { setAttribute(file, "com.apple.lastuseddate#PS", Data(bytes: &used, count: 8) + Data(count: 8)) }
    }

    private func history(_ library: LibraryWriter) throws -> [String: [String: Int]] {
        try library.db.read { db in
            var out: [String: [String: Int]] = [:]
            for row in try Row.fetchAll(db, sql: "select i.text, i.created_at, ix.type, ix.at from item i join interaction ix on ix.item_id = i.id") {
                let name = (row["text"] as String).components(separatedBy: ",")[0]
                out[name, default: [:]]["created"] = row["created_at"]
                out[name, default: [:]][row["type"] as String] = row["at"]
            }
            return out
        }
    }

    private let export = 1_778_500_000   // 2026-05-11

    func testYourPhotosAreDatedWhenTakenNotWhenTheyArrived() throws {
        let root = try neutralFolder().appending(path: "Downloads")
        try write(picture(seed: 40, width: 900, height: 700, date: "2015:10:03 12:00:00"), root, "beach.jpg")
        try write(picture(seed: 41, width: 900, height: 700), root, "no camera date.jpg")
        try write(picture(seed: 42, width: 900, height: 700, date: "2015:10:03 12:00:00"), root, "from-web.jpg")
        arrived(root.appending(path: "beach.jpg"), exportAt: export, agent: "Photos", usedAt: export + 60)
        arrived(root.appending(path: "no camera date.jpg"), exportAt: export, agent: "Photos", usedAt: export + 60)
        arrived(root.appending(path: "from-web.jpg"), exportAt: export, agent: "Safari", usedAt: export + 60)
        let library = try LibraryWriter(root: try neutralFolder())
        try Pipeline.readFiles([root.path], library: library, reporter: silent)
        let seen = try history(library)
        let taken = Int(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2015, month: 10, day: 3, hour: 12))!.timeIntervalSince1970)
        XCTAssertEqual(seen["beach"]?["made"], taken)
        XCTAssertEqual(seen["beach"]?["created"], taken)
        XCTAssertNil(seen["beach"]?["open"], "the export marked it as used; you didn't open it")
        XCTAssertGreaterThan(abs((seen["no camera date"]?["made"] ?? export) - export), 86400, "falls back to when the file was created")
        XCTAssertEqual(seen["from-web"]?["download"], export, "a download's arrival is when you kept it")
        XCTAssertEqual(seen["from-web"]?["open"], export + 60, "opening a download the same day is real")
    }

    func testFixDatesRepairsWhatIsStoredAndAddsNothing() throws {
        let root = try neutralFolder().appending(path: "Downloads")
        for (seed, name) in ["beach", "moved away", "left out"].enumerated() {
            try write(picture(seed: 50 + seed, width: 900, height: 700, date: "2015:10:03 12:00:00"), root, "\(name).jpg")
            arrived(root.appending(path: "\(name).jpg"), exportAt: export, agent: "Photos")
        }
        let library = try LibraryWriter(root: try neutralFolder())
        try Pipeline.readFiles([root.path], library: library, reporter: silent)

        // As an older import left things: dated by the export, and marked as opened that day.
        let created = 1_444_000_000
        let count = try library.db.write { db -> Int in
            try db.execute(sql: "update interaction set at = ? where type = 'made'", arguments: [self.export])
            try db.execute(sql: "update item set created_at = ?", arguments: [created])
            for id in try String.fetchAll(db, sql: "select id from item") {
                try db.execute(sql: "insert into interaction(item_id, type, at) values (?, 'open', ?)", arguments: [id, self.export + 60])
                try db.execute(sql: "insert into interaction(item_id, type, at) values (?, 'open', ?)", arguments: [id, self.export - 86400 * 400])
            }
            return try Int.fetchOne(db, sql: "select count(*) from item") ?? 0
        }
        try FileManager.default.removeItem(at: root.appending(path: "moved away.jpg"))
        try write(Data("left out.jpg\n".utf8), root, ".topographignore")
        try write(picture(seed: 60, width: 900, height: 700, date: "2020:01:01 12:00:00"), root, "new.jpg")
        arrived(root.appending(path: "new.jpg"), exportAt: export, agent: "Photos")
        let taken = Int(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2015, month: 10, day: 3, hour: 12))!.timeIntervalSince1970)
        for _ in 0..<2 {    // a second run changes nothing
            try Pipeline.readFiles([root.path], fixDates: true, library: library, reporter: silent)
            let seen = try history(library)
            XCTAssertEqual(seen["beach"]?["made"], taken)
            XCTAssertEqual(seen["beach"]?["created"], taken)
            XCTAssertEqual(seen["moved away"]?["made"], created, "gone from disk, so the stored creation date")
            XCTAssertEqual(seen["left out"]?["made"], created)
            for name in ["beach", "moved away", "left out"] {
                XCTAssertEqual(seen[name]?["open"], export - 86400 * 400, "a real opening stays; the export's goes")
            }
        }
        try library.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from item"), count, "nothing new is imported")
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from interaction where type = 'open'"), count)
        }
    }

    func testImportSurvivesBadFilesAndResumes() throws {
        let root = try neutralFolder().appending(path: "Desktop")
        for index in 0..<4 { try write(Data(String(repeating: "solid part\(index)\n", count: 10).utf8), root, "part \(index).stl") }
        var report = FilesReport()
        let candidates = FilesImporter.collect(roots: [root.path], options: .init(), report: &report)
        let preview: (URL) -> (data: Data?, kind: String) = { file in
            file.lastPathComponent == "part 1.stl" || file.lastPathComponent == "part 2.stl" ? (nil, "image") : (picture(seed: 3), "image")
        }
        let records = candidates.compactMap { FilesImporter.record(for: $0, report: &report, finished: [], preview: preview) }
        XCTAssertEqual(Set(records.compactMap(\.text)), ["part 0, in Desktop", "part 3, in Desktop"])
        var second = FilesReport()
        let again = FilesImporter.collect(roots: [root.path], options: .init(), report: &second)
            .compactMap { FilesImporter.record(for: $0, report: &second, finished: Set(records.map(\.id)), preview: preview) }
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(second.already.total, 2)
    }
}

final class MediaIngestTests: XCTestCase {
    func testSizesLikePillowsThumbnail() {
        XCTAssertEqual(MediaIngest.fittedSize(width: 4000, height: 3000, edge: 1600).width, 1600)
        XCTAssertEqual(MediaIngest.fittedSize(width: 4000, height: 3000, edge: 1600).height, 1200)
        XCTAssertEqual(MediaIngest.fittedSize(width: 300, height: 200, edge: 1600).width, 300, "never larger")
        XCTAssertEqual(MediaIngest.fittedSize(width: 3000, height: 4000, edge: 320).height, 320)
        XCTAssertEqual(MediaIngest.fittedSize(width: 3000, height: 4000, edge: 320).width, 240)
    }

    func testStoresByContentWithWebPCopiesAndAHash() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        let bytes = picture(seed: 4, width: 2000, height: 1000)
        let record = ImportRecord(id: "x:1", platform: "x", kind: "image", interactions: [ImportInteraction(type: "post", at: 1)],
                                  media: [ImportMedia(ord: 0) { bytes }])
        XCTAssertTrue(try library.upsert(record))
        XCTAssertFalse(try library.upsert(record), "the second time isn't new")
        let row = try XCTUnwrap(try library.db.read { try Row.fetchOne($0, sql: "select * from media") })
        XCTAssertEqual(row["status"] as String, "ok")
        XCTAssertEqual(row["width"] as Int, 2000)
        XCTAssertEqual(row["height"] as Int, 1000)
        let hash = PipelineText.sha256(bytes)
        XCTAssertEqual(row["local_path"] as String, "media/\(hash.prefix(2))/\(hash)-d.webp")
        XCTAssertEqual((row["phash"] as String).count, 16)
        XCTAssertTrue((row["palette"] as String).hasPrefix("[[\"#"))
        let display = library.root.appending(path: row["local_path"] as String)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(display as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1600)
        XCTAssertEqual(image.height, 800)
    }

    func testAPictureThatWontDecodeIsMarkedFailed() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        try library.upsert(ImportRecord(id: "x:1", platform: "x", media: [ImportMedia(ord: 0) { Data("not a picture".utf8) }]))
        XCTAssertEqual(try library.db.read { try String.fetchOne($0, sql: "select status from media") }, "failed")
    }

    func testMergeNeverReplacesRicherDataWithPoorer() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        try library.upsert(ImportRecord(id: "ig:1", platform: "instagram", kind: "image", author: "a", text: "words", createdAt: 100, createdEstimated: true, hydrated: 1))
        try library.upsert(ImportRecord(id: "ig:1", platform: "instagram", kind: "link", author: "b", createdAt: 200, hydrated: 0))
        let row = try XCTUnwrap(try library.db.read { try Row.fetchOne($0, sql: "select * from item") })
        XCTAssertEqual(row["kind"] as String, "image")
        XCTAssertEqual(row["author"] as String, "a")
        XCTAssertEqual(row["text"] as String, "words")
        XCTAssertEqual(row["created_at"] as Int, 200, "a real date replaces an estimate")
        XCTAssertEqual(row["hydrated"] as Int, 1)
    }

    func testUnavailablePostsLeaveTheMap() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        let notice = "This Post is from a suspended account. {learnmore}"
        for (index, text) in [notice, "a real liked post", notice].enumerated() {
            try library.upsert(ImportRecord(id: "x:\(index)", platform: "x", kind: "text", text: text, interactions: [ImportInteraction(type: "like", at: 0)]))
        }
        try library.db.write { try $0.execute(sql: "insert into embedding(item_id, model, vector) values ('x:0', 'm', x'00')") }
        XCTAssertEqual(try library.markUnavailable(), 2)
        try library.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from embedding"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "select text from item where id = 'x:1'"), "a real liked post")
        }
    }
}

final class HydratorTests: XCTestCase {
    func testXParsing() {
        // swiftlint:disable:next force_try
        let data = try! JSONValue.parse(#"{"user":{"screen_name":"someone"},"created_at":"2023-04-23T12:00:00.000Z","mediaDetails":[{"media_url_https":"https://a/1.jpg","type":"photo"},{"media_url_https":"https://a/2.jpg","type":"video"}]}"#)
        let found = Hydrator.parseXSyndication(data)
        XCTAssertEqual(found.author, "someone")
        XCTAssertEqual(found.media.count, 2)
        XCTAssertTrue(found.media[1].video)
        XCTAssertEqual(found.createdAt, 1682251200)
        XCTAssertTrue(Hydrator.xToken("1176576000000000000").allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testInstagramPages() throws {
        let embed = ##"<div><img class="EmbeddedMediaImage" alt="x" src="https://scontent.cdninstagram.com/a.jpg?x=1&amp;y=2"><div class="Caption"><a class="CaptionUsername" href="#">studio_b</a> Clay &amp; light<br />second line<div class="CaptionComments"></div></div></div>"##
        let out = try XCTUnwrap(Hydrator.parseInstagramEmbed(embed))
        XCTAssertTrue(out.media[0].url.hasSuffix("x=1&y=2"))
        XCTAssertEqual(out.author, "studio_b")
        XCTAssertTrue(out.text?.hasPrefix("Clay & light") == true)
        let og = #"<meta property="og:image" content="https://cdn/b.jpg" /><meta property="og:description" content="12 likes, 3 comments - architect_c on March 3, 2023: &quot;Concrete stairs&quot;. " />"#
        let page = try XCTUnwrap(Hydrator.parseInstagramOpenGraph(og))
        XCTAssertEqual(page.media[0].url, "https://cdn/b.jpg")
        XCTAssertEqual(page.author, "architect_c")
        XCTAssertTrue(page.text?.contains("Concrete stairs") == true)
        XCTAssertNil(Hydrator.parseInstagramOpenGraph("<html>login</html>"))
        let signIn = #"<meta property="og:title" content="Instagram" /><meta property="og:image" content="https://static.cdninstagram.com/rsrc.php/v4/yD/r/R0fBIMurK8v.png" />"#
        XCTAssertNil(Hydrator.parseInstagramOpenGraph(signIn), "Instagram's sign-in page isn't the post")
    }

    func testPostsSavedWithInstagramsLogoGoBackToWaiting() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        for code in ["walled", "real"] {
            try library.upsert(ImportRecord(id: "ig:\(code)", platform: "instagram", kind: "link", url: "https://www.instagram.com/p/\(code)/",
                                            interactions: [ImportInteraction(type: "like", at: 1)]))
        }
        // How a post the sign-in page stood in for was stored, and a post that was really fetched.
        try library.db.write { db in
            for (id, text, image) in [("ig:walled", "Instagram", "https://static.cdninstagram.com/rsrc.php/v4/yD/r/R0fBIMurK8v.png"),
                                      ("ig:real", "Concrete stairs", "https://scontent.cdninstagram.com/b.jpg")] {
                try db.execute(sql: "update item set hydrated = 1, kind = 'image', text = ? where id = ?", arguments: [text, id])
                try db.execute(sql: "insert into media(item_id, ord, original_url, status) values (?, 0, ?, 'ok')", arguments: [id, image])
                try db.execute(sql: "insert into embedding(item_id, model, vector) values (?, 'clip-vit-b-32', x'00')", arguments: [id])
                try db.execute(sql: "insert into layout(item_id, model, x, y, cluster) values (?, 'clip-vit-b-32', 1, 1, 0)", arguments: [id])
            }
        }
        XCTAssertEqual(try Hydrator.forgetSignInPages(library: library), 1)
        try library.db.read { db in
            let walled = try XCTUnwrap(Row.fetchOne(db, sql: "select hydrated, hydrate_attempts, kind, text from item where id = 'ig:walled'"))
            XCTAssertEqual(walled[0] as Int, 0)
            XCTAssertEqual(walled[1] as Int, 0)
            XCTAssertEqual(walled[2] as String, "link")
            XCTAssertNil(walled[3] as String?)
            for table in ["media", "embedding", "layout"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from \(table) where item_id = 'ig:walled'"), 0, table)
                XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from \(table) where item_id = 'ig:real'"), 1, table)
            }
            XCTAssertEqual(try String.fetchOne(db, sql: "select text from item where id = 'ig:real'"), "Concrete stairs")
        }
        XCTAssertEqual(try Hydrator.forgetSignInPages(library: library), 0)
    }

    private func library() throws -> LibraryWriter {
        let library = try LibraryWriter(root: try neutralFolder())
        for index in 0..<15 {
            try library.upsert(ImportRecord(id: "x:\(1_000_000_000_000 + index)", platform: "x", interactions: [ImportInteraction(type: "like", at: index)]))
        }
        return library
    }

    func testStopsAfterTenNetworkFailuresWithoutBlamingThePosts() throws {
        let library = try library()
        let calls = LockedCount()
        let offline = WebFetcher { url, _, _ in
            calls.add()
            throw FetchFailure(url: url, status: nil, message: "offline")
        }
        let stats = try Hydrator(fetcher: offline, delay: 0).hydrate(library: library, reporter: silent)
        XCTAssertTrue(stats.stoppedOnFailures)
        XCTAssertEqual(calls.value, 10)
        XCTAssertEqual(try library.db.read { try Int.fetchOne($0, sql: "select sum(hydrate_attempts) from item") }, 0)
    }

    func testTriesPostsItHasNotTriedBeforeOnesThatFailed() throws {
        let library = try library()
        // The newest post has failed, as thousands can when a run restarts from the top.
        try library.db.write { try $0.execute(sql: "update item set hydrate_attempts = 1 where id = 'x:1000000000014'") }
        let asked = LockedList()
        let gone = WebFetcher { url, _, _ in
            asked.add(url)
            return Data(#"{"__typename":"TweetTombstone"}"#.utf8)
        }
        _ = try Hydrator(fetcher: gone, delay: 0).hydrate(library: library, reporter: silent)
        XCTAssertEqual(asked.values.count, 15)
        XCTAssertTrue(asked.values[0].contains("id=1000000000013"), "the newest untried post goes first")
        XCTAssertTrue(asked.values[14].contains("id=1000000000014"), "the failed one waits until the end")
    }

    func testSaysWhatBecameOfEveryPost() throws {
        let library = try library()
        try library.db.write { try $0.execute(sql: "update item set hydrate_attempts = 2 where id = 'x:1000000000014'") }
        let said = LockedList()
        let reporter = PipelineReporter(progress: { _ in }, say: { said.add($0) })
        let gone = WebFetcher { _, _, _ in Data(#"{"__typename":"TweetTombstone"}"#.utf8) }
        let stats = try Hydrator(fetcher: gone, delay: 0).hydrate(library: library, reporter: reporter)
        XCTAssertEqual(stats.unreachable, 1)
        XCTAssertEqual(stats.toRetry, 14)
        XCTAssertTrue(said.values.contains { $0.contains("0 fetched, 14 to retry, 1 unreachable") }, "\(said.values)")
    }

    func testTryingUnreachablePostsAgainTakesOnlyThose() throws {
        let library = try library()
        try library.db.write { db in
            try db.execute(sql: "update item set hydrated = -1, hydrate_attempts = 3 where id in ('x:1000000000000', 'x:1000000000001')")
        }
        let asked = LockedList()
        let answers = WebFetcher { url, _, _ in
            asked.add(url)
            return url.contains("id=1000000000001") ? Data(#"{"text":"still here"}"#.utf8) : Data(#"{"__typename":"TweetTombstone"}"#.utf8)
        }
        let stats = try Hydrator(fetcher: answers, delay: 0).hydrate(library: library, retryingUnreachable: true, reporter: silent)
        XCTAssertEqual(asked.values.count, 2, "the 13 posts waiting their turn aren't touched")
        XCTAssertEqual(stats.hydrated, 1)
        XCTAssertEqual(stats.unreachable, 1)
        try library.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "select hydrated from item where id = 'x:1000000000001'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "select hydrated from item where id = 'x:1000000000000'"), -1, "stays given up on")
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from item where hydrated = 0 and hydrate_attempts = 0"), 13)
        }
    }

    func testWaitsAtAHumanPaceAndGivesUpOnAPostAfterAFewAttempts() throws {
        let library = try library()
        let waited = LockedCount()
        let gone = WebFetcher { _, _, _ in Data(#"{"__typename":"TweetTombstone"}"#.utf8) }
        let hydrator = Hydrator(fetcher: gone, delay: 1.5, wait: { _ in waited.add() })
        for _ in 0..<Hydrator.maxAttempts { _ = try hydrator.hydrate(library: library, limit: 15, reporter: silent) }
        XCTAssertGreaterThanOrEqual(waited.value, 15 * 3 * 15, "1.5 s per post, in tenths")
        XCTAssertEqual(try library.db.read { try Int.fetchOne($0, sql: "select count(*) from item where hydrated = -1") }, 15)
        let stats = try hydrator.hydrate(library: library, reporter: silent)
        XCTAssertEqual(stats.hydrated + stats.unreachable, 0, "nothing's retried forever")
    }

    func testFetchedPostsClearTheirStaleVectorsAndCanBePaused() throws {
        let library = try library()
        try library.db.write { try $0.execute(sql: "insert into embedding(item_id, model, vector) select id, 'm', x'00' from item") }
        let bytes = picture(seed: 3)
        let answers = WebFetcher { url, _, _ in
            url.contains("syndication") ? Data(#"{"text":"words","mediaDetails":[{"media_url_https":"https://a/1.jpg","type":"photo"}]}"#.utf8) : bytes
        }
        let stopped = LockedCount()
        let reporter = PipelineReporter(progress: { _ in }, say: { _ in }, isCancelled: { stopped.value >= 3 })
        let hydrator = Hydrator(fetcher: answers, delay: 0.1, wait: { _ in stopped.add() })
        XCTAssertThrowsError(try hydrator.hydrate(library: library, reporter: reporter)) { XCTAssertTrue($0 is PipelinePaused) }
        try library.db.read { db in
            let done = try Int.fetchOne(db, sql: "select count(*) from item where hydrated = 1") ?? 0
            XCTAssertGreaterThan(done, 0)
            XCTAssertLessThan(done, 15, "pausing stops it part way")
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from embedding"), 15 - done)
            XCTAssertEqual(try String.fetchOne(db, sql: "select status from media"), "ok")
        }
    }

    func testYouTubeOnlyAsksForThePicture() {
        XCTAssertEqual(YouTubeImporter.thumbnailURL("abc123"), "https://i.ytimg.com/vi/abc123/hqdefault.jpg")
    }
}

private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    func add(_ value: String) {
        lock.lock()
        list.append(value)
        lock.unlock()
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

final class TakeoutTests: XCTestCase {
    private func takeout() throws -> Archive {
        let root = try neutralFolder()
        let history = #"[{"header":"YouTube","title":"Watched How risograph works","titleUrl":"https://www.youtube.com/watch?v=abc123DEF","subtitles":[{"name":"Print Shop","url":"x"}],"time":"2024-01-02T03:04:05.000Z"},{"header":"YouTube","title":"Watched a video that has been removed","time":"2024-01-03T03:04:05.000Z"}]"#
        try write(Data(history.utf8), root, "Takeout/YouTube and YouTube Music/history/watch-history.json")
        try write(Data("Video ID,Playlist Video Creation Timestamp\nabc123DEF,2024-02-01T00:00:00+00:00\n".utf8), root, "Takeout/YouTube and YouTube Music/playlists/Liked videos-videos.csv")
        try write(Data("Video ID,Playlist Video Creation Timestamp\nxyz789GHI,2024-03-01T00:00:00+00:00\n".utf8), root, "Takeout/YouTube and YouTube Music/playlists/Type-videos.csv")
        try write(Data("Playlist ID,Title\nP1,Type\n".utf8), root, "Takeout/YouTube and YouTube Music/playlists/playlists.csv")
        try write(Data("Comment ID,Channel ID,Comment Create Timestamp,Video ID,Comment Text\nc1,ch,2024-04-01T00:00:00+00:00,xyz789GHI,Nice\n".utf8), root, "Takeout/YouTube and YouTube Music/comments/comments.csv")
        let search = #"[{"title":"Searched for foggy coastline","titleUrl":"https://google.com/search?q=foggy","time":"2023-01-01T00:00:00Z"},{"title":"Searched for Foggy Coastline","time":"2023-06-01T00:00:00Z"},{"title":"Searched for mri results lab","time":"2023-01-02T00:00:00Z"},{"title":"Visited Some site","time":"2023-01-03T00:00:00Z"}]"#
        try write(Data(search.utf8), root, "Takeout/My Activity/Search/MyActivity.json")
        try write(Data(#"[{"title":"Searched for hand drawn type","time":"2023-02-01T00:00:00Z"}]"#.utf8), root, "Takeout/My Activity/Image Search/MyActivity.json")
        try write(Data(#"[{"title":"Searched for something in chrome","time":"2023-03-01T00:00:00Z"}]"#.utf8), root, "Takeout/My Activity/Chrome/MyActivity.json")
        return try Archive([root])
    }

    func testDetectsBothFromOneTakeout() throws {
        XCTAssertEqual(ArchiveImporters.detect(try takeout()).map { $0.name }, ["youtube", "google"])
    }

    func testYouTubeMergesAVideosInteractions() throws {
        var records: [ImportRecord] = []
        try YouTubeImporter.parse(try takeout()) { records.append($0) }
        let types = records.filter { $0.id == "youtube:abc123DEF" }.flatMap { $0.interactions.map(\.type) }
        XCTAssertEqual(Set(types), ["view", "like"])
        let saved = records.first { $0.id == "youtube:xyz789GHI" && $0.interactions[0].type == "save" }
        XCTAssertEqual(saved?.interactions[0].collection, "Type")
        XCTAssertTrue(records.contains { $0.interactions[0].type == "comment" })
        XCTAssertEqual(records.first { $0.interactions[0].type == "view" }?.text, "How risograph works")
    }

    func testGoogleReadsSearchesOnlyAndSkipsSensitiveOnes() throws {
        var records: [ImportRecord] = []
        try GoogleImporter.parse(try takeout()) { records.append($0) }
        XCTAssertEqual(Set(records.compactMap { $0.text?.lowercased() }), ["foggy coastline", "hand drawn type"])
        XCTAssertEqual(Set(records.filter { $0.text?.lowercased() == "foggy coastline" }.map(\.id)).count, 1, "the same search twice is one item")
        XCTAssertTrue(records.allSatisfy { $0.platform == "google" && $0.hydrated == 1 })
    }
}

final class LiveSyncTests: XCTestCase {
    private func opener(_ routes: [(String, String)]) -> (String) throws -> Data {
        { url in
            for (prefix, body) in routes where url.hasPrefix(prefix) { return Data(body.utf8) }
            throw FetchFailure(url: url, status: 404, message: "no route for \(url)")
        }
    }

    private func post(_ uri: String, handle: String = "ann.test", did: String = "did:me", image: String? = nil) -> String {
        let embed = image.map { #","embed":{"images":[{"fullsize":"\#($0)"}]}"# } ?? ""
        return #"{"uri":"\#(uri)","author":{"did":"\#(did)","handle":"\#(handle)"},"record":{"text":"hello","createdAt":"2024-05-01T00:00:00Z"}\#(embed)}"#
    }

    func testBlueskyReadsPostsRepostsAndLikes() throws {
        let app = "https://public.api.bsky.app/xrpc", host = "https://bsky.social/xrpc"
        let fetcher = SyncFetcher(delay: 0, opener: opener([
            ("\(app)/com.atproto.identity.resolveHandle", #"{"did":"did:me"}"#),
            ("\(app)/app.bsky.feed.getAuthorFeed", #"{"feed":[{"post":\#(post("at://did:me/app.bsky.feed.post/1"))},{"post":\#(post("at://did:other/app.bsky.feed.post/2", handle: "bo.test", did: "did:other")),"reason":{"$type":"app.bsky.feed.defs#reasonRepost","indexedAt":"2024-06-01T00:00:00Z"}}]}"#),
            ("\(host)/com.atproto.repo.listRecords", #"{"records":[{"value":{"subject":{"uri":"at://did:other/app.bsky.feed.post/3"},"createdAt":"2024-07-01T00:00:00Z"}}]}"#),
            ("\(app)/app.bsky.feed.getPosts", #"{"posts":[\#(post("at://did:other/app.bsky.feed.post/3", handle: "bo.test", did: "did:other", image: "https://cdn.test/a.jpg"))]}"#),
        ]), wait: { _ in })
        let library = try LibraryWriter(root: try neutralFolder())
        try Pipeline.sync(source: "bluesky", account: "ann.test", library: library, fetcher: fetcher, reporter: silent)
        try library.db.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "select type from interaction order by type"), ["like", "post", "repost"])
            XCTAssertEqual(try String.fetchOne(db, sql: "select original_url from media"), "https://cdn.test/a.jpg")
            XCTAssertEqual(try String.fetchOne(db, sql: "select value from meta where key = 'sync_bluesky'"), "ann.test")
        }
    }

    func testArenaReadsBlocksAsSavesInTheirChannel() throws {
        let host = "https://api.are.na/v2"
        let fetcher = SyncFetcher(delay: 0, opener: opener([
            ("\(host)/users/ann/channels", #"{"channels":[{"slug":"spaces","title":"Spaces"}],"total_pages":1}"#),
            ("\(host)/channels/spaces/contents", #"{"contents":[{"id":7,"base_class":"Block","class":"Image","title":"A room","created_at":"2024-01-01T00:00:00Z","image":{"large":{"url":"https://cdn.test/room.jpg"}},"user":{"slug":"ann"}},{"id":8,"base_class":"Channel","class":"Channel","title":"nested"}]}"#),
        ]), wait: { _ in })
        let library = try LibraryWriter(root: try neutralFolder())
        try Pipeline.sync(source: "arena", account: "ann", library: library, fetcher: fetcher, reporter: silent)
        try library.db.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "select type, collection from interaction"))
            XCTAssertEqual(row["type"] as String, "save")
            XCTAssertEqual(row["collection"] as String, "Spaces")
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from item"), 1)
        }
    }

    func testFetcherWaitsBetweenRequestsAndStopsAfterTenFailures() {
        var waits: [TimeInterval] = []
        let fetcher = SyncFetcher(delay: 1.5, opener: { url in throw FetchFailure(url: url, status: nil, message: "offline") }, wait: { waits.append($0) })
        var stopped = false
        for _ in 0..<10 {
            do { _ = try fetcher.json("https://x.test", "a") } catch is SyncFetcher.TooManyFailures { stopped = true } catch {}
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(waits, [TimeInterval](repeating: 1.5, count: 10))
    }
}

final class LayoutTests: XCTestCase {
    /// Blobs of items around a few centers, as unit vectors in a small space.
    private func blobs(_ centers: Int, each: Int, dimensions: Int = 16, seed: UInt64 = 1) -> (Matrix, [Int]) {
        var random = SeededRandom(seed: seed)
        let means = (0..<centers).map { _ in (0..<dimensions).map { _ in Float(random.normal()) } }
        var values: [Float] = [], labels: [Int] = []
        for (label, mean) in means.enumerated() {
            for _ in 0..<each {
                values += mean.map { $0 + Float(random.normal()) * 0.08 }
                labels.append(label)
            }
        }
        return (Matrix(rows: centers * each, columns: dimensions, values: values).unitRows, labels)
    }

    func testNearestFindsEachRowItselfThenTheClosest() {
        let vectors = Matrix(rows: 4, columns: 2, values: [1, 0, 0.99, 0.14, 0, 1, -1, 0]).unitRows
        let found = VectorMath.nearest(vectors, k: 2)
        XCTAssertEqual(Array(found.indices[0..<2]), [0, 1])
        XCTAssertEqual(found.distances[0], 0)
        XCTAssertEqual(Array(found.indices[6..<8]).first, 3)
    }

    func testEigenOfASmallTable() {
        let (values, vectors) = VectorMath.symmetricEigen([2, 1, 1, 2], n: 2)
        XCTAssertEqual(values[0], 3, accuracy: 1e-9)
        XCTAssertEqual(values[1], 1, accuracy: 1e-9)
        XCTAssertEqual(abs(vectors[0]), 1 / 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testPercentileInterpolates() {
        XCTAssertEqual(VectorMath.percentile([1, 2, 3, 4], 75), 3.25, accuracy: 1e-6)
    }

    func testUMAPKeepsNeighborsTogether() {
        let (vectors, labels) = blobs(5, each: 80)
        let neighbors = VectorMath.nearest(vectors, k: 16)
        let xy = UMAP.embed(vectors, neighbors: neighbors)
        var same = 0, total = 0
        for item in 0..<vectors.rows {
            var best = Float.infinity, nearest = 0
            for other in 0..<vectors.rows where other != item {
                let dx = xy[item * 2] - xy[other * 2], dy = xy[item * 2 + 1] - xy[other * 2 + 1]
                if dx * dx + dy * dy < best { (best, nearest) = (dx * dx + dy * dy, other) }
            }
            if labels[nearest] == labels[item] { same += 1 }
            total += 1
        }
        XCTAssertGreaterThan(Double(same) / Double(total), 0.98)
        XCTAssertEqual(xy, UMAP.embed(vectors, neighbors: neighbors), "the same vectors draw the same map")
    }

    func testHDBSCANNeverJoinsSeparateBlobs() {
        var random = SeededRandom(seed: 3)
        var xy: [Float] = []
        var truth: [Int] = []
        for (label, center) in [(100.0, 100.0), (500.0, 200.0), (300.0, 800.0)].enumerated() {
            for _ in 0..<120 {
                xy += [Float(center.0 + random.normal() * 12), Float(center.1 + random.normal() * 12)]
                truth.append(label)
            }
        }
        let found = HDBSCAN.regions(xy)
        // "Leaf" selection takes the finest regions, so a blob can divide, but regions never span two.
        XCTAssertGreaterThanOrEqual(Set(found).subtracting([-1]).count, 3)
        for label in Set(found).subtracting([-1]) {
            XCTAssertEqual(Set(truth.indices.filter { found[$0] == label }.map { truth[$0] }).count, 1)
        }
        XCTAssertEqual(HDBSCAN.regions([1, 1, 2, 2]), [0, 0], "too few to divide")
    }

    func testRegionsNestAndGetDistinctNames() throws {
        var random = SeededRandom(seed: 4)
        let topics = ["synth patch sequencer", "kerning typeface specimen", "fern moss garden", "senate vote bill", "pinball arcade machine",
                      "sourdough bread crumb", "eurorack oscillator module", "lettering brush script", "succulent cactus pot", "election ballot county"]
        var xy: [Float] = [], texts: [String?] = [], leaf: [Int] = []
        for (index, topic) in topics.enumerated() {
            let cx = Double(index % 5) * 60 + (index < 5 ? 0 : 600)
            for _ in 0..<40 {
                xy += [Float(cx + random.normal() * 8), Float(300 + random.normal() * 8)]
                texts.append("\(topic) \(["today", "again", "lol", ""][Int(random.next() % 4)])")
                leaf.append(index)
            }
        }
        var (regions, roots) = RegionNesting.build(xy: xy, leaf: leaf, top: 2, branching: 3)
        XCTAssertEqual(roots.count, 2)
        XCTAssertTrue(roots.allSatisfy { regions[$0]?.children.count == 5 })
        XCTAssertTrue((0..<10).allSatisfy { roots.contains(regions[$0]?.parent ?? -1) })

        let vectors = Matrix(rows: texts.count, columns: 4)
        try RegionLabels.name(regions: &regions, roots: roots, vectors: vectors, texts: texts, hasImage: [Bool](repeating: false, count: texts.count),
                              concepts: ["gardens"], modifiers: [], phraseVectors: nil)
        let names = (0..<10).map { regions[$0]?.label ?? "" }
        XCTAssertEqual(Set(names.map(RegionLabels.key)).count, 10, "each name used once")
        for (index, topic) in topics.enumerated() {
            XCTAssertTrue(Set(names[index].split(separator: " ")).isSubset(of: Set(topic.split(separator: " "))), names[index])
        }
        for root in roots {
            for kid in regions[root]?.children ?? [] {
                XCTAssertNotEqual(RegionLabels.key(regions[kid]?.label ?? ""), RegionLabels.key(regions[root]?.label ?? ""))
            }
        }
        XCTAssertEqual(RegionLabels.tokens("#GenerativeArt by @someone https://x.co/a"), ["generative", "art", "by"])
        XCTAssertTrue(RegionLabels.ngrams(RegionLabels.tokens("my new drum machine")).contains("drum machine"))
        XCTAssertFalse(RegionLabels.ngrams(RegionLabels.tokens("my new")).contains("my new"))
        XCTAssertEqual(RegionLabels.key("Houseplants"), RegionLabels.key("houseplant"))
    }

    func testMapRecipeTextCleaning() {
        XCTAssertEqual(MapVectors.cleanFileText("IMG_2020 CoolPoster_v2, in Client Work"), "Cool Poster Client Work")
        XCTAssertEqual(MapVectors.cleanPostText("RT @ann: fern &amp; moss https://x.co/a #garden .@bo"), "fern & moss garden")
        XCTAssertEqual(MapVectors.wordsWeight(wordCount: 1, isFile: false), 0)
        XCTAssertEqual(MapVectors.wordsWeight(wordCount: 20, isFile: false), 1)
        XCTAssertEqual(MapVectors.wordsWeight(wordCount: 20, isFile: true), 0.6)
    }

    func testFilesMoveTowardPostsAboutTheSameThing() {
        var random = SeededRandom(seed: 8)
        let dimensions = 12
        let subject = (0..<dimensions).map { _ in Float(random.normal()) }
        let fileLook = (0..<dimensions).map { _ in Float(random.normal()) }
        var values: [Float] = [], isFile: [Bool] = []
        for _ in 0..<60 {
            values += subject.map { $0 + Float(random.normal()) * 0.15 }
            isFile.append(false)
        }
        for _ in 0..<30 {
            values += zip(subject, fileLook).map { $0 * 0.6 + $1 * 0.4 + Float(random.normal()) * 0.15 }
            isFile.append(true)
        }
        let vectors = Matrix(rows: 90, columns: dimensions, values: values).unitRows
        let moved = MapVectors.pullFilesToPosts(vectors, isFile: isFile)
        func closeness(_ table: Matrix) -> Float {
            let center = table.mean(of: Array(0..<60))
            var sum: Float = 0
            for file in 60..<90 { for d in 0..<dimensions { sum += table.values[file * dimensions + d] * center[d] } }
            return sum
        }
        XCTAssertGreaterThan(closeness(moved), closeness(vectors))
        XCTAssertEqual(Array(moved.values[0..<dimensions]), Array(vectors.values[0..<dimensions]), "posts stay where they are")
    }

    func testConceptsFileMatchesThePipelines() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pipeline = repo.appending(path: "pipeline/topograph/concepts.txt")
        let mine = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources/TopographCore/Resources/concepts.txt")
        XCTAssertEqual(try String(contentsOf: pipeline, encoding: .utf8), try String(contentsOf: mine, encoding: .utf8))
        XCTAssertTrue(RegionLabels.loadModifiers().contains("purple"))
    }

    func testBuildingAMapFromVectorsWritesWhatTheAppReads() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        let (vectors, labels) = blobs(3, each: 40, dimensions: CLIPEncoder.dimensions)
        try library.db.write { db in
            for item in 0..<vectors.rows {
                try db.execute(sql: "insert into item(id, platform, kind, text, created_at, hydrated) values (?, 'x', 'text', ?, 1600000000, 1)",
                               arguments: ["x:\(item)", "topic\(labels[item]) word\(labels[item]) thing"])
                try db.execute(sql: "insert into interaction(item_id, type, at) values (?, 'post', 1600000000)", arguments: ["x:\(item)"])
                let data = Array(vectors.row(item)).withUnsafeBytes { Data($0) }
                try db.execute(sql: "insert into embedding(item_id, model, vector) values (?, ?, ?)", arguments: ["x:\(item)", CLIPEncoder.modelName, data])
            }
        }
        try library.setMeta("embedding_model", CLIPEncoder.modelName)
        try MapBuilder.computeLayout(library: library, recipe: .pictures, clip: nil, reporter: silent)
        let reader = try Library(root: library.root)
        let map = try reader.map(.pictures)
        XCTAssertEqual(map.recipe, .pictures)
        try library.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from layout"), vectors.rows)
            XCTAssertEqual(try Double.fetchOne(db, sql: "select max(x) from layout") ?? 9999, 950, accuracy: 460)
            let neighbors = try String.fetchOne(db, sql: "select neighbors from layout limit 1") ?? ""
            XCTAssertEqual(try JSONValue.parse(neighbors).array?.count, 8)
            XCTAssertEqual(try String.fetchOne(db, sql: "select value from meta where key = 'map'"), "pictures")
            XCTAssertGreaterThan(try Int.fetchOne(db, sql: "select count(*) from cluster") ?? 0, 0)
        }
    }

    func testSearchesFloatOverThePicturesTheyAreAbout() {
        var random = SeededRandom(seed: 3)
        let dimensions = 32
        func unit(_ v: [Float]) -> [Float] { let l = sqrt(v.reduce(0) { $0 + $1 * $1 }); return v.map { $0 / l } }
        func noise(_ scale: Float) -> [Float] { (0..<dimensions).map { _ in Float(random.normal()) * scale } }
        let subjects = (0..<3).map { _ in unit(noise(1)) }
        // Words sit apart on the map, and every search shares a lean toward words.
        let wordy = unit(noise(1))
        let centers: [(Float, Float)] = [(100, 100), (500, 900), (900, 100)]
        var land: [Float] = [], xy: [Float] = [], hasPicture: [Bool] = []
        for (subject, center) in zip(subjects, centers) {
            for _ in 0..<20 {
                land += unit(zip(subject, noise(0.05)).map(+))
                xy += [center.0 + Float(random.normal()) * 5, center.1 + Float(random.normal()) * 5]
                hasPicture.append(true)
            }
        }
        for subject in subjects {
            for _ in 0..<20 {
                land += unit((0..<dimensions).map { subject[$0] * 0.3 + wordy[$0] + Float(random.normal()) * 0.05 })
                xy += [500, 500]
                hasPicture.append(false)
            }
        }
        var sky: [Float] = []
        for subject in subjects {
            for _ in 0..<5 { sky += unit((0..<dimensions).map { subject[$0] * 0.5 + wordy[$0] + Float(random.normal()) * 0.05 }) }
        }
        let placed = MapBuilder.placeClouds(Matrix(rows: 15, columns: dimensions, values: sky),
                                            over: Matrix(rows: 120, columns: dimensions, values: land), hasPicture: hasPicture, xy: xy)
        for (search, cloud) in placed.enumerated() {
            let center = centers[search / 5]
            XCTAssertLessThan(hypot(cloud.x - center.0, cloud.y - center.1), 40, "over its own subject's pictures")
            XCTAssertEqual(Int(cloud.near[0]) / 20, search / 5)
            XCTAssertTrue(cloud.near.allSatisfy { $0 < 60 }, "pictures only")
        }
    }

    func testSearchesAreCloudsNotLand() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        let (vectors, _) = blobs(3, each: 40, dimensions: CLIPEncoder.dimensions)
        try library.db.write { db in
            for item in 0..<vectors.rows {
                let search = item % 10 == 0
                let id = search ? "google:\(item)" : "x:\(item)"
                try db.execute(sql: "insert into item(id, platform, kind, text, created_at, hydrated) values (?, ?, 'text', ?, 1600000000, 1)",
                               arguments: [id, search ? "google" : "x", "words \(item)"])
                try db.execute(sql: "insert into interaction(item_id, type, at) values (?, ?, 1600000000)", arguments: [id, search ? "search" : "post"])
                let data = Array(vectors.row(item)).withUnsafeBytes { Data($0) }
                try db.execute(sql: "insert into embedding(item_id, model, vector) values (?, ?, ?)", arguments: [id, CLIPEncoder.modelName, data])
            }
        }
        try library.setMeta("embedding_model", CLIPEncoder.modelName)
        try MapBuilder.computeLayout(library: library, recipe: .pictures, clip: nil, reporter: silent)
        try library.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from layout where item_id like 'google:%'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from cloud"), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from layout"), 108)
        }
        let map = try Library(root: library.root).map(.pictures)
        XCTAssertEqual(map.clouds.searches.count, 12)
        XCTAssertEqual(map.waiting, 0, "clouds aren't waiting to be mapped")
        XCTAssertEqual(try Library(root: library.root).sources().unplaced, 0)
    }
}

final class WordsTokenizerTests: XCTestCase {
    func testSplitsLikeBERT() {
        let tokenizer = WordsTokenizer(vocabulary: ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "hello", "world", "un", "##believ", "##able", ",", "cafe"].joined(separator: "\n"))
        XCTAssertEqual(tokenizer.tokens("Hello, World"), [2, 4, 9, 5, 3])
        XCTAssertEqual(tokenizer.tokens("unbelievable"), [2, 6, 7, 8, 3])
        XCTAssertEqual(tokenizer.tokens("Café"), [2, 10, 3], "accents go")
        XCTAssertEqual(tokenizer.tokens("zzz"), [2, 1, 3], "unknown words")
        XCTAssertEqual(tokenizer.tokens(String(repeating: "hello ", count: 400)).count, 256)
    }
}

/// One thing, one item: a repost joins the post it reposts, and your own Instagram post is the
/// same item as your like of it. Libraries imported before this are mended on re-import.
final class SameThingTests: XCTestCase {
    private let liked = "1750000000000000001", repost = "1760000000000000000", source = "1740000000000000000"
    private let repostWithPicture = "1770000000000000000", unliked = "1780000000000000000"

    private func xArchive() throws -> Archive {
        let root = try neutralFolder()
        func shim(_ feed: String, _ json: String) -> Data { Data("window.YTD.\(feed).part0 = \(json)".utf8) }
        func tweet(_ id: String, _ text: String, _ extra: String = "") -> String {
            #"{"tweet": {"id_str": "\#(id)", "full_text": "\#(text)", "created_at": "Mon Feb 05 14:00:34 +0000 2024", "entities": {"urls": []}\#(extra)}}"#
        }
        let tweets = [
            tweet(repost, "RT @maker: First things first. Enable the flag in settings, then reload https://example.com/a and wa…"),
            tweet(repostWithPicture, "RT @painter: Studio",
                  #", "extended_entities": {"media": [{"type": "photo", "media_url_https": "https://pbs.twimg.com/media/K.jpg", "source_status_id_str": "\#(source)"}]}"#),
            tweet(unliked, "RT @someone: Something you never liked, only passed on"),
        ]
        try write(shim("account", #"[{"account": {"username": "me"}}]"#), root, "t/data/account.js")
        try write(shim("tweets", "[" + tweets.joined(separator: ",") + "]"), root, "t/data/tweets.js")
        try write(shim("like", #"[{"like": {"tweetId": "\#(liked)", "fullText": "First things first. Enable the flag in settings, then reload https://t.co/xyz and watch it go"}}]"#),
                  root, "t/data/like.js")
        return try Archive([root])
    }

    func testARepostIsThePostItReposts() throws {
        var reposts: [String: ImportRecord] = [:]
        try XImporter.parse(try xArchive()) { record in
            if record.interactions.first?.type == "repost" { reposts[record.id] = record }
        }
        let post = try XCTUnwrap(reposts["x:\(liked)"])
        XCTAssertEqual(post.replaces, ["x:\(repost)"])
        XCTAssertEqual(post.author, "maker")
        XCTAssertFalse(post.text?.hasPrefix("RT @") ?? true)
        XCTAssertEqual(reposts["x:\(source)"]?.replaces, ["x:\(repostWithPicture)"])
        XCTAssertEqual(reposts["x:\(unliked)"]?.replaces, [], "nothing to join")
    }

    func testGistMatchesPython() {
        XCTAssertEqual(XImporter.gist("RT body with https://t.co/x a link and a cut wor…"), "rt body with a link and a cut")
        XCTAssertEqual(XImporter.gist("  Two\n spaces  "), "two spaces")
    }

    func testReimportMendsALibrary() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        // As an older import left it: the repost as an item of its own, fetched and mapped.
        try library.upsert(ImportRecord(id: "x:\(repost)", platform: "x", kind: "image", text: "RT @maker: First things", hydrated: 1,
                                        interactions: [ImportInteraction(type: "repost", at: 1_707_141_634)]))
        try library.db.write { db in
            try db.execute(sql: "insert into media(item_id, ord, thumb_path, status) values (?, 0, 'media/aa/t.webp', 'ok')", arguments: ["x:\(repost)"])
            try db.execute(sql: "insert into layout(item_id, model, x, y, cluster) values (?, 'm', 1, 2, 3)", arguments: ["x:\(repost)"])
        }
        let archive = try xArchive()
        for _ in 0..<2 {
            try XImporter.parse(archive) { try library.upsert($0) }
        }
        try library.db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from item where id = ?", arguments: ["x:\(repost)"]), 0)
            XCTAssertEqual(Set(try String.fetchAll(db, sql: "select type from interaction where item_id = ?", arguments: ["x:\(liked)"])), ["like", "repost"])
            // Its picture and place came along, so it isn't fetched again or lost from the map.
            XCTAssertEqual(try String.fetchOne(db, sql: "select thumb_path from media where item_id = ?", arguments: ["x:\(liked)"]), "media/aa/t.webp")
            XCTAssertEqual(try Double.fetchOne(db, sql: "select x from layout where item_id = ?", arguments: ["x:\(liked)"]), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "select kind from item where id = ?", arguments: ["x:\(liked)"]), "image")
            XCTAssertEqual(try Int.fetchOne(db, sql: "select count(*) from item"), 3, "the liked post, the post behind the picture, the repost of one never liked")
        }
    }

    func testYourPostYouLikedIsOneItem() throws {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var n = ((1_620_000_000 * 1000 - 1_314_220_021_721) << 23) + 12345
        var code = ""
        for _ in 0..<11 { code = String(alphabet[n % 64]) + code; n /= 64 }
        XCTAssertEqual(PipelineText.instagramShortcodeTime(code), 1_620_000_000)

        let root = try neutralFolder()
        try write(Data(#"{"profile_user": [{"string_map_data": {"Username": {"value": "jb.test"}}}]}"#.utf8), root,
                  "personal_information/personal_information/personal_information.json")
        try write(picture(seed: 1), root, "media/posts/202105/111.jpg")
        try write(picture(seed: 2), root, "media/posts/202105/113.jpg")
        try write(Data(#"""
            [{"media": [{"uri": "media/posts/202105/111.jpg", "creation_timestamp": 1620000000, "title": "Ferns"}]},
             {"media": [{"uri": "media/posts/202105/113.jpg", "creation_timestamp": 1621000000, "title": "Blue hour"}]}]
            """#.utf8), root, "your_instagram_activity/media/posts_1.json")
        try write(Data(#"""
            [{"timestamp": 1620000500, "media": [], "label_values": [
              {"label": "URL", "value": "https://www.instagram.com/p/\#(code)/", "href": "https://www.instagram.com/p/\#(code)/"},
              {"label": "Caption", "value": "Ferns"},
              {"dict": [{"dict": [{"label": "Username", "value": "jb.test"}], "title": ""}], "title": "Owner"}]}]
            """#.utf8), root, "your_instagram_activity/likes/liked_posts.json")

        var records: [ImportRecord] = []
        try InstagramImporter.parse(try Archive([root])) { records.append($0) }
        let mine = records.filter { $0.id == "ig:\(code)" }
        XCTAssertEqual(Set(mine.compactMap { $0.interactions.first?.type }), ["post", "like"])
        let post = try XCTUnwrap(mine.first { $0.interactions.first?.type == "post" })
        XCTAssertEqual(post.url, "https://www.instagram.com/p/\(code)/")
        XCTAssertTrue(post.replaces.first?.hasPrefix("ig:own:") ?? false)
        XCTAssertEqual(records.filter { $0.id.hasPrefix("ig:own:") }.count, 1, "the post you didn't like keeps its own id")
    }
}

final class SamePicturesTests: XCTestCase {
    private func small(_ seed: Int, flat: Bool = false) -> [Float] {
        var random = SeededRandom(seed: UInt64(seed + 1))
        return (0..<(SamePictures.side * SamePictures.side * 3)).map { _ in flat ? 0.5 : Float(random.next() % 256) / 255 }
    }

    func testSameNeedsDetailAndAlmostEveryPixel() {
        let picture = small(1)
        XCTAssertTrue(SamePictures.same(picture, picture.map { min($0 + 0.005, 1) }), "a copy, re-encoded")
        XCTAssertFalse(SamePictures.same(picture, small(2)), "another picture")
        XCTAssertFalse(SamePictures.same(small(0, flat: true), small(0, flat: true)), "flat frames say nothing")
    }

    func testEveryMemberMatchesTheLeadItself() {
        let pictures = ["a", "b", "c"].enumerated().map {
            SamePictures.Picture(id: $1, hash: 0, thumb: "", pixels: 1000 - $0, aspect: 1, time: 0)
        }
        // Frames of a video: each like the next, the first not like the last.
        let sets = SamePictures.sets(pictures, matches: [0: [1], 1: [0, 2], 2: [1]])
        XCTAssertEqual(sets, [[0, 1]])
    }

    func testCandidatesAreCloseHashesOnly() {
        let pairs = SamePictures.candidates([0xFFFF_0000_FFFF_0000, 0xFFFF_0000_FFFF_0001, 0x0123_4567_89AB_CDEF])
        XCTAssertEqual(pairs.map { [$0.0, $0.1] }, [[0, 1]])
    }

    /// A picture with shapes in it, which survive being made small, unlike noise.
    private func shapes(_ seed: Int) -> Data {
        let context = CGContext(data: nil, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var random = SeededRandom(seed: UInt64(seed))
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
        for _ in 0..<8 {
            context.setFillColor(red: CGFloat(random.next() % 256) / 255, green: CGFloat(random.next() % 256) / 255, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: Int(random.next() % 400), y: Int(random.next() % 300), width: 80, height: 60))
        }
        let out = NSMutableData()
        let target = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(target, context.makeImage()!, nil)
        CGImageDestinationFinalize(target)
        return out as Data
    }

    func testFindsCopiesAcrossPlacesAndLeadsWithTheLargest() throws {
        let library = try LibraryWriter(root: try neutralFolder())
        let photo = shapes(3), other = shapes(9)
        for (id, platform, data, width) in [("file:1", "files", photo, 4000), ("ig:1", "instagram", photo, 1080),
                                            ("x:1", "x", other, 1200), ("youtube:1", "youtube", photo, 1280)] {
            try write(data, library.root, "media/\(id).jpg")
            try library.db.write { db in
                try db.execute(sql: "insert into item(id, platform, hydrated) values (?, ?, 1)", arguments: [id, platform])
                try db.execute(sql: "insert into interaction(item_id, type, at) values (?, 'like', 1)", arguments: [id])
                try db.execute(sql: """
                    insert into media(item_id, ord, thumb_path, width, height, phash, status) values (?, 0, ?, ?, ?, 'ffff0000ffff0000', 'ok')
                    """, arguments: [id, "media/\(id).jpg", width, width * 3 / 4])
            }
        }
        XCTAssertEqual(try SamePictures.find(library: library, reporter: silent), 1)
        let rows = try library.db.read { try Row.fetchAll($0, sql: "select item_id, lead from same_picture order by item_id") }
        XCTAssertEqual(rows.map { [$0[0] as String, $0[1] as String] }, [["file:1", "file:1"], ["ig:1", "file:1"]],
                       "another picture with the same hash isn't it, and a video's poster isn't matched")
    }
}
