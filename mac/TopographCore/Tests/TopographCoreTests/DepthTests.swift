import XCTest
@testable import TopographCore

final class DepthTests: XCTestCase {
    private let month = 30 * 86400
    private let start = 1_500_000_000

    private func item(_ region: Int = 1, monthsIn: Int, mine: Bool = false, phash: UInt64? = nil) -> MapItem {
        MapItem(x: 1, y: 1, resonance: 1, mine: mine, region: region, time: start + monthsIn * month, phash: phash)
    }

    private func map(_ items: [MapItem]) -> LibraryMap {
        LibraryMap(items: items, regions: RegionTree(records: [.init(id: 1, label: "a", x: 1, y: 1, r: 4), .init(id: 2, label: "b", x: 2, y: 2, r: 4)], items: items))
    }

    func testEchoNeedsActivitySilenceAndActivity() throws {
        var items: [MapItem] = []
        for m in 0..<3 { items += Array(repeating: item(monthsIn: m), count: 4) }
        for m in 18..<21 { items += Array(repeating: item(monthsIn: m), count: 4) }
        let map = map(items)
        let axis = try XCTUnwrap(MonthAxis(times: items.compactMap(\.time)))
        let echoes = Echoes.find(map: map, visible: Array(items.indices.map(Int32.init)), axis: axis)
        let echo = try XCTUnwrap(echoes.first)
        XCTAssertEqual(echo.region, 1)
        XCTAssertGreaterThanOrEqual(echo.silentMonths, 14)
        XCTAssertEqual(echo.thenItems.count, 10)
        XCTAssertTrue(echo.thenItems.allSatisfy { items[Int($0)].time! < items[Int(echo.nowItems[0])].time! })
    }

    func testSteadyInterestIsNoEcho() throws {
        let items = (0..<30).flatMap { m in Array(repeating: item(monthsIn: m), count: 4) }
        let axis = try XCTUnwrap(MonthAxis(times: items.compactMap(\.time)))
        XCTAssertTrue(Echoes.find(map: map(items), visible: Array(items.indices.map(Int32.init)), axis: axis).isEmpty)
    }

    func testAShortGapOrAFewItemsIsNoEcho() throws {
        let shortGap = Array(repeating: item(monthsIn: 0), count: 8) + Array(repeating: item(monthsIn: 6), count: 8)
        let axis1 = try XCTUnwrap(MonthAxis(times: shortGap.compactMap(\.time)))
        XCTAssertTrue(Echoes.find(map: map(shortGap), visible: Array(shortGap.indices.map(Int32.init)), axis: axis1).isEmpty)

        let few = Array(repeating: item(monthsIn: 0), count: 2) + Array(repeating: item(monthsIn: 24), count: 8)
        let axis2 = try XCTUnwrap(MonthAxis(times: few.compactMap(\.time)))
        XCTAssertTrue(Echoes.find(map: map(few), visible: Array(few.indices.map(Int32.init)), axis: axis2).isEmpty)
    }

    func testPaletteHueGoesAroundAndLightGoesInward() {
        let red = PaletteLayout.position(rgb: 0xff0000), green = PaletteLayout.position(rgb: 0x00ff00)
        XCTAssertNotEqual(atan2(red.y, red.x), atan2(green.y, green.x), accuracy: 0.5)
        let dark = PaletteLayout.position(rgb: 0x800000), light = PaletteLayout.position(rgb: 0xff8080)
        XCTAssertGreaterThan(hypot(dark.x, dark.y), hypot(light.x, light.y))
        let white = PaletteLayout.position(rgb: 0xffffff)
        XCTAssertEqual(hypot(white.x, white.y), 0, accuracy: 1e-6)
    }

    func testTributariesAreNearestKeptItemsBeforeTheWork() {
        let items = [
            item(monthsIn: 12, mine: true),   // the work
            item(monthsIn: 10),               // close, in the window
            item(monthsIn: 11),               // less close
            item(monthsIn: 2),                // close, but too long before
            item(monthsIn: 13),               // close, but after
            item(monthsIn: 11, mine: true),   // close, but your own
        ]
        let vectors: [[Float]] = [[1, 0], [1, 0], [0.6, 0.8], [1, 0], [1, 0], [1, 0]]
        let store = EmbeddingStore(dimensions: 2, vectors: vectors.flatMap { $0 },
                                   rowOfItem: Dictionary(uniqueKeysWithValues: items.indices.map { (Int32($0), $0) }))
        XCTAssertEqual(store.similarity(0, 2) ?? 0, 0.6, accuracy: 1e-5)
        XCTAssertEqual(Tributaries.find(of: 0, map: map(items), embeddings: store), [1, 2])
    }

    func testProcessGroupsNearDuplicatesCloseInTime() {
        let items = [
            item(monthsIn: 0, mine: true, phash: 0xFF00),
            item(monthsIn: 0, mine: true, phash: 0xFF01),
            item(monthsIn: 0, mine: true, phash: 0xFF03),
            item(monthsIn: 0, mine: true, phash: 0xFFFF_FFFF_0000_0000),   // looks different
            item(monthsIn: 40, mine: true, phash: 0xFF00),                 // same look, years later
            item(monthsIn: 0, mine: false, phash: 0xFF00),                 // not yours
        ]
        XCTAssertEqual(ProcessSequences.find(items: items).map { $0.sorted() }, [[0, 1, 2]])
    }
}

final class MoodboardTests: XCTestCase {
    func testPicksAreTheMostResonantPicturesInside() {
        let items = [
            MapItem(id: "a", x: 1, y: 1, resonance: 1, region: 1, thumb: "a"),
            MapItem(id: "b", x: 1, y: 1, resonance: 5, region: 1, thumb: "b"),
            MapItem(id: "c", x: 1, y: 1, resonance: 9, region: 1),              // no picture
            MapItem(id: "d", x: 1, y: 1, resonance: 9, region: 2, thumb: "d"),  // elsewhere
        ]
        let tree = RegionTree(records: [.init(id: 1, label: "a", x: 1, y: 1, r: 4), .init(id: 2, label: "b", x: 1, y: 1, r: 4)], items: items)
        XCTAssertEqual(Moodboard.picks(region: 1, map: LibraryMap(items: items, regions: tree)), [1, 0])
    }

    func testRenderMakesAPNGEvenWhenAPictureIsMissing() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/picture.webp")
        let data = try XCTUnwrap(Moodboard.render(title: "a region", files: [missing], columns: 2, cell: 40, gap: 4, margin: 8))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}


final class RegionNamerTests: XCTestCase {
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body: [String: Any] = [:]
        nonisolated(unsafe) static var seen: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            Stub.seen = request
            let response = HTTPURLResponse(url: request.url!, statusCode: Stub.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: Stub.body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func namer() -> RegionNamer {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return RegionNamer(key: "test-key", session: URLSession(configuration: config))
    }

    func testAsksWithYourKeySendsOnlyTheSampleAndReadsTheName() async throws {
        Stub.status = 200
        Stub.body = ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": " \"Folded Paper Forms\".\n"]]]
        let picture = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).webp")
        try Data([1, 2, 3]).write(to: picture)
        defer { try? FileManager.default.removeItem(at: picture) }
        let samples = (0..<12).map { RegionNamer.Sample(thumbnail: picture, caption: "caption \($0)") }
        let name = try await namer().suggest(samples: samples, siblings: ["soldering"])
        XCTAssertEqual(name, "folded paper forms")

        let request = try namer().request(samples: samples, siblings: ["soldering"])
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        XCTAssertEqual(content.filter { $0["type"] as? String == "image" }.count, RegionNamer.sampleLimit, "no more pictures than it says")
        let text = try XCTUnwrap(content.last?["text"] as? String)
        XCTAssertTrue(text.contains("caption 7") && !text.contains("caption 8"), "no more captions than it says")
        XCTAssertTrue(text.contains("soldering"))
    }

    func testFailuresSayWhatHappened() async {
        func failure(status: Int, body: [String: Any]) async -> RegionNamer.Failure? {
            Stub.status = status
            Stub.body = body
            do {
                _ = try await namer().suggest(samples: [], siblings: [])
                return nil
            } catch { return error as? RegionNamer.Failure }
        }
        let badKey = await failure(status: 401, body: [:])
        XCTAssertEqual(badKey, .badKey)
        let declined = await failure(status: 200, body: ["stop_reason": "refusal", "content": []])
        XCTAssertEqual(declined, .declined)
        let busy = await failure(status: 529, body: ["error": ["message": "overloaded"]])
        XCTAssertEqual(busy, .service(status: 529, message: "overloaded"))
        let empty = await failure(status: 200, body: ["stop_reason": "end_turn", "content": [["type": "text", "text": "  "]]])
        XCTAssertEqual(empty, .unreadable)
    }

    func testRenamingKeepsEverythingElse() {
        let items = [MapItem(x: 1, y: 1, resonance: 1, region: 1)]
        let tree = RegionTree(records: [.init(id: 1, label: "old", x: 1, y: 1, r: 4)], items: items)
        let renamed = tree.renamed([1: "new"])
        XCTAssertEqual(renamed.regions[1]?.label, "new")
        XCTAssertEqual(renamed.regions[1]?.count, 1)
        XCTAssertEqual(renamed.members(of: 1), [0])
    }
}
