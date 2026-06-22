import Foundation

/// A `URLProtocol` that answers requests from a per-test closure instead of the network, so the
/// `GitHubAPIClient` tests drive real decoding/pagination/error-mapping against canned HTTP
/// responses. Install it on an ephemeral `URLSessionConfiguration` and set `handler` per test.
final class StubURLProtocol: URLProtocol {
    /// Maps a request to the `(response, body)` it should receive, or throws to simulate a
    /// transport failure. Set before each call; read on URLSession's loading thread.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
