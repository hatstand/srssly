import Foundation
import OSLog
import SrsslyCore
import SwiftData

/// Limits for the offline cache.
public struct OfflineCachePolicy: Sendable {
    /// Only articles published this recently are cached.
    public var maxArticleAge: TimeInterval = 30 * 24 * 3600
    /// Cached articles older than this are removed, unless starred.
    public var keepFor: TimeInterval = 30 * 24 * 3600
    /// Give up on an article after this many failures.
    public var maxAttempts = 3
    public var maxArticlesPerRun = 300
    public var maxResourcesPerArticle = 40
    /// Above this, the oldest unstarred articles are removed first.
    public var maxTotalBytes = 1024 * 1024 * 1024
    public var maxConcurrentArticles = 4

    public init() {}

    public static let standard = OfflineCachePolicy()
}

public struct OfflineCacheSummary: Sendable, Equatable {
    public var cached = 0
    public var failed = 0
    public var bytes = 0
    /// The run stopped because no allowed network was available (e.g. the
    /// device left Wi-Fi). Articles not reached are tried next time.
    public var stoppedForNetwork = false

    public init() {}
}

/// Downloads pages and images for recent articles so they can be read
/// offline, and prunes what's no longer needed.
///
/// For each article it works out the cache mode (the subscription's choice,
/// else what `CacheModeDetector` saw in the feed):
///  - `.feedContent`: the images in the feed's own HTML.
///  - `.extractedArticle`: the article extracted from the linked page and
///    its images (or the whole page, if no article was found).
///  - `.fullPage`: the linked page, plus the images and stylesheets it uses
///    and those in the feed's HTML.
///
/// Newest articles go first, so a run cut short has saved the ones most
/// likely to be read.
public actor OfflineCacher: ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public nonisolated let cache: OfflineCache
    private let fetcher: any ResourceFetching
    private let policy: OfflineCachePolicy
    private var inFlight: Task<OfflineCacheSummary, Never>?
    private let log = Logger(subsystem: "com.purplehatstands.srssly", category: "offline")

    public init(
        container: ModelContainer,
        cache: OfflineCache,
        fetcher: any ResourceFetching = HTTPResourceFetcher(),
        policy: OfflineCachePolicy = .standard
    ) {
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
        self.cache = cache
        self.fetcher = fetcher
        self.policy = policy
    }

    /// Caches articles that aren't cached yet. Concurrent calls share one
    /// run. Cancelling stops starting new articles and keeps what finished.
    @discardableResult
    public func run(allowsCellular: Bool, now: Date = .now) async -> OfflineCacheSummary {
        let task: Task<OfflineCacheSummary, Never>
        if let inFlight {
            task = inFlight
        } else {
            task = Task { await self.cacheArticles(allowsCellular: allowsCellular, now: now) }
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

    // MARK: - Caching

    /// What one article needs, copied out of the model so downloads can run
    /// off the actor.
    struct Job: Sendable {
        var key: String
        var mode: CacheMode
        var link: URL?
        var feedHTML: String?
        /// Page images to fetch beyond the feed's, from a site rule.
        var pageImageSelectors: [String] = []
    }

    struct JobResult: Sendable {
        var key: String
        var pageFile: String?
        var resources: [String] = []
        var extraImages: [ImageReference] = []
        var bytes = 0
        var error: String?
        var networkUnavailable = false
    }

    private func cacheArticles(allowsCellular: Bool, now: Date) async -> OfflineCacheSummary {
        var summary = OfflineCacheSummary()
        let jobs: [Job]
        do {
            jobs = try pendingJobs(now: now)
        } catch {
            log.error("Reading articles to cache failed: \(error, privacy: .public)")
            return summary
        }
        guard !jobs.isEmpty else { return summary }

        let cache = self.cache
        let fetcher = self.fetcher
        let policy = self.policy
        var pending = jobs[...]
        var stop = false
        await withTaskGroup(of: JobResult.self) { group in
            func addNext() {
                guard !stop, !Task.isCancelled, let job = pending.popFirst() else { return }
                group.addTask {
                    await Self.perform(job, cache: cache, fetcher: fetcher, policy: policy, allowsCellular: allowsCellular)
                }
            }
            for _ in 0..<max(1, policy.maxConcurrentArticles) { addNext() }
            var unsaved = 0
            while let result = await group.next() {
                if result.networkUnavailable {
                    stop = true
                    summary.stoppedForNetwork = true
                } else {
                    apply(result, now: now, summary: &summary)
                    unsaved += 1
                    if unsaved >= 20 { save(); unsaved = 0 }
                }
                addNext()
            }
        }
        save()
        log.notice("Offline cache: \(summary.cached) cached, \(summary.failed) failed, \(summary.bytes) bytes\(summary.stoppedForNetwork ? ", stopped: no allowed network" : "")")
        return summary
    }

    private func pendingJobs(now: Date) throws -> [Job] {
        let oldest = now.addingTimeInterval(-policy.maxArticleAge)
        let maxAttempts = policy.maxAttempts
        var descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.offlineCachedAt == nil && $0.offlineAttempts < maxAttempts && $0.publishedAt >= oldest },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = policy.maxArticlesPerRun
        let articles = try modelContext.fetch(descriptor)
        guard !articles.isEmpty else { return [] }

        let subscriptions = Dictionary(
            try modelContext.fetch(FetchDescriptor<Subscription>()).map { ($0.id, (mode: $0.cacheMode, feed: $0.feedURL)) },
            uniquingKeysWith: { a, _ in a }
        )
        let detected = Dictionary(
            try modelContext.fetch(FetchDescriptor<FeedFetchState>()).map { ($0.subscriptionID, $0.detectedCacheMode) },
            uniquingKeysWith: { a, _ in a }
        )
        return articles.compactMap { article in
            // Articles whose subscription was removed are left alone.
            guard let sub = subscriptions[article.subscriptionID] else { return nil }
            let detectedMode = detected[article.subscriptionID].flatMap { $0 } ?? .feedContent
            let rule = SiteRules.rule(article: article.link, feed: sub.feed)
            return Job(
                key: article.key,
                mode: CacheModeDetector.effectiveMode(sub.mode, siteRule: rule?.cacheMode, detected: detectedMode),
                link: article.link,
                feedHTML: article.contentHTML ?? article.summaryHTML,
                pageImageSelectors: rule?.pageImageSelectors ?? []
            )
        }
    }

    /// Downloads one article's page and resources. Runs off the actor.
    static func perform(
        _ job: Job, cache: OfflineCache, fetcher: any ResourceFetching,
        policy: OfflineCachePolicy, allowsCellular: Bool
    ) async -> JobResult {
        var result = JobResult(key: job.key)
        var urls: [URL] = []

        let needsPage = job.mode == .fullPage || job.mode == .extractedArticle || !job.pageImageSelectors.isEmpty
        if needsPage, let link = job.link {
            do throws(ResourceFetchError) {
                let page = try await fetcher.fetch(link, allowsCellular: allowsCellular)
                let html = String(decoding: page.data, as: UTF8.self)
                var saveWholePage = job.mode == .fullPage
                if job.mode == .extractedArticle {
                    if let article = ArticleExtractor.extract(html, pageURL: page.finalURL) {
                        let data = ArticleExtractor.savedPage(article)
                        result.pageFile = try? cache.storePage(data, articleKey: job.key)
                        result.bytes += data.count
                        urls += HTMLResources.scan(article.html, baseURL: page.finalURL).downloadURLs
                    } else {
                        // Nothing looked like an article: keep the page.
                        saveWholePage = true
                    }
                }
                if saveWholePage {
                    result.pageFile = try? cache.storePage(page.data, articleKey: job.key)
                    result.bytes += page.data.count
                    // Stylesheets first: a page with many images would
                    // otherwise use up the resource limit before them.
                    let resources = HTMLResources.scan(html, baseURL: page.finalURL)
                    urls += resources.stylesheets + resources.images.map(\.url)
                }
                result.extraImages = SiteRules.pageImages(html, pageURL: page.finalURL, selectors: job.pageImageSelectors)
                urls += result.extraImages.map(\.url)
            } catch .networkUnavailable {
                result.networkUnavailable = true
                return result
            } catch {
                result.error = String(describing: error)
                return result
            }
        }
        if let html = job.feedHTML {
            urls += HTMLResources.scan(html, baseURL: job.link).downloadURLs
        }

        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard seen.count <= policy.maxResourcesPerArticle, !Task.isCancelled else { break }
            if cache.hasResource(url) {
                result.resources.append(OfflineFileName.resource(url))
                continue
            }
            do throws(ResourceFetchError) {
                let resource = try await fetcher.fetch(url, allowsCellular: allowsCellular)
                if let name = try? cache.storeResource(resource.data, for: url) {
                    result.resources.append(name)
                    result.bytes += resource.data.count
                }
            } catch .networkUnavailable {
                result.networkUnavailable = true
                return result
            } catch {
                // A missing image doesn't stop the article being readable.
                continue
            }
        }
        return result
    }

    private func apply(_ result: JobResult, now: Date, summary: inout OfflineCacheSummary) {
        let key = result.key
        guard let article = try? modelContext.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first else { return }
        if let error = result.error {
            article.offlineAttempts += 1
            article.offlineError = error
            summary.failed += 1
        } else {
            article.offlineCachedAt = now
            article.offlineError = nil
            article.offlinePageFile = result.pageFile
            article.offlineResources = result.resources
            article.offlineBytes = result.bytes
            article.extraImages = result.extraImages
            summary.cached += 1
            summary.bytes += result.bytes
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            log.error("Saving offline cache state failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Pruning

    /// Removes cached copies of old articles (keeping starred ones), then
    /// the oldest until the cache fits its size limit, then any files no
    /// article uses. Returns bytes freed.
    @discardableResult
    public func prune(now: Date = .now) -> Int {
        let cached: [Article]
        let starred: Set<String>
        do {
            cached = try modelContext.fetch(FetchDescriptor<Article>(
                predicate: #Predicate { $0.offlineCachedAt != nil },
                sortBy: [SortDescriptor(\.publishedAt)]
            ))
            starred = Set(try modelContext.fetch(FetchDescriptor<ArticleState>(
                predicate: #Predicate { $0.isStarred == true }
            )).map(\.articleKey))
        } catch {
            log.error("Reading cached articles failed: \(error, privacy: .public)")
            return 0
        }

        let cutoff = now.addingTimeInterval(-policy.keepFor)
        var kept: [Article] = []
        for article in cached {
            if article.publishedAt < cutoff, !starred.contains(article.key) {
                uncache(article)
            } else {
                kept.append(article)
            }
        }

        // Over budget: drop the oldest unstarred articles first. Shared
        // resources are counted once per article, so this errs towards
        // freeing more than strictly needed.
        var total = kept.reduce(0) { $0 + $1.offlineBytes }
        for article in kept where total > policy.maxTotalBytes && !starred.contains(article.key) {
            total -= article.offlineBytes
            uncache(article)
        }
        save()

        let remaining = cached.filter { $0.offlineCachedAt != nil }
        var freed = cache.removePages(notIn: Set(remaining.compactMap(\.offlinePageFile)))
        freed += cache.removeResources(notIn: Set(remaining.flatMap(\.offlineResources)))
        if freed > 0 { log.notice("Offline cache pruned \(freed) bytes") }
        return freed
    }

    private func uncache(_ article: Article) {
        article.offlineCachedAt = nil
        article.offlinePageFile = nil
        article.offlineResources = []
        article.offlineBytes = 0
        // Don't download it again: it's past the age limit or over budget.
        article.offlineAttempts = policy.maxAttempts
    }
}
