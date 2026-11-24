import Foundation
import SrsslyCore
import SwiftData
import Testing
@testable import SrsslyStore

/// Returns canned results per feed URL and records what it was asked for.
actor StubFetcher: FeedFetching {
    var results: [URL: Result<FetchResult, FetchError>] = [:]
    var requests: [FetchRequest] = []

    func set(_ url: URL, _ result: Result<FetchResult, FetchError>) { results[url] = result }

    func fetch(_ request: FetchRequest) async throws(FetchError) -> FetchResult {
        requests.append(request)
        guard let result = results[request.url] else { throw .transport("no stub") }
        return try result.get()
    }
}

func updated(_ items: [ParsedItem], title: String? = "Feed", etag: String? = "\"e\"", movedTo: URL? = nil) -> Result<FetchResult, FetchError> {
    .success(FetchResult(
        status: .updated(ParsedFeed(format: .rss2, title: title, siteURL: URL(string: "https://site.test/"), items: items)),
        movedTo: movedTo, etag: etag, lastModified: nil, contentHash: "h"
    ))
}

@MainActor
@Suite struct FeedRefresherTests {
    let container: ModelContainer
    let fetcher = StubFetcher()
    let feedURL = URL(string: "https://a.test/feed")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try SrsslyStore.makeContainer(inMemory: true, cloudKit: false)
    }

    private func addSubscription(_ url: URL? = nil, title: String = "") throws -> Subscription {
        let sub = Subscription(feedURL: url ?? feedURL, title: title)
        container.mainContext.insert(sub)
        try container.mainContext.save()
        return sub
    }

    private func articles() throws -> [Article] {
        try ModelContext(container).fetch(FetchDescriptor<Article>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]))
    }

    private func fetchState() throws -> FeedFetchState? {
        try ModelContext(container).fetch(FetchDescriptor<FeedFetchState>()).first
    }

    @Test func insertsArticlesAndRecordsValidators() async throws {
        let sub = try addSubscription()
        await fetcher.set(feedURL, updated([
            ParsedItem(guid: "1", title: "Old", published: now.addingTimeInterval(-3_600)),
            ParsedItem(guid: "2", title: "New", published: now.addingTimeInterval(-60)),
        ]))
        let refresher = FeedRefresher(container: container, fetcher: fetcher)

        let summary = await refresher.refresh(now: now)

        #expect(summary.attempted == 1)
        #expect(summary.updated == 1)
        #expect(summary.newArticles == 2)
        #expect(try articles().map(\.title) == ["New", "Old"])
        let state = try #require(try fetchState())
        #expect(state.etag == "\"e\"")
        #expect(state.contentHash == "h")
        #expect(state.lastSuccessAt == now)
        #expect(state.latestItemAt == now.addingTimeInterval(-60))

        let refreshedSub = try #require(try ModelContext(container).fetch(FetchDescriptor<Subscription>()).first)
        #expect(refreshedSub.id == sub.id)
        #expect(refreshedSub.title == "Feed", "empty title is filled from the feed")
        #expect(refreshedSub.siteURLString == "https://site.test/")
    }

    @Test func refetchUpdatesInPlaceAndSendsValidators() async throws {
        _ = try addSubscription(title: "Mine")
        await fetcher.set(feedURL, updated([ParsedItem(guid: "1", title: "Typo", published: now)]))
        let refresher = FeedRefresher(container: container, fetcher: fetcher)
        await refresher.refresh(now: now)

        await fetcher.set(feedURL, updated([
            ParsedItem(guid: "1", title: "Fixed", published: now),
            ParsedItem(guid: "2", title: "Another", published: now.addingTimeInterval(10)),
        ], title: "Theirs"))
        let summary = await refresher.refresh(force: true, now: now.addingTimeInterval(60))

        #expect(summary.newArticles == 1)
        #expect(Set(try articles().map(\.title)) == ["Fixed", "Another"])
        let sub = try #require(try ModelContext(container).fetch(FetchDescriptor<Subscription>()).first)
        #expect(sub.title == "Mine", "a title the user has is kept")
        let lastRequest = try #require(await fetcher.requests.last)
        #expect(lastRequest.etag == "\"e\"")
        #expect(lastRequest.contentHash == "h")
    }

    @Test func skipsFeedsThatAreNotDueUnlessForced() async throws {
        _ = try addSubscription()
        await fetcher.set(feedURL, updated([ParsedItem(guid: "1", title: "A", published: now)]))
        let refresher = FeedRefresher(container: container, fetcher: fetcher)
        await refresher.refresh(now: now)

        let soon = await refresher.refresh(now: now.addingTimeInterval(60))
        #expect(soon.attempted == 0)
        let forced = await refresher.refresh(force: true, now: now.addingTimeInterval(60))
        #expect(forced.attempted == 1)
    }

    @Test func failuresCountUpAndBackOff() async throws {
        _ = try addSubscription()
        await fetcher.set(feedURL, .failure(.http(status: 500)))
        let refresher = FeedRefresher(container: container, fetcher: fetcher)

        let first = await refresher.refresh(now: now)
        #expect(first.failed == 1)
        await refresher.refresh(force: true, now: now.addingTimeInterval(1))
        let state = try #require(try fetchState())
        #expect(state.consecutiveFailures == 2)
        #expect(state.lastError?.contains("500") == true)
        // Two failures: next try is 30 minutes after the last.
        #expect(await refresher.refresh(now: now.addingTimeInterval(20 * 60)).attempted == 0)
        #expect(await refresher.refresh(now: now.addingTimeInterval(32 * 60)).attempted == 1)
    }

    @Test func movedFeedUpdatesSubscriptionURL() async throws {
        _ = try addSubscription(URL(string: "http://old.test/feed")!)
        let newURL = URL(string: "https://new.test/rss.xml")!
        await fetcher.set(URL(string: "http://old.test/feed")!, updated([], movedTo: newURL))
        let refresher = FeedRefresher(container: container, fetcher: fetcher)
        await refresher.refresh(now: now)

        let sub = try #require(try ModelContext(container).fetch(FetchDescriptor<Subscription>()).first)
        #expect(sub.feedURL == newURL)
        #expect(sub.canonicalKey == "new.test/rss.xml")
    }

    @Test func undatedItemsUseFirstSeenTimeAndDuplicatesCollapse() async throws {
        _ = try addSubscription()
        await fetcher.set(feedURL, updated([
            ParsedItem(guid: "same", title: "One"),
            ParsedItem(guid: "same", title: "One again"),
        ]))
        let refresher = FeedRefresher(container: container, fetcher: fetcher)
        let summary = await refresher.refresh(now: now)
        #expect(summary.newArticles == 1)
        #expect(try articles().first?.publishedAt == now)
    }

    @Test func notModifiedKeepsArticles() async throws {
        _ = try addSubscription()
        await fetcher.set(feedURL, updated([ParsedItem(guid: "1", title: "A", published: now)]))
        let refresher = FeedRefresher(container: container, fetcher: fetcher)
        await refresher.refresh(now: now)
        await fetcher.set(feedURL, .success(FetchResult(status: .notModified, etag: "\"e\"", contentHash: "h")))
        let summary = await refresher.refresh(force: true, now: now.addingTimeInterval(60))
        #expect(summary.unchanged == 1)
        #expect(try articles().count == 1)
    }
}

/// Answers one feed straight away and hangs on the rest until cancelled.
actor SlowFetcher: FeedFetching {
    let fastURL: URL
    init(fastURL: URL) { self.fastURL = fastURL }

    func fetch(_ request: FetchRequest) async throws(FetchError) -> FetchResult {
        if request.url == fastURL {
            return try updated([ParsedItem(guid: "fast", title: "Fast")]).get()
        }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            throw .transport("cancelled")
        }
        return try updated([]).get()
    }
}

@MainActor
@Suite struct FeedRefresherCancellationTests {
    @Test func cancellingKeepsFinishedFeedsAndDoesNotCountFailures() async throws {
        let container = try SrsslyStore.makeContainer(inMemory: true, cloudKit: false)
        let fast = URL(string: "https://fast.test/feed")!
        container.mainContext.insert(Subscription(feedURL: fast, title: "Fast"))
        container.mainContext.insert(Subscription(feedURL: URL(string: "https://slow.test/feed")!, title: "Slow"))
        try container.mainContext.save()
        let refresher = FeedRefresher(container: container, fetcher: SlowFetcher(fastURL: fast))

        let task = Task { await refresher.refresh() }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let summary = await task.value

        #expect(summary.failed == 0)
        #expect(summary.newArticles == 1)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Article>()).map(\.title) == ["Fast"])
        let states = try context.fetch(FetchDescriptor<FeedFetchState>())
        #expect(states.allSatisfy { $0.consecutiveFailures == 0 })
    }
}
