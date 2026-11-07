import Foundation

/// What went wrong asking for something. A site answering with an error said something about
/// the post; no answer at all says only that the network is down.
public struct FetchFailure: Error, LocalizedError {
    public let url: String
    public let status: Int?
    public let message: String

    /// No answer came back.
    public var isNetwork: Bool { status == nil }
    public var errorDescription: String? { message }
}

/// One request at a time, with no cookies and no cache, so nothing about you goes along.
public struct WebFetcher: Sendable {
    public var fetch: @Sendable (_ url: String, _ accept: String, _ timeout: TimeInterval) throws -> Data

    public init(fetch: @escaping @Sendable (_ url: String, _ accept: String, _ timeout: TimeInterval) throws -> Data) {
        self.fetch = fetch
    }

    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private final class Outcome: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }

    public static let standard = WebFetcher { url, accept, timeout in
        guard let address = URL(string: url) else {
            throw FetchFailure(url: url, status: 0, message: "\(url): not a web address")
        }
        var request = URLRequest(url: address, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        let task = session.dataTask(with: request) { data, response, error in
            outcome.data = data
            outcome.status = (response as? HTTPURLResponse)?.statusCode
            outcome.error = error
            done.signal()
        }
        task.resume()
        done.wait()
        if let error = outcome.error {
            throw FetchFailure(url: url, status: nil, message: "\(address.host ?? url): \(error.localizedDescription)")
        }
        if let status = outcome.status, status >= 400 {
            throw FetchFailure(url: url, status: status, message: "\(address.host ?? url): status \(status)")
        }
        return outcome.data ?? Data()
    }
}

extension PipelineReporter {
    /// Wait out the human pace, but stop waiting when asked to stop.
    func pause(_ seconds: TimeInterval, wait: @Sendable (TimeInterval) -> Void) throws {
        var left = seconds
        while left > 0 {
            if isCancelled() { throw PipelinePaused() }
            wait(min(left, 0.1))
            left -= 0.1
        }
        if isCancelled() { throw PipelinePaused() }
    }
}
