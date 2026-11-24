import CryptoKit
import Foundation

/// What the store knows about a feed from its last fetch.
public struct FetchRequest: Sendable, Equatable {
    public var url: URL
    public var etag: String?
    public var lastModified: String?
    /// Hash of the last body, for servers that ignore conditional requests.
    public var contentHash: String?

    public init(url: URL, etag: String? = nil, lastModified: String? = nil, contentHash: String? = nil) {
        self.url = url
        self.etag = etag
        self.lastModified = lastModified
        self.contentHash = contentHash
    }
}

public struct FetchResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// The server answered 304 Not Modified.
        case notModified
        /// The server sent the feed again but it is byte-for-byte the same.
        case unchanged
        case updated(ParsedFeed)
    }

    public var status: Status
    /// Where the feed should be fetched from next time, if it moved for good:
    /// a chain of permanent redirects, or a page that pointed to its feed.
    public var movedTo: URL?
    public var etag: String?
    public var lastModified: String?
    public var contentHash: String?

    public init(
        status: Status, movedTo: URL? = nil, etag: String? = nil,
        lastModified: String? = nil, contentHash: String? = nil
    ) {
        self.status = status
        self.movedTo = movedTo
        self.etag = etag
        self.lastModified = lastModified
        self.contentHash = contentHash
    }
}

public enum FetchError: Error, Equatable, Sendable {
    case http(status: Int)
    /// The URL serves a web page with no feed link in it.
    case notAFeed
    case parse(FeedParseError)
    case transport(String)
}

/// Fetches and parses one feed. An interface so a server-side aggregator can
/// replace direct fetching later without touching the refresh logic.
public protocol FeedFetching: Sendable {
    func fetch(_ request: FetchRequest) async throws(FetchError) -> FetchResult
}

/// Fetches feeds directly from their servers.
public struct HTTPFeedFetcher: FeedFetching {
    public static let userAgent = "Srssly/0.1 (+https://github.com/hatstand/srssly)"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ request: FetchRequest) async throws(FetchError) -> FetchResult {
        let first = try await get(request.url, etag: request.etag, lastModified: request.lastModified)
        if first.status == 304 {
            return FetchResult(
                status: .notModified, movedTo: first.permanentTarget,
                etag: first.etag ?? request.etag, lastModified: first.lastModified ?? request.lastModified,
                contentHash: request.contentHash
            )
        }
        guard (200..<300).contains(first.status) else { throw .http(status: first.status) }

        var response = first
        var movedTo = first.permanentTarget
        if FeedDiscovery.looksLikeHTML(first.body) {
            // An old feed URL that now serves the site. Follow its feed link
            // once, and remember the new URL.
            let html = String(decoding: first.body, as: UTF8.self)
            guard let feedURL = FeedDiscovery.feedLinks(inHTML: html, baseURL: first.finalURL).first else {
                throw .notAFeed
            }
            response = try await get(feedURL, etag: nil, lastModified: nil)
            guard (200..<300).contains(response.status) else { throw .http(status: response.status) }
            movedTo = response.permanentTarget ?? feedURL
        }

        let hash = Self.hash(response.body)
        if hash == request.contentHash {
            return FetchResult(
                status: .unchanged, movedTo: movedTo,
                etag: response.etag, lastModified: response.lastModified, contentHash: hash
            )
        }
        let feed: ParsedFeed
        do {
            feed = try FeedParser.parse(response.body, url: response.finalURL)
        } catch {
            throw .parse(error)
        }
        return FetchResult(
            status: .updated(feed), movedTo: movedTo,
            etag: response.etag, lastModified: response.lastModified, contentHash: hash
        )
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Response {
        var status: Int
        var body: Data
        var finalURL: URL
        var permanentTarget: URL?
        var etag: String?
        var lastModified: String?
    }

    private func get(_ url: URL, etag: String?, lastModified: String?) async throws(FetchError) -> Response {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "application/rss+xml, application/atom+xml, application/rdf+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        // We do our own conditional requests; don't let URLCache answer for the server.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let redirects = RedirectRecorder()
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request, delegate: redirects)
        } catch {
            throw .transport((error as NSError).localizedDescription)
        }
        guard let http = urlResponse as? HTTPURLResponse else { throw .transport("Not an HTTP response") }
        return Response(
            status: http.statusCode,
            body: data,
            finalURL: http.url ?? url,
            permanentTarget: redirects.permanentTarget,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}

/// Records redirects so a feed that moved permanently can be updated.
///
/// Only a chain made entirely of permanent redirects (301, 308) counts: a
/// temporary hop anywhere means the original URL should be kept. FeedBurner,
/// for example, uses 302s.
private final class RedirectRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var allPermanent = true
    private var target: URL?

    var permanentTarget: URL? {
        lock.withLock { allPermanent ? target : nil }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        lock.withLock {
            if response.statusCode == 301 || response.statusCode == 308 {
                target = request.url
            } else {
                allPermanent = false
            }
        }
        return request
    }
}
