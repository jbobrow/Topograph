import Foundation
import Testing
@testable import TopographCore

// Numbers from the Python pipeline: open_clip's tokenizer and preprocessing on made-up text and
// generated pictures. Regenerate them if the recipe ever changes.

@Suite struct CLIPTokenizerTests {
    static let golden: [(String, [Int32])] = [
        ("dice", [49406, 14406, 49407]),
        ("a photo of kinetic sculpture in a gallery", [49406, 320, 1125, 539, 37699, 8757, 530, 320, 3830, 49407]),
        ("", [49406, 49407]),
        ("   ", [49406, 49407]),
        ("Hello, World!!", [49406, 3306, 267, 1002, 748, 49407]),
        ("I'm sure they've said we'll go; it's John's.", [49406, 328, 880, 1650, 889, 1200, 1946, 649, 1342, 861, 282, 585, 568, 1742, 568, 269, 49407]),
        ("'sam 'tis 're've", [49406, 568, 687, 713, 533, 982, 1200, 49407]),
        ("<start_of_text>hello<end_of_text>", [49406, 49406, 3306, 49407, 49407]),
        ("x<y &amp; y&gt;z", [49406, 343, 283, 344, 261, 344, 285, 345, 49407]),
        ("AT&amp;amp;T &copy 2024 &#169; &#x2014; &notanentity; &para=3", [49406, 536, 261, 339, 5811, 273, 271, 273, 275, 5811, 2005, 126, 361, 514, 28455, 282, 126, 114, 284, 274, 49407]),
        ("“curly” ‘quotes’ and ʼapostrophe", [49406, 257, 20795, 257, 262, 5808, 262, 537, 262, 4089, 3121, 19853, 49407]),
        ("ﬁne ﬂour ﬀ ĳ", [49406, 3797, 18592, 1304, 72, 329, 49407]),
        ("ＦＵＬＬ\u{3000}ｗｉｄｔｈ！", [49406, 1476, 23571, 256, 49407]),
        ("Déjà vu naïve café é", [49406, 25466, 73, 21259, 13230, 1097, 35689, 563, 15304, 4166, 49407]),
        ("tokyo 東京 2024 ４２", [49406, 6667, 48338, 21078, 361, 273, 271, 273, 275, 275, 273, 49407]),
        ("emoji 🎲🎲 👩🏽\u{200D}💻 ok", [49406, 16327, 1165, 110, 1165, 366, 18800, 8514, 4244, 18135, 2481, 49407]),
        ("Ελληνικά ΣΑΣ", [49406, 138, 113, 138, 119, 138, 119, 138, 115, 138, 121, 138, 117, 138, 118, 138, 361, 139, 225, 138, 109, 139, 480, 49407]),
        ("İstanbul ß ǅ", [49406, 328, 16384, 11231, 127, 509, 67, 129, 378, 49407]),
        ("tabs\u{9}and\u{A}new\u{D}\u{A}lines\u{2028}here\u{A0}nbsp\u{3000}end", [49406, 29163, 537, 686, 3418, 763, 6459, 4393, 806, 49407]),
        ("ctrl\u{1}\u{7}chars\u{FEFF}\u{200B}zero\u{206A}", [49406, 35602, 75, 540, 864, 9844, 5848, 49407]),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", [49406, 23126, 23126, 23126, 23126, 23126, 23126, 23126, 23126, 23126, 6727, 19336, 49407]),
        ("word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word ", [49406, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 2653, 49407]),
        ("https://example.com/a?b=c&d=e#f", [49406, 30901, 12441, 6228, 269, 2464, 270, 320, 286, 321, 284, 322, 261, 323, 284, 324, 258, 325, 49407]),
        ("#topography @maker_01 100% (of) [it]", [49406, 258, 23008, 4897, 287, 4836, 318, 271, 272, 272, 271, 271, 260, 263, 539, 264, 314, 585, 316, 49407]),
        ("ゴジラ한글العربية", [49406, 3909, 112, 32234, 23007, 15197, 250, 32495, 222, 12973, 18843, 10948, 16378, 12046, 20915, 49407]),
        ("\u{1B}[31mred\u{1B}[0m", [49406, 736, 49407]),
        ("\u{93}cp1252\u{94} \u{85} end", [49406, 257, 9130, 272, 273, 276, 273, 257, 959, 806, 49407]),
        ("1,000.5 3rd", [49406, 272, 267, 271, 271, 271, 269, 276, 274, 1973, 49407]),
        ("don't DON'T", [49406, 847, 713, 847, 713, 49407]),
    ]

    @Test func matchesOpenCLIP() throws {
        let tokenizer = try CLIPTokenizer()
        for (text, expected) in Self.golden {
            let tokens = tokenizer.tokens(text)
            #expect(tokens.count == CLIPTokenizer.contextLength)
            #expect(tokens.filter { $0 != 0 } == expected, "\(text)")
        }
    }
}

@Suite struct CLIPImageTests {
    private static func pattern(_ width: Int, _ height: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                out.append(UInt8((x * 7 + y * 3) % 256))
                out.append(UInt8((x * x / 5 + y) % 256))
                out.append(UInt8(((x ^ y) * 11) % 256))
            }
        }
        return out
    }

    static let golden: [(width: Int, height: Int, sum: Double, first: [Float], middle: [Float], last: [Float])] = [
        (400, 300, 28176.55740545923, [-0.42001041769981384, 1.699689507484436, -0.9398571848869324], [-0.9747506976127625, 0.8592545986175537, 0.2546282708644867], [-1.7630656957626343, 0.22892838716506958, -1.238478660583496]),
        (300, 401, 28121.18778492883, [0.45589518547058105, -0.9867009520530701, -0.7549964189529419], [-0.09884507209062576, -0.38639017939567566, 1.150492548942566], [-0.755774199962616, -0.3263591229915619, 0.1693078875541687]),
        (50, 80, 13959.31208952202, [-1.1645302772521973, -1.5269806385040283, 0.8092109560966492], [1.2004148960113525, -0.7015532851219177, 0.9229714870452881], [-1.4273018836975098, -1.241832971572876, 1.619754672050476]),
        (224, 224, 27932.018825160805, [-1.7922625541687012, -1.7520971298217773, -1.480219841003418], [1.463186502456665, 1.9848371744155884, -0.982517421245575], [0.864651083946228, 1.009332299232483, -1.480219841003418]),
        (225, 223, 27959.044728064793, [-1.6900734901428223, -1.7520971298217773, -1.3237991333007812], [1.5069818496704102, -0.806607723236084, 0.041327301412820816], [0.8208557963371277, 0.9943245053291321, -1.3095790147781372]),
    ]

    @Test func matchesPillowAndTorchvision() {
        for golden in Self.golden {
            let pixels = CLIPImage.pixels(rgb: Self.pattern(golden.width, golden.height), width: golden.width, height: golden.height)
            let size = CLIPImage.size
            #expect(pixels.count == 3 * size * size)
            func at(_ channel: Int, _ y: Int, _ x: Int) -> Float { pixels[(channel * size + y) * size + x] }
            for channel in 0..<3 {
                #expect(abs(at(channel, 0, 0) - golden.first[channel]) < 1e-5, "\(golden.width)×\(golden.height)")
                #expect(abs(at(channel, 112, 57) - golden.middle[channel]) < 1e-5, "\(golden.width)×\(golden.height)")
                #expect(abs(at(channel, 223, 223) - golden.last[channel]) < 1e-5, "\(golden.width)×\(golden.height)")
            }
            let sum = pixels.reduce(0.0) { $0 + Double($1) }
            #expect(abs(sum - golden.sum) < 0.01, "\(golden.width)×\(golden.height): \(sum) vs \(golden.sum)")
        }
    }
}

@Suite struct NearestTests {
    private func item(_ id: Int, picture: Bool) -> MapItem {
        var item = MapItem(x: 0, y: 0, resonance: 1, mine: false)
        item.platform = "files"
        item.thumb = picture ? "t\(id).webp" : nil
        return item
    }

    @Test func picturesAreNotCrowdedOutByText() {
        // Text scores far higher than pictures, yet the best picture still comes first
        // among its own kind, and leads overall for standing out further from the rest.
        let vectors: [[Float]] = [
            [0.9, 0.1], [0.8, 0.2], [0.85, 0.15], [0.82, 0.18],     // text
            [0.5, 0.5], [0.1, 0.9], [0.1, 0.91], [0.1, 0.89],       // pictures
        ]
        let items = (0..<8).map { item($0, picture: $0 >= 4) }
        let store = EmbeddingStore(dimensions: 2, vectors: vectors.flatMap { $0 },
                                   rowOfItem: Dictionary(uniqueKeysWithValues: (0..<8).map { (Int32($0), $0) }))
        let ranked = store.nearest(to: [1, 0], items: items, count: 8)
        #expect(ranked.first == 4)
        #expect(ranked.count == 8)
    }

    @Test func anItemCloseToEverythingDoesNotLead() {
        // Item 0 sits on the average phrase; item 1 fits the query itself.
        let vectors: [[Float]] = [[0.7, 0.7], [1, 0], [0, 1], [0.1, 0.99]]
        let items = (0..<4).map { item($0, picture: true) }
        let rows = Dictionary(uniqueKeysWithValues: (0..<4).map { (Int32($0), $0) })
        let plain = EmbeddingStore(dimensions: 2, vectors: vectors.flatMap { $0 }, rowOfItem: rows)
        let corrected = EmbeddingStore(dimensions: 2, vectors: vectors.flatMap { $0 }, rowOfItem: rows, everyday: [0.7, 0.7])
        let query: [Float] = [0.8, 0.6]
        #expect(plain.nearest(to: query, items: items, count: 1) == [0])
        #expect(corrected.nearest(to: query, items: items, count: 1) == [1])
    }

    @Test func filtersApplyToTheRankingAndKeepItsOrder() {
        var filter = MapFilter()
        filter.nearest = [2, 0, 1]
        filter.hiddenPlatforms = ["x"]
        var items = (0..<3).map { item($0, picture: true) }
        items[0].platform = "x"
        #expect(filter.visible(in: items, search: SearchIndex(items: items)) == [2, 1])
    }
}

@Suite(.enabled(if: CLIPEncoder.isInstalled())) struct CLIPEncoderTests {
    @Test func textVectorMatchesPython() throws {
        let vector = try CLIPEncoder(computeUnits: .cpuOnly).embed(text: "a photo of a topographic map")
        let python: [Float] = [0.00844, -0.00587, -0.00576, -0.00584, -0.00357, -0.02772, 0.01203, 0.03022]
        for index in python.indices { #expect(abs(vector[index] - python[index]) < 0.0001) }
    }
}
