import Foundation

/// Optional naming through Claude. Off by default, and only ever runs when you press the
/// key, with your own API key. It sends a region's thumbnails and captions, and nothing
/// else leaves this Mac.
public struct RegionNamer: Sendable {
    public struct Sample: Sendable {
        public let thumbnail: URL?
        public let caption: String?

        public init(thumbnail: URL?, caption: String?) {
            self.thumbnail = thumbnail
            self.caption = caption
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case badKey
        case declined
        case service(status: Int, message: String)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .badKey: "That API key wasn’t accepted."
            case .declined: "Claude declined to name this region."
            case .service(let status, let message): "The naming service said \(status): \(message)"
            case .unreadable: "The reply couldn’t be read."
            }
        }
    }

    /// Said in the app before you turn this on.
    public static let disclosure = "Sends up to \(sampleLimit) thumbnails and captions from the region you’re naming to Anthropic’s API, using your own key, only when you press the key. Nothing else leaves this Mac."
    public static let sampleLimit = 8
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let key: String
    private let session: URLSession

    public init(key: String, session: URLSession = .shared) {
        self.key = key
        self.session = session
    }

    func request(samples: [Sample], siblings: [String]) throws -> URLRequest {
        var content: [[String: Any]] = []
        var captions: [String] = []
        for sample in samples.prefix(Self.sampleLimit) {
            if let thumbnail = sample.thumbnail, let data = try? Data(contentsOf: thumbnail) {
                content.append(["type": "image", "source": [
                    "type": "base64", "media_type": "image/webp", "data": data.base64EncodedString(),
                ]])
            }
            if let caption = sample.caption, !caption.isEmpty { captions.append(String(caption.prefix(300))) }
        }
        var prompt = """
            These come from one region of someone's private map of their own taste. Name the region in \
            2 to 4 lowercase words, the way a place is named on a map: specific to what these share, \
            with no generic words like "collection" or "various". Reply with the name only.
            """
        if !captions.isEmpty { prompt += "\n\nCaptions:\n" + captions.map { "- \($0)" }.joined(separator: "\n") }
        if !siblings.isEmpty { prompt += "\n\nThe regions beside it are called: \(siblings.joined(separator: ", ")). Tell this one apart from those." }
        content.append(["type": "text", "text": prompt])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-5-5",
            "max_tokens": 4000,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": [["role": "user", "content": content]],
        ] as [String: Any])
        return request
    }

    public func suggest(samples: [Sample], siblings: [String]) async throws -> String {
        let (data, response) = try await session.data(for: request(samples: samples, siblings: siblings))
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.badKey }
        guard status == 200, let body else {
            let message = (body?["error"] as? [String: Any])?["message"] as? String
            throw Failure.service(status: status, message: message ?? "no details")
        }
        if body["stop_reason"] as? String == "refusal" { throw Failure.declined }
        let blocks = body["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else { throw Failure.unreadable }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.")))
        guard !name.isEmpty else { throw Failure.unreadable }
        return name.lowercased()
    }
}

extension RegionTree {
    /// The same tree with some regions called something else.
    public func renamed(_ names: [Int: String]) -> RegionTree {
        RegionTree(regions: regions.mapValues { region in
            names[region.id].map { region.withLabel($0) } ?? region
        }, roots: roots, base: self)
    }
}
