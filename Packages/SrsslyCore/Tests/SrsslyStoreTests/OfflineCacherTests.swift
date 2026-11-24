import Foundation
import SrsslyCore
import SwiftData
import Testing
@testable import SrsslyStore

/// Serves canned resources by URL and records what was asked for.
actor StubResourceFetcher: ResourceFetching {
    var responses: [URL: Result<FetchedResource, ResourceFetchError>] = [:]
    var requests: [(URL, Bool)] = []

    func set(_ url: String, html: String) {
        let u = URL(string: url)!
        responses[u] = .success(FetchedResource(data: Data(html.utf8), mimeType: "text/html", finalURL: u))
    }

    func set(_ url: String, bytes: Int) {
        let u = URL(string: url)!
        responses[u] = .success(FetchedResource(data: Data(repeating: 7, count: bytes), mimeType: "image/png", finalURL: u))
    }

    func set(_ url: String, error: ResourceFetchError) { responses[URL(string: url)!] = .failure(error) }

    func requested() -> [URL] { requests.map(\.0) }
    func cellularFlags() -> [Bool] { requests.map(\.1) }

    func fetch(_ url: URL, allowsCellular: Bool) async throws(ResourceFetchError) -> FetchedResource {
        requests.append((url, allowsCellular))
        guard let response = responses[url] else { throw .http(status: 404) }
        return try response.get()
    }
}

@MainActor
@Suite struct OfflineCacherTests {
    let container: ModelContainer
    let cache: OfflineCache
    let fetcher = StubResourceFetcher()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try SrsslyStore.makeContainer(inMemory: true)
        cache = try OfflineCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "OfflineCacherTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func makeCacher(_ policy: OfflineCachePolicy = .standard) -> OfflineCacher {
        OfflineCacher(container: container, cache: cache, fetcher: fetcher, policy: policy)
    }

    @discardableResult
    private func subscription(_ feed: String, mode: CacheMode = .automatic, detected: CacheMode? = nil) throws -> Subscription {
        let sub = Subscription(feedURL: URL(string: feed)!, title: feed)
        sub.cacheMode = mode
        container.mainContext.insert(sub)
        if let detected {
            let state = FeedFetchState(subscriptionID: sub.id)
            state.detectedCacheModeRaw = detected.rawValue
            container.mainContext.insert(state)
        }
        try container.mainContext.save()
        return sub
    }

    @discardableResult
    private func article(_ sub: Subscription, _ guid: String, link: String?, html: String? = nil, age: TimeInterval = 3600) throws -> Article {
        let article = Article(
            key: "\(sub.id.uuidString.lowercased()):\(guid)", subscriptionID: sub.id, guid: guid, title: guid,
            link: link.flatMap(URL.init(string:)), publishedAt: now.addingTimeInterval(-age), summaryHTML: html
        )
        container.mainContext.insert(article)
        try container.mainContext.save()
        return article
    }

    private func stored(_ key: String) throws -> Article {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first)
    }

    @Test func feedContentDownloadsTheFeedsImages() async throws {
        let sub = try subscription("https://comic.test/rss", detected: .feedContent)
        let a = try article(sub, "1", link: "https://comic.test/1", html: #"<img src="/c/1.png" title="hover">"#)
        await fetcher.set("https://comic.test/c/1.png", bytes: 100)

        let summary = await makeCacher().run(allowsCellular: false, now: now)

        #expect(summary.cached == 1)
        #expect(summary.bytes == 100)
        #expect(await fetcher.requested() == [URL(string: "https://comic.test/c/1.png")!], "the page itself isn't fetched")
        #expect(await fetcher.cellularFlags() == [false])
        let saved = try stored(a.key)
        #expect(saved.offlineCachedAt == now)
        #expect(saved.offlinePageFile == nil)
        #expect(saved.offlineResources == [OfflineFileName.resource(URL(string: "https://comic.test/c/1.png")!)])
        #expect(cache.hasResource(URL(string: "https://comic.test/c/1.png")!))
    }

    @Test func fullPageSavesThePageAndItsImages() async throws {
        let sub = try subscription("https://news.test/rss", detected: .fullPage)
        let a = try article(sub, "1", link: "https://news.test/story", html: "Teaser")
        await fetcher.set("https://news.test/story", html: #"<link rel="stylesheet" href="/s.css"><img src="hero.jpg">"#)
        await fetcher.set("https://news.test/hero.jpg", bytes: 50)
        await fetcher.set("https://news.test/s.css", bytes: 10)

        let summary = await makeCacher().run(allowsCellular: true, now: now)

        #expect(summary.cached == 1)
        let saved = try stored(a.key)
        let page = try #require(saved.offlinePageFile)
        #expect(cache.page(named: page).map { String(decoding: $0, as: UTF8.self) }?.contains("hero.jpg") == true)
        #expect(saved.offlineResources.count == 2)
        #expect(await fetcher.cellularFlags().allSatisfy { $0 })
    }

    @Test func subscriptionChoiceOverridesDetection() async throws {
        let sub = try subscription("https://news.test/rss", mode: .fullPage, detected: .feedContent)
        try article(sub, "1", link: "https://news.test/a")
        await fetcher.set("https://news.test/a", html: "<p>Page</p>")
        await makeCacher().run(allowsCellular: false, now: now)
        #expect(await fetcher.requested() == [URL(string: "https://news.test/a")!])
    }

    @Test func pageFailuresCountAndEventuallyGiveUp() async throws {
        let sub = try subscription("https://news.test/rss", detected: .fullPage)
        let a = try article(sub, "1", link: "https://news.test/gone")
        await fetcher.set("https://news.test/gone", error: .http(status: 500))
        var policy = OfflineCachePolicy()
        policy.maxAttempts = 2
        let cacher = makeCacher(policy)

        #expect(await cacher.run(allowsCellular: false, now: now).failed == 1)
        #expect(await cacher.run(allowsCellular: false, now: now).failed == 1)
        #expect(await cacher.run(allowsCellular: false, now: now).failed == 0, "gave up after two attempts")
        let saved = try stored(a.key)
        #expect(saved.offlineAttempts == 2)
        #expect(saved.offlineCachedAt == nil)
        #expect(saved.offlineError != nil)
    }

    @Test func missingImagesDontFailTheArticle() async throws {
        let sub = try subscription("https://comic.test/rss", detected: .feedContent)
        let a = try article(sub, "1", link: "https://comic.test/1", html: #"<img src="https://comic.test/missing.png">"#)
        #expect(await makeCacher().run(allowsCellular: false, now: now).cached == 1)
        #expect(try stored(a.key).offlineResources.isEmpty)
    }

    @Test func noAllowedNetworkStopsWithoutCountingFailures() async throws {
        let sub = try subscription("https://news.test/rss", detected: .fullPage)
        let a = try article(sub, "1", link: "https://news.test/a")
        await fetcher.set("https://news.test/a", error: .networkUnavailable)
        var policy = OfflineCachePolicy()
        policy.maxConcurrentArticles = 1

        let summary = await makeCacher(policy).run(allowsCellular: false, now: now)

        #expect(summary.stoppedForNetwork)
        #expect(summary.failed == 0)
        #expect(try stored(a.key).offlineAttempts == 0)
    }

    @Test func newestFirstAndOldArticlesSkipped() async throws {
        let sub = try subscription("https://news.test/rss", detected: .fullPage)
        try article(sub, "old", link: "https://news.test/old", age: 40 * 24 * 3600)
        try article(sub, "older", link: "https://news.test/older", age: 7200)
        try article(sub, "newer", link: "https://news.test/newer", age: 60)
        for path in ["old", "older", "newer"] { await fetcher.set("https://news.test/\(path)", html: "<p>\(path)</p>") }
        var policy = OfflineCachePolicy()
        policy.maxConcurrentArticles = 1

        await makeCacher(policy).run(allowsCellular: false, now: now)

        #expect(await fetcher.requested().map(\.lastPathComponent) == ["newer", "older"])
    }

    @Test func sharedImagesDownloadOnce() async throws {
        let sub = try subscription("https://comic.test/rss", detected: .feedContent)
        try article(sub, "1", link: "https://comic.test/1", html: #"<img src="https://comic.test/logo.png">"#)
        try article(sub, "2", link: "https://comic.test/2", html: #"<img src="https://comic.test/logo.png">"#, age: 7200)
        await fetcher.set("https://comic.test/logo.png", bytes: 5)
        var policy = OfflineCachePolicy()
        policy.maxConcurrentArticles = 1

        #expect(await makeCacher(policy).run(allowsCellular: false, now: now).cached == 2)
        #expect(await fetcher.requested().count == 1)
    }

    @Test func pruneRemovesOldUnstarredAndUnusedFiles() async throws {
        let sub = try subscription("https://comic.test/rss", detected: .feedContent)
        let old = try article(sub, "old", link: "https://comic.test/old", html: #"<img src="https://comic.test/old.png">"#, age: 20 * 24 * 3600)
        let starred = try article(sub, "starred", link: "https://comic.test/s", html: #"<img src="https://comic.test/s.png">"#, age: 20 * 24 * 3600)
        await fetcher.set("https://comic.test/old.png", bytes: 10)
        await fetcher.set("https://comic.test/s.png", bytes: 10)
        container.mainContext.insert(ArticleState(articleKey: starred.key, isStarred: true))
        try container.mainContext.save()
        let cacher = makeCacher()
        #expect(await cacher.run(allowsCellular: false, now: now).cached == 2)

        // Fifteen days later both are past the 30-day limit.
        let freed = await cacher.prune(now: now.addingTimeInterval(15 * 24 * 3600))

        #expect(freed == 10)
        #expect(try stored(old.key).offlineCachedAt == nil)
        #expect(try stored(starred.key).offlineCachedAt != nil)
        #expect(!cache.hasResource(URL(string: "https://comic.test/old.png")!))
        #expect(cache.hasResource(URL(string: "https://comic.test/s.png")!))
        #expect(await cacher.run(allowsCellular: false, now: now.addingTimeInterval(15 * 24 * 3600)).cached == 0,
                "pruned articles aren't downloaded again")
    }

    @Test func pruneKeepsTheCacheUnderItsSizeLimit() async throws {
        let sub = try subscription("https://comic.test/rss", detected: .feedContent)
        let older = try article(sub, "a", link: "https://comic.test/a", html: #"<img src="https://comic.test/a.png">"#, age: 7200)
        let newer = try article(sub, "b", link: "https://comic.test/b", html: #"<img src="https://comic.test/b.png">"#, age: 60)
        await fetcher.set("https://comic.test/a.png", bytes: 60)
        await fetcher.set("https://comic.test/b.png", bytes: 60)
        var policy = OfflineCachePolicy()
        policy.maxTotalBytes = 100
        let cacher = makeCacher(policy)
        await cacher.run(allowsCellular: false, now: now)

        await cacher.prune(now: now)

        #expect(try stored(older.key).offlineCachedAt == nil, "oldest goes first")
        #expect(try stored(newer.key).offlineCachedAt != nil)
        #expect(cache.totalBytes() == 60)
    }
}

@MainActor
@Suite struct DetectedCacheModeTests {
    @Test func refresherRecordsTheDetectedMode() async throws {
        let container = try SrsslyStore.makeContainer(inMemory: true)
        let url = URL(string: "https://teaser.test/feed")!
        container.mainContext.insert(Subscription(feedURL: url, title: "T"))
        try container.mainContext.save()
        let fetcher = StubFetcher()
        await fetcher.set(url, updated([
            ParsedItem(guid: "1", link: URL(string: "https://teaser.test/1"), summaryHTML: "Read more"),
        ]))

        await FeedRefresher(container: container, fetcher: fetcher).refresh()

        let state = try #require(try ModelContext(container).fetch(FetchDescriptor<FeedFetchState>()).first)
        #expect(state.detectedCacheMode == .fullPage)
    }
}
