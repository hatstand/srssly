import Foundation
import OSLog
import SrsslyCore
import SwiftData

public struct RefreshSummary: Sendable, Equatable {
    public var attempted = 0
    public var updated = 0
    public var unchanged = 0
    public var failed = 0
    public var newArticles = 0

    public init() {}
}

/// Fetches due feeds in parallel and writes the results to the store.
///
/// Runs on its own model context off the main actor. SwiftData merges the
/// saved changes into the main context, so the UI updates without waiting
/// on this.
public actor FeedRefresher: ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    private let fetcher: any FeedFetching
    private let policy: RefreshPolicy
    private let maxConcurrentFetches: Int
    private var inFlight: Task<RefreshSummary, Never>?
    private let log = Logger(subsystem: "com.purplehatstands.srssly", category: "refresh")

    public init(
        container: ModelContainer,
        fetcher: any FeedFetching = HTTPFeedFetcher(),
        policy: RefreshPolicy = .standard,
        maxConcurrentFetches: Int = 6
    ) {
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
        self.fetcher = fetcher
        self.policy = policy
        self.maxConcurrentFetches = maxConcurrentFetches
    }

    /// Refreshes every feed that is due, or every feed when `force` is set
    /// (pull to refresh). Concurrent calls share one refresh.
    ///
    /// Cancelling (e.g. when a background task's time runs out) stops
    /// starting new fetches and saves what has arrived so far. Fetches cut
    /// off by the cancellation don't count as failures.
    @discardableResult
    public func refresh(force: Bool = false, now: Date = .now) async -> RefreshSummary {
        let task: Task<RefreshSummary, Never>
        if let inFlight {
            task = inFlight
        } else {
            task = Task { await self.run(force: force, now: now) }
            inFlight = task
        }
        let summary = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight == task { inFlight = nil }
        return summary
    }

    private func run(force: Bool, now: Date) async -> RefreshSummary {
        var summary = RefreshSummary()
        let subscriptions: [Subscription]
        let states: [UUID: FeedFetchState]
        do {
            subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>())
            states = Dictionary(
                try modelContext.fetch(FetchDescriptor<FeedFetchState>()).map { ($0.subscriptionID, $0) },
                uniquingKeysWith: { a, _ in a }
            )
        } catch {
            log.error("Reading subscriptions failed: \(error, privacy: .public)")
            return summary
        }

        var jobs: [(UUID, FetchRequest)] = []
        for sub in subscriptions {
            guard let url = sub.feedURL else { continue }
            let state = states[sub.id]
            if !force, !policy.isDue(
                lastAttempt: state?.lastAttemptAt, consecutiveFailures: state?.consecutiveFailures ?? 0,
                latestItem: state?.latestItemAt, now: now
            ) { continue }
            jobs.append((sub.id, FetchRequest(
                url: url, etag: state?.etag, lastModified: state?.lastModified, contentHash: state?.contentHash
            )))
        }
        guard !jobs.isEmpty else { return summary }

        let results = await fetchAll(jobs)
        let byID = Dictionary(subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cancelled = Task.isCancelled
        for (id, result) in results {
            guard let sub = byID[id] else { continue }
            if cancelled, case .failure = result { continue }
            let state = states[id] ?? {
                let s = FeedFetchState(subscriptionID: id)
                modelContext.insert(s)
                return s
            }()
            apply(result, to: sub, state: state, now: now, summary: &summary)
        }
        summary.attempted = results.count

        do {
            try modelContext.save()
        } catch {
            log.error("Saving refresh failed: \(error, privacy: .public)")
        }
        log.notice("Refreshed \(summary.attempted) feeds: \(summary.updated) updated, \(summary.unchanged) unchanged, \(summary.failed) failed, \(summary.newArticles) new articles")
        return summary
    }

    private func fetchAll(_ jobs: [(UUID, FetchRequest)]) async -> [(UUID, Result<FetchResult, FetchError>)] {
        let fetcher = self.fetcher
        let limit = max(1, maxConcurrentFetches)
        return await withTaskGroup(of: (UUID, Result<FetchResult, FetchError>).self) { group in
            var results: [(UUID, Result<FetchResult, FetchError>)] = []
            var pending = jobs[...]
            func addNext() {
                guard !Task.isCancelled, let (id, request) = pending.popFirst() else { return }
                group.addTask {
                    do throws(FetchError) {
                        return (id, .success(try await fetcher.fetch(request)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for _ in 0..<limit { addNext() }
            while let result = await group.next() {
                results.append(result)
                addNext()
            }
            return results
        }
    }

    private func apply(
        _ result: Result<FetchResult, FetchError>, to sub: Subscription, state: FeedFetchState,
        now: Date, summary: inout RefreshSummary
    ) {
        state.lastAttemptAt = now
        switch result {
        case .failure(let error):
            state.consecutiveFailures += 1
            state.lastError = String(describing: error)
            summary.failed += 1

        case .success(let fetched):
            state.consecutiveFailures = 0
            state.lastError = nil
            state.lastSuccessAt = now
            state.etag = fetched.etag
            state.lastModified = fetched.lastModified
            state.contentHash = fetched.contentHash
            if let movedTo = fetched.movedTo, movedTo != sub.feedURL {
                // Synced, so other devices fetch the new URL too.
                sub.updateFeedURL(movedTo)
            }
            switch fetched.status {
            case .notModified, .unchanged:
                summary.unchanged += 1
            case .updated(let feed):
                summary.updated += 1
                if sub.title.isEmpty, let title = feed.title {
                    sub.title = title
                    sub.modifiedAt = now
                }
                if sub.siteURLString == nil, let site = feed.siteURL {
                    sub.siteURLString = site.absoluteString
                    sub.modifiedAt = now
                }
                summary.newArticles += upsert(feed.items, for: sub.id, state: state, now: now)
                if !feed.items.isEmpty {
                    let detected = CacheModeDetector.detect(feed.items).rawValue
                    if state.detectedCacheModeRaw != detected { state.detectedCacheModeRaw = detected }
                }
            }
        }
    }

    /// Inserts new items and updates changed ones. Returns the number inserted.
    private func upsert(_ items: [ParsedItem], for subscriptionID: UUID, state: FeedFetchState, now: Date) -> Int {
        let existing: [String: Article]
        do {
            let found = try modelContext.fetch(FetchDescriptor<Article>(
                predicate: #Predicate { $0.subscriptionID == subscriptionID }
            ))
            existing = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            log.error("Reading articles failed: \(error, privacy: .public)")
            return 0
        }

        var inserted = 0
        var seen = Set<String>()
        for item in items {
            let key = ArticleKey.make(
                subscriptionID: subscriptionID, guid: item.guid, link: item.link?.absoluteString,
                title: item.title, published: item.date
            )
            guard seen.insert(key).inserted else { continue }
            let title = item.title ?? item.link?.absoluteString ?? "Untitled"
            if let article = existing[key] {
                // Publishers fix typos and add content after posting.
                if article.title != title { article.title = title }
                if article.summaryHTML != item.summaryHTML { article.summaryHTML = item.summaryHTML }
                if article.contentHTML != item.contentHTML { article.contentHTML = item.contentHTML }
                if let date = item.date, article.publishedAt != date { article.publishedAt = date }
            } else {
                modelContext.insert(Article(
                    key: key, subscriptionID: subscriptionID, guid: item.guid, title: title, link: item.link,
                    author: item.author,
                    // Undated items sort by when we first saw them.
                    publishedAt: min(item.date ?? now, now),
                    summaryHTML: item.summaryHTML, contentHTML: item.contentHTML, fetchedAt: now
                ))
                inserted += 1
            }
            if let date = item.date, date > (state.latestItemAt ?? .distantPast) {
                state.latestItemAt = min(date, now)
            }
        }
        return inserted
    }
}
