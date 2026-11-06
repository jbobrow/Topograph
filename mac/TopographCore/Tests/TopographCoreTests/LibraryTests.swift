import Foundation
import GRDB
import XCTest
@testable import TopographCore

final class LibraryTests: XCTestCase {
    private var root: URL!
    private var writer: DatabaseQueue!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "topograph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        writer = try DatabaseQueue(path: root.appending(path: "topograph.sqlite").path)
        _ = try writer.writeWithoutTransaction { try String.fetchOne($0, sql: "pragma journal_mode = wal") }
        try writer.write { db in
            try db.execute(sql: LibrarySchema.sql)
            try db.execute(sql: "insert into meta values ('embedding_model', 'clip-vit-b-32')")
        }
    }

    override func tearDownWithError() throws {
        writer = nil
        try FileManager.default.removeItem(at: root)
    }

    private func place(_ id: String, x: Double = 100, y: Double = 200, hydrated: Int = 1, text: String? = "words",
                       types: [String] = [], model: String = "clip-vit-b-32") throws {
        try writer.write { db in
            try db.execute(sql: "insert into item(id, platform, text, hydrated) values (?, 'x', ?, ?)",
                           arguments: [id, text, hydrated])
            try db.execute(sql: "insert into layout(item_id, model, x, y, cluster) values (?, ?, ?, ?, 0)",
                           arguments: [id, model, x, y])
            for (at, type) in types.enumerated() {
                try db.execute(sql: "insert into interaction(item_id, type, at) values (?, ?, ?)",
                               arguments: [id, type, at])
            }
        }
    }

    func testReadsPositionsResonanceAndWhatIsMine() throws {
        try place("x:1", x: 12, y: 34, types: ["like", "save"])
        try place("x:2", types: ["post"])
        let items = try Library(root: root).map().items.sorted { $0.id < $1.id }
        XCTAssertEqual(items.map(\.x), [12, 100])
        XCTAssertEqual(items.map(\.y), [34, 200])
        XCTAssertEqual(items.map(\.resonance), [4, 2.5])
        XCTAssertEqual(items.map(\.mine), [false, true])
        XCTAssertEqual(items.map(\.groups), [[.liked, .kept], [.made]])
    }

    func testRepeatedInteractionsCountOnce() throws {
        try place("x:1", types: ["open", "open", "open"])
        XCTAssertEqual(try Library(root: root).map().items.first?.resonance, 0.5)
    }

    func testTimeIsTheFirstRealEngagementThenAnEstimateThenPublication() throws {
        try writer.write { db in
            try db.execute(sql: """
                insert into item(id, platform, created_at) values ('x:real', 'x', 900), ('x:est', 'x', 900), ('x:none', 'x', 900);
                insert into layout(item_id, model, x, y, cluster) values
                  ('x:real', 'clip-vit-b-32', 1, 1, 0), ('x:est', 'clip-vit-b-32', 2, 2, 0), ('x:none', 'clip-vit-b-32', 3, 3, 0);
                insert into interaction(item_id, type, at, at_estimated) values
                  ('x:real', 'like', 100, 1), ('x:real', 'save', 500, 0), ('x:real', 'post', 300, 0),
                  ('x:est', 'like', 200, 1), ('x:est', 'save', 0, 0);
                """)
        }
        let times = Dictionary(uniqueKeysWithValues: try Library(root: root).map().items.map { ($0.id, $0.time) })
        XCTAssertEqual(times["x:real"], 300)
        XCTAssertEqual(times["x:est"], 200)
        XCTAssertEqual(times["x:none"], 900)
    }

    func testFirstPictureGivesThumbnailAndAspect() throws {
        try place("x:1")
        try writer.write { db in
            try db.execute(sql: """
                insert into media(item_id, ord, kind, thumb_path, width, height, status) values
                  ('x:1', 1, 'image', 'second-t.webp', 100, 100, 'ok'),
                  ('x:1', 0, 'image', 'failed-t.webp', 100, 100, 'failed'),
                  ('x:1', 2, 'image', 'third-t.webp', 300, 100, 'ok');
                """)
        }
        let item = try XCTUnwrap(Library(root: root).map().items.first)
        XCTAssertEqual(item.thumb, "second-t.webp")
        XCTAssertEqual(item.aspect, 1)
    }

    func testWaitingItemsCountButGoneOnesDont() throws {
        try place("x:placed")
        try writer.write { db in
            try db.execute(sql: """
                insert into item(id, platform, hydrated, created_at) values
                  ('x:waiting', 'x', 0, 700), ('x:gone', 'x', -1, 800);
                """)
        }
        let map = try Library(root: root).map()
        XCTAssertEqual(map.waiting, 1)
        XCTAssertEqual(map.waitingTimes, [700])
    }

    func testDetailReadsHistoryMediaAndNeighbors() throws {
        try place("x:1", types: ["like"])
        try writer.write { db in
            try db.execute(sql: """
                update item set url = 'https://example.com/1', created_at = 42 where id = 'x:1';
                update layout set neighbors = '["x:2", "x:3"]' where item_id = 'x:1';
                insert into media(item_id, ord, kind, local_path, thumb_path, status) values
                  ('x:1', 1, 'image', 'b-d.webp', 'b-t.webp', 'ok'), ('x:1', 0, 'video', 'a-d.webp', 'a-t.webp', 'ok');
                """)
        }
        let detail = try Library(root: root).detail(of: "x:1")
        XCTAssertEqual(detail.url, "https://example.com/1")
        XCTAssertEqual(detail.createdAt, 42)
        XCTAssertEqual(detail.interactions.map(\.type), ["like"])
        XCTAssertEqual(detail.media.map(\.display), ["a-d.webp", "b-d.webp"])
        XCTAssertEqual(detail.neighbors, ["x:2", "x:3"])
    }

    func testUnknownTypeCountsOneAndNoInteractionsCountZero() {
        XCTAssertEqual(Interactions.resonance(["something new"]), 1)
        XCTAssertEqual(Interactions.resonance([String]()), 0)
    }

    func testLeavesGoneItemsOffTheMap() throws {
        try place("x:gone", hydrated: -1, text: nil)
        try place("x:empty-text", hydrated: -1, text: "")
        try place("x:has-text", hydrated: -1, text: "still here")
        try place("x:has-picture", hydrated: -1, text: nil)
        try place("x:failed-picture", hydrated: -1, text: nil)
        try writer.write { db in
            try db.execute(sql: "insert into media(item_id, ord, kind, status) values ('x:has-picture', 0, 'image', 'ok')")
            try db.execute(sql: "insert into media(item_id, ord, kind, status) values ('x:failed-picture', 0, 'image', 'failed')")
        }
        XCTAssertEqual(try Library(root: root).map().items.count, 2)
    }

    func testOnlyReadsTheCurrentModel() throws {
        try place("x:1")
        try place("x:2", model: "lite")
        XCTAssertEqual(try Library(root: root).map().items.count, 1)
    }

    func testCannotWrite() throws {
        try place("x:1")
        let library = try Library(root: root)
        XCTAssertThrowsError(try library.db.write { try $0.execute(sql: "delete from item") })
        XCTAssertThrowsError(try library.db.read { try $0.execute(sql: "delete from item") })
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "select count(*) from item") }, 1)
    }

    func testReadsWhileAWriterHasATransactionOpen() throws {
        try place("x:1")
        try writer.inDatabase { db in
            try db.execute(sql: "begin immediate")
            try db.execute(sql: "update layout set x = 999")
            // The uncommitted change isn't visible and doesn't block the read.
            XCTAssertEqual(try Library(root: root).map().items.first?.x, 100)
            try db.execute(sql: "commit")
        }
        XCTAssertEqual(try Library(root: root).map().items.first?.x, 999)
    }

    func testColorAndHashComeFromTheFirstPicture() throws {
        try place("x:1")
        try writer.write { db in
            try db.execute(sql: """
                insert into media(item_id, ord, kind, palette, phash, status) values
                  ('x:1', 0, 'image', '[["#262825", 0.29], ["#89a8bb", 0.25]]', 'cbe0349f3788e364', 'ok')
                """)
        }
        let item = try XCTUnwrap(Library(root: root).map().items.first)
        XCTAssertEqual(item.color, 0x262825)
        XCTAssertEqual(item.phash, 0xcbe0349f3788e364)
        XCTAssertEqual(try Library(root: root).detail(of: "x:1").media.first?.palette.map(\.hex), ["#262825", "#89a8bb"])
    }

    func testMissingLibraryAndMissingMapSayWhatToDo() throws {
        try writer.write { try $0.execute(sql: "delete from meta") }
        let nowhere = root.appending(path: "nowhere")
        XCTAssertThrowsError(try Library(root: nowhere)) {
            XCTAssertEqual($0 as? LibraryError, .notFound(path: nowhere.path))
        }
        XCTAssertThrowsError(try Library(root: root).map().items) {
            XCTAssertEqual($0 as? LibraryError, .noMap)
        }
    }
}
