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

    func testTheSamePictureFromSeveralPlacesIsOnePoint() throws {
        try place("file:1", text: "IMG_0042, in Photos", types: ["made"])
        try place("ig:1", text: "Ferns after rain", types: ["post", "like"])
        try place("x:3", types: ["like"])
        try writer.write { db in
            try db.execute(sql: "update item set platform = 'files' where id = 'file:1'")
            try db.execute(sql: "update item set platform = 'instagram', author = 'me', url = 'https://www.instagram.com/p/A/' where id = 'ig:1'")
            try db.execute(sql: "insert into same_picture(item_id, lead) values ('file:1', 'file:1'), ('ig:1', 'file:1')")
        }
        let library = try Library(root: root)
        let map = try library.map()
        XCTAssertEqual(map.items.map(\.id).sorted(), ["file:1", "x:3"], "the post is drawn where the file is")
        let file = try XCTUnwrap(map.items.first { $0.id == "file:1" })
        XCTAssertEqual(file.also, ["instagram"])
        XCTAssertEqual(file.text, "Ferns after rain", "the caption it was posted with, not the file's name")
        XCTAssertEqual(file.resonance, 2.5 + 2.5 + 1, "made, posted and liked")
        XCTAssertEqual(map.waiting, 0, "the post isn't waiting for the map")

        var filter = MapFilter()
        filter.hiddenPlatforms = ["files"]
        XCTAssertTrue(filter.matches(file), "it shows while Instagram is on")
        filter.hiddenPlatforms = ["files", "instagram"]
        XCTAssertFalse(filter.matches(file))

        let detail = try library.detail(of: "file:1")
        XCTAssertEqual(detail.same.map(\.id), ["ig:1"])
        XCTAssertEqual(detail.same.first?.url, "https://www.instagram.com/p/A/")
        XCTAssertEqual(Set(detail.interactions.map { "\($0.type) \($0.source ?? "")" }), ["made files", "post instagram", "like instagram"])
    }

    /// Two arrangements of one item, with a region and a neighbor on each.
    private func placeOnTwoMaps() throws {
        try place("x:1", x: 10, y: 10)
        try place("x:2", x: 20, y: 20)
        try writer.write { db in
            try db.execute(sql: """
                insert into layout(item_id, model, x, y, cluster, neighbors) values
                  ('x:1', 'clip-vit-b-32+blended', 700, 800, 5, '["x:2"]');
                insert into cluster(model, id, label) values ('clip-vit-b-32', 0, 'by look'), ('clip-vit-b-32+blended', 5, 'by subject');
                update layout set neighbors = '["x:9"]' where model = 'clip-vit-b-32' and item_id = 'x:1';
                """)
        }
    }

    func testEachMapHasItsOwnPlacesRegionsAndNeighbors() throws {
        try placeOnTwoMaps()
        let library = try Library(root: root)
        let pictures = try library.map(.pictures)
        XCTAssertEqual(pictures.recipe, .pictures)
        XCTAssertEqual(pictures.items.count, 2)
        XCTAssertEqual(pictures.regions.regions[0]?.label, "by look")

        let blended = try library.map(.blended)
        XCTAssertEqual(blended.recipe, .blended)
        XCTAssertEqual(blended.items.map(\.x), [700])
        XCTAssertEqual(blended.regions.regions[5]?.label, "by subject")
        XCTAssertEqual(blended.waiting, 1, "the item only on the other map is still waiting on this one")

        XCTAssertEqual(try library.detail(of: "x:1", in: .blended).neighbors, ["x:2"])
        XCTAssertEqual(try library.detail(of: "x:1", in: .pictures).neighbors, ["x:9"])
    }

    func testAMapThatIsNotBuiltFallsBackToTheOneBuiltLast() throws {
        try placeOnTwoMaps()
        XCTAssertEqual(try Library(root: root).map().recipe, .pictures, "a library from before there was a choice")
        XCTAssertEqual(try Library(root: root).map(.words).recipe, .pictures)
        try writer.write { try $0.execute(sql: "insert into meta values ('map', 'blended')") }
        XCTAssertEqual(try Library(root: root).map().recipe, .blended)
        XCTAssertEqual(try Library(root: root).map(.words).recipe, .blended)
        XCTAssertEqual(try Library(root: root).map(.pictures).recipe, .pictures, "what you asked for wins")
    }

    func testSourcesSayWhichMapsAreBuiltAndWhatIsMissingFromEach() throws {
        try placeOnTwoMaps()
        let library = try Library(root: root)
        let onBlended = try library.sources(showing: .blended)
        XCTAssertEqual(onBlended.shownMap, .blended)
        XCTAssertEqual(onBlended.maps, [.pictures: 2, .blended: 1])
        XCTAssertEqual(onBlended.unplaced, 1)
        XCTAssertEqual(onBlended.waiting(on: .blended), 1)
        XCTAssertEqual(onBlended.waiting(on: .pictures), 0)
        XCTAssertEqual(try library.sources(showing: .pictures).unplaced, 0)
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

    /// What the file looks like once every Python tool has exited: no -wal, no -shm.
    func testOpensAfterTheLastWriterHasClosedAndStillCannotWrite() throws {
        try place("x:1")
        try writer.close()
        // Python's SQLite removes these on close. Apple's, used by this test, keeps them empty.
        let file = root.appending(path: "topograph.sqlite").path
        try? FileManager.default.removeItem(atPath: file + "-wal")
        try? FileManager.default.removeItem(atPath: file + "-shm")

        let library = try Library(root: root)
        XCTAssertEqual(try library.map().items.count, 1)
        XCTAssertThrowsError(try library.db.write { try $0.execute(sql: "delete from item") })
        XCTAssertThrowsError(try library.db.read { try $0.execute(sql: "delete from item") })
        XCTAssertThrowsError(try library.db.writeWithoutTransaction { try $0.execute(sql: "drop table item") })
        XCTAssertEqual(try library.map().items.count, 1)
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

    func testSourcesCountWhatsFetchedWaitingAndUnplaced() throws {
        try place("x:1", hydrated: 1, types: ["post"])
        try writer.write { db in
            try db.execute(sql: """
                insert into item(id, platform, hydrated, hydrate_attempts) values
                  ('x:waiting', 'x', 0, 0), ('x:gaveup', 'x', 0, 3), ('x:gone', 'x', -1, 3), ('ig:1', 'instagram', 1, 0);
                insert into item(id, platform, kind, text, hydrated) values
                  ('ig:2', 'instagram', 'text', 'a red chair', 1), ('ig:3', 'instagram', 'text', '👍 https://t.co/x', 1),
                  ('fb:trace:1', 'facebook', 'trace', 'You liked a photo', -1);
                insert into meta values ('files_roots', '["/a", "/b"]'), ('sync_bluesky', 'ann.test');
                """)
        }
        let sources = try Library(root: root).sources()
        let x = try XCTUnwrap(sources.platforms.first { $0.platform == "x" })
        XCTAssertEqual(x.items, 3, "gone items aren't counted")
        XCTAssertEqual(x.waiting, 1)
        XCTAssertEqual(x.fetched, 1)
        XCTAssertEqual(x.newest, 0)
        XCTAssertEqual(sources.fileRoots, ["/a", "/b"])
        XCTAssertEqual(sources.syncAccounts, ["bluesky": "ann.test"])
        XCTAssertEqual(sources.unplaced, 1, "only what updating the map would place: the one with words")
        XCTAssertEqual(sources.waiting(on: .blended), 2, "x:1 and ig:2 on a map that isn't built")
    }

    func testDroppedThingsAreClassified() throws {
        let zip = root.appending(path: "export.zip")
        try Data().write(to: zip)
        let note = root.appending(path: "note.txt")
        try Data().write(to: note)
        let export = root.appending(path: "export/data")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data().write(to: export.appending(path: "tweets.js"))
        let plain = root.appending(path: "pictures")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(DroppedSource.classify(zip), .export)
        XCTAssertEqual(DroppedSource.classify(note), .unknown)
        XCTAssertEqual(DroppedSource.classify(root.appending(path: "export")), .export)
        XCTAssertEqual(DroppedSource.classify(plain), .folder)
        XCTAssertEqual(DroppedSource.classify(root.appending(path: "nowhere")), .unknown)
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
