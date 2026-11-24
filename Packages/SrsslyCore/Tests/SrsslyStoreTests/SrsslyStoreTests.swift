import Foundation
import SrsslyCore
import SwiftData
import Testing
@testable import SrsslyStore

@MainActor
@Suite struct SrsslyStoreTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try SrsslyStore.makeContainer(inMemory: true)
    }

    @Test func subscriptionStoresCanonicalKeyAndCacheMode() throws {
        let sub = Subscription(feedURL: URL(string: "http://www.popehat.com/feed/")!, title: "Popehat", folder: "Random")
        sub.cacheMode = .extractedArticle
        context.insert(sub)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
        #expect(fetched.canonicalKey == "popehat.com/feed")
        #expect(fetched.cacheMode == .extractedArticle)

        fetched.updateFeedURL(URL(string: "https://popehat.com/feed")!)
        #expect(fetched.feedURLString == "https://popehat.com/feed")
        #expect(fetched.canonicalKey == "popehat.com/feed")
    }

    @Test func findsDuplicateSubscriptionsByCanonicalKey() throws {
        context.insert(Subscription(feedURL: URL(string: "http://www.popehat.com/feed/")!, title: "Popehat"))
        context.insert(Subscription(feedURL: URL(string: "https://popehat.com/feed")!, title: "Popehat"))
        context.insert(Subscription(feedURL: URL(string: "https://popehat.substack.com/feed")!, title: "The Popehat Report"))
        try context.save()

        let key = "popehat.com/feed"
        let dupes = try context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.canonicalKey == key }))
        #expect(dupes.count == 2)
    }

    @Test func articlesSortNewestFirstAndUpsertByKey() throws {
        let subID = UUID()
        func article(_ guid: String, _ t: TimeInterval, title: String) -> Article {
            Article(
                key: ArticleKey.make(subscriptionID: subID, guid: guid, link: nil, title: nil, published: nil),
                subscriptionID: subID, guid: guid, title: title, link: nil,
                publishedAt: Date(timeIntervalSince1970: t)
            )
        }
        context.insert(article("a", 100, title: "Old"))
        context.insert(article("b", 200, title: "New"))
        try context.save()
        // Same key again (a re-fetch) replaces rather than duplicates.
        context.insert(article("a", 100, title: "Old, edited"))
        try context.save()

        let all = try context.fetch(FetchDescriptor<Article>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]))
        #expect(all.map(\.title) == ["New", "Old, edited"])
    }

    @Test func readStateJoinsToArticlesByKey() throws {
        let subID = UUID()
        let key = ArticleKey.make(subscriptionID: subID, guid: "x", link: nil, title: nil, published: nil)
        context.insert(Article(key: key, subscriptionID: subID, guid: "x", title: "X", link: nil, publishedAt: .now))
        context.insert(ArticleState(articleKey: key, isRead: true))
        try context.save()

        let state = try #require(try context.fetch(FetchDescriptor<ArticleState>(predicate: #Predicate { $0.articleKey == key })).first)
        #expect(state.isRead)
        #expect(!state.isStarred)
    }

    @Test func fetchStateDefaults() throws {
        let state = FeedFetchState(subscriptionID: UUID())
        context.insert(state)
        try context.save()
        #expect(state.consecutiveFailures == 0)
        #expect(state.etag == nil)
    }
}
