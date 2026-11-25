import Foundation
import SwiftData
import Testing
@testable import SrsslyStore

@MainActor
@Suite struct SubscriptionCleanupTests {
    @Test func removesArticlesAndFetchStateOfDeletedSubscriptions() throws {
        let container = try SrsslyStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let kept = Subscription(feedURL: URL(string: "https://kept.test/feed")!, title: "Kept")
        let gone = Subscription(feedURL: URL(string: "https://gone.test/feed")!, title: "Gone")
        context.insert(kept)
        context.insert(gone)
        for (sub, n) in [(kept, 2), (gone, 3)] {
            context.insert(FeedFetchState(subscriptionID: sub.id))
            for i in 0..<n {
                context.insert(Article(key: "\(sub.id):\(i)", subscriptionID: sub.id, guid: "\(i)", title: "\(i)", link: nil, publishedAt: .now))
            }
        }
        context.insert(ArticleState(articleKey: "\(gone.id):0", isStarred: true))
        try context.save()

        context.delete(gone)
        try context.save()
        #expect(try SubscriptionCleanup.removeOrphans(in: context) == 3)

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Article>()).allSatisfy { $0.subscriptionID == kept.id })
        #expect(try fresh.fetchCount(FetchDescriptor<Article>()) == 2)
        #expect(try fresh.fetch(FetchDescriptor<FeedFetchState>()).map(\.subscriptionID) == [kept.id])
        #expect(try fresh.fetchCount(FetchDescriptor<ArticleState>()) == 1, "synced state is kept")
    }
}
