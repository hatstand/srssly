import Foundation

/// Serves canned HTTP responses to a URLSession, keyed by URL.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Called with each request so tests can assert on headers.
        var check: (@Sendable (URLRequest) -> Void)? = nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [URL: Stub] = [:]
    nonisolated(unsafe) private static var hits: [URL: Int] = [:]

    static func set(_ url: String, _ stub: Stub) {
        lock.withLock { stubs[URL(string: url)!] = stub }
    }

    static func hitCount(_ url: String) -> Int {
        lock.withLock { hits[URL(string: url)!] ?? 0 }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let stub = Self.lock.withLock { () -> Stub? in
            Self.hits[url, default: 0] += 1
            return Self.stubs[url]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        stub.check?(request)
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        if (300..<400).contains(stub.status), stub.status != 304, let location = stub.headers["Location"] {
            var next = URLRequest(url: URL(string: location, relativeTo: url)!.absoluteURL)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            // URLSession stops this protocol and starts a new one for `next`.
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
