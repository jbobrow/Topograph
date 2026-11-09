import XCTest
@testable import TopographCore

final class CloudsTests: XCTestCase {
    private let day = 86_400
    private let start = 1_600_000_000

    private func cell(_ x: Double, _ y: Double) -> Int {
        let n = DensityField.side
        let column = Int((x + DensityField.origin) / DensityField.cellSize), row = Int((y + DensityField.origin) / DensityField.cellSize)
        return column + row * n
    }

    /// Forty searches near one place over a month.
    private func burst(at x: Float, _ y: Float, from time: Int) -> [Clouds.Search] {
        (0..<40).map { Clouds.Search(x: x + Float($0 % 5) * 4, y: y + Float($0 / 5) * 4, time: time + $0 * 18_000, text: "q\($0)") }
    }

    func testWeatherIsWhereThisSeasonsSearchesGatherMoreThanUsual() throws {
        let clouds = Clouds(searches: burst(at: 800, 800, from: start + 400 * day) + burst(at: 200, 200, from: start))
        XCTAssertEqual(clouds.searches.first?.time, start, "kept in time order")

        let first = try XCTUnwrap(clouds.weather(endingAt: start + 40 * day))
        XCTAssertGreaterThanOrEqual(first[cell(210, 210)], 1, "a cloud over where that season's searches were")
        XCTAssertLessThan(first[cell(810, 810)], 1, "clear sky where they hadn't happened yet")

        let later = try XCTUnwrap(clouds.weather(endingAt: start + 440 * day))
        XCTAssertGreaterThanOrEqual(later[cell(810, 810)], 1, "the weather moves")
        XCTAssertLessThan(later[cell(210, 210)], 1)
    }

    func testAQuietSeasonHasNoWeather() {
        let clouds = Clouds(searches: burst(at: 200, 200, from: start))
        XCTAssertNil(clouds.weather(endingAt: start + 300 * day), "no searches in the season")
        XCTAssertNil(Clouds().weather(endingAt: start))
    }
}

final class CloudTests: XCTestCase {
    private let day = 86_400
    private let start = 1_600_000_000

    private func burst(at x: Float, _ y: Float, from time: Int, label: String) -> [Clouds.Search] {
        (0..<40).map { Clouds.Search(x: x + Float($0 % 5) * 4, y: y + Float($0 / 5) * 4, time: time + $0 * 18_000, text: "\(label) \($0)") }
    }

    func testACloudHoldsItsSeasonsSearchesUnderIt() throws {
        let clouds = Clouds(searches: burst(at: 200, 200, from: start, label: "kites")
            + burst(at: 800, 800, from: start + 10 * day, label: "inks")
            + burst(at: 500, 200, from: start + 400 * day, label: "later"))
        let end = start + 40 * day
        let weather = try XCTUnwrap(clouds.weather(endingAt: end))

        let cloud = try XCTUnwrap(clouds.cloud(at: 210, 210, weather: weather, endingAt: end))
        XCTAssertEqual(cloud.searches.count, 40, "only this season's, and only this cloud's")
        XCTAssertTrue(cloud.searches.allSatisfy { $0.text.hasPrefix("kites") })
        XCTAssertEqual(cloud.searches.first?.text, "kites 39", "newest first")
        XCTAssertEqual(cloud.season.upperBound, end)

        XCTAssertEqual(clouds.cloud(at: 810, 810, weather: weather, endingAt: end)?.searches.first?.text, "inks 39")
        XCTAssertNil(clouds.cloud(at: 500, 500, weather: weather, endingAt: end), "clear sky between them")
        XCTAssertTrue(Clouds.isCloudy(weather, at: 210, 210))
        XCTAssertFalse(Clouds.isCloudy(weather, at: 500, 500))
    }
}

final class CloudThemesTests: XCTestCase {
    /// Two subjects, each searched in its own words, on vectors that tell them apart.
    func testThemesGroupByMeaningAndAreNamedByTheirWords() {
        let subjects = [("eurorack", ["case", "power", "rails", "skiff", "depth", "modules", "price", "busboard", "used", "diy"]),
                        ("risograph", ["inks", "drum", "paper", "colors", "studio", "masters", "pink", "registration", "service", "zine"])]
        var searches: [Clouds.Search] = []
        var vectors: [String: [Float]] = [:]
        for (s, (subject, words)) in subjects.enumerated() {
            for (w, word) in words.enumerated() {
                let id = "google:\(subject)-\(word)"
                searches.append(Clouds.Search(x: 0, y: 0, time: 1_000 + w, text: "\(subject) \(word)", id: id))
                var v = [Float](repeating: 0, count: 8)
                v[s] = 1
                v[2 + w % 6] = 0.3
                vectors[id] = v
            }
        }
        searches.append(Clouds.Search(x: 0, y: 0, time: 5_000, text: "eurorack case", id: "google:again"))
        vectors["google:again"] = vectors["google:eurorack-case"]

        let (themes, rest) = CloudThemes.find(searches, vectors: vectors)
        XCTAssertEqual(Set(themes.map(\.name)), ["eurorack", "risograph"])
        XCTAssertEqual(themes.first?.name, "eurorack", "the bigger one first: it was searched once more")
        XCTAssertEqual(themes.first?.searches.count, 11)
        XCTAssertTrue(rest.isEmpty)
    }

    func testAFewSearchesAreJustAList() {
        let searches = (0..<5).map { Clouds.Search(x: 0, y: 0, time: $0, text: "q\($0)", id: "\($0)") }
        let (themes, rest) = CloudThemes.find(searches, vectors: Dictionary(uniqueKeysWithValues: searches.map { ($0.id, [Float](repeating: 1, count: 4)) }))
        XCTAssertTrue(themes.isEmpty)
        XCTAssertEqual(rest.count, 5)
    }
}
