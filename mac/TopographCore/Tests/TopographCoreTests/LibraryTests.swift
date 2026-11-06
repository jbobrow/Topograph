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
            try db.execute(sql: """
                create table item (id text primary key, platform text, kind text, url text, author text,
                  text text, created_at integer, created_estimated integer default 0,
                  hydrated integer default 0, hydrate_attempts integer default 0);
                create table interaction (item_id text, type text, at integer, at_estimated integer default 0,
                  collection text, source_file text, primary key (item_id, type, at));
                create table media (item_id text, ord integer, kind text, status text, primary key (item_id, ord));
                create table layout (item_id text, model text, x real, y real, cluster integer, neighbors text,
                  primary key (item_id, model));
                create table meta (key text primary key, value text);
                insert into meta values ('embedding_model', 'clip-vit-b-32');
                """)
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
        let items = try Library(root: root).mapItems()
        XCTAssertEqual(items, [
            MapItem(x: 12, y: 34, resonance: 4, mine: false),
            MapItem(x: 100, y: 200, resonance: 2.5, mine: true),
        ])
    }

    func testRepeatedInteractionsCountOnce() throws {
        try place("x:1", types: ["open", "open", "open"])
        XCTAssertEqual(try Library(root: root).mapItems().first?.resonance, 0.5)
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
            try db.execute(sql: "insert into media values ('x:has-picture', 0, 'image', 'ok')")
            try db.execute(sql: "insert into media values ('x:failed-picture', 0, 'image', 'failed')")
        }
        XCTAssertEqual(try Library(root: root).mapItems().count, 2)
    }

    func testOnlyReadsTheCurrentModel() throws {
        try place("x:1")
        try place("x:2", model: "lite")
        XCTAssertEqual(try Library(root: root).mapItems().count, 1)
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
            XCTAssertEqual(try Library(root: root).mapItems().first?.x, 100)
            try db.execute(sql: "commit")
        }
        XCTAssertEqual(try Library(root: root).mapItems().first?.x, 999)
    }

    func testMissingLibraryAndMissingMapSayWhatToDo() throws {
        let nowhere = root.appending(path: "nowhere")
        XCTAssertThrowsError(try Library(root: nowhere)) {
            XCTAssertEqual($0 as? LibraryError, .notFound(path: nowhere.path))
        }
        XCTAssertThrowsError(try Library(root: root).mapItems()) {
            XCTAssertEqual($0 as? LibraryError, .noMap)
        }
    }
}
