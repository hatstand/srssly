import Foundation
import Testing
@testable import SrsslyCore

private let rss = Data("""
<rss version="2.0"><channel><title>Feed</title>
<item><title>One</title><guid>1</guid></item>
</channel></rss>
""".utf8)

// Each test uses its own host, so they can run in parallel.
@Suite struct FeedFetcherTests {
    let fetcher = HTTPFeedFetcher(session: StubURLProtocol.session())

    @Test func parsesAndReturnsValidators() async throws {
        StubURLProtocol.set("https://a.test/feed", .init(
            status: 200, headers: ["ETag": "\"v1\"", "Last-Modified": "Mon, 23 Nov 2026 05:00:00 GMT"], body: rss,
            check: { req in
                #expect(req.value(forHTTPHeaderField: "User-Agent") == HTTPFeedFetcher.userAgent)
                #expect(req.value(forHTTPHeaderField: "If-None-Match") == nil)
            }
        ))
        let result = try await fetcher.fetch(FetchRequest(url: URL(string: "https://a.test/feed")!))
        guard case .updated(let feed) = result.status else { Issue.record("expected update"); return }
        #expect(feed.items.map(\.title) == ["One"])
        #expect(result.etag == "\"v1\"")
        #expect(result.lastModified == "Mon, 23 Nov 2026 05:00:00 GMT")
        #expect(result.contentHash == HTTPFeedFetcher.hash(rss))
        #expect(result.movedTo == nil)
    }

    @Test func sendsValidatorsAndHandles304() async throws {
        StubURLProtocol.set("https://b.test/feed", .init(status: 304, check: { req in
            #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
            #expect(req.value(forHTTPHeaderField: "If-Modified-Since") == "Mon, 23 Nov 2026 05:00:00 GMT")
        }))
        let result = try await fetcher.fetch(FetchRequest(
            url: URL(string: "https://b.test/feed")!, etag: "\"v1\"",
            lastModified: "Mon, 23 Nov 2026 05:00:00 GMT", contentHash: "abc"
        ))
        #expect(result.status == .notModified)
        #expect(result.etag == "\"v1\"")
        #expect(result.contentHash == "abc")
    }

    @Test func sameBodyIsUnchangedWhenServerIgnoresValidators() async throws {
        // FeedBurner ignores conditional GET; fall back to the body hash.
        StubURLProtocol.set("https://c.test/feed", .init(status: 200, body: rss))
        let result = try await fetcher.fetch(FetchRequest(
            url: URL(string: "https://c.test/feed")!, contentHash: HTTPFeedFetcher.hash(rss)
        ))
        #expect(result.status == .unchanged)
    }

    @Test func permanentRedirectChainIsReported() async throws {
        StubURLProtocol.set("http://d.test/feed", .init(status: 301, headers: ["Location": "https://d.test/feed"]))
        StubURLProtocol.set("https://d.test/feed", .init(status: 308, headers: ["Location": "https://d.test/rss.xml"]))
        StubURLProtocol.set("https://d.test/rss.xml", .init(status: 200, body: rss))
        let result = try await fetcher.fetch(FetchRequest(url: URL(string: "http://d.test/feed")!))
        #expect(result.movedTo == URL(string: "https://d.test/rss.xml"))
    }

    @Test func temporaryRedirectIsNotPersisted() async throws {
        StubURLProtocol.set("https://e.test/feed", .init(status: 301, headers: ["Location": "https://e.test/feed2"]))
        StubURLProtocol.set("https://e.test/feed2", .init(status: 302, headers: ["Location": "https://cdn.e.test/feed"]))
        StubURLProtocol.set("https://cdn.e.test/feed", .init(status: 200, body: rss))
        let result = try await fetcher.fetch(FetchRequest(url: URL(string: "https://e.test/feed")!))
        #expect(result.movedTo == nil)
        guard case .updated = result.status else { Issue.record("expected update"); return }
    }

    @Test func htmlPageWithFeedLinkIsFollowedAndPersisted() async throws {
        let page = #"<!DOCTYPE html><html><head><link rel="alternate" type="application/rss+xml" href="/rss.xml"></head></html>"#
        StubURLProtocol.set("https://f.test/feed/", .init(status: 200, body: Data(page.utf8)))
        StubURLProtocol.set("https://f.test/rss.xml", .init(status: 200, body: rss))
        let result = try await fetcher.fetch(FetchRequest(url: URL(string: "https://f.test/feed/")!))
        #expect(result.movedTo == URL(string: "https://f.test/rss.xml"))
        guard case .updated(let feed) = result.status else { Issue.record("expected update"); return }
        #expect(feed.title == "Feed")
    }

    @Test func htmlPageWithoutFeedLinkIsNotAFeed() async {
        StubURLProtocol.set("https://g.test/feed", .init(status: 200, body: Data("<html><body>gone</body></html>".utf8)))
        await #expect(throws: FetchError.notAFeed) {
            try await fetcher.fetch(FetchRequest(url: URL(string: "https://g.test/feed")!))
        }
    }

    @Test func httpErrorsAreReported() async {
        StubURLProtocol.set("https://h.test/feed", .init(status: 404))
        await #expect(throws: FetchError.http(status: 404)) {
            try await fetcher.fetch(FetchRequest(url: URL(string: "https://h.test/feed")!))
        }
    }

    @Test func transportErrorsAreReported() async {
        await #expect(throws: (any Error).self) {
            try await fetcher.fetch(FetchRequest(url: URL(string: "https://unknown.test/feed")!))
        }
    }
}
