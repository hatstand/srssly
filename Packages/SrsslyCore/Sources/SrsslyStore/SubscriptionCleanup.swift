import Foundation
import SwiftData

/// Removes this device's articles and fetch state for subscriptions that no
/// longer exist, whether deleted here or on another device. Read and
/// starred state is kept: it's synced, small, and comes back into use if
/// the feed is added again (subscription IDs come from the feed URL).
/// Offline files left unused are deleted by the next `OfflineCacher.prune`.
public enum SubscriptionCleanup {
    /// Returns how many articles were removed.
    @discardableResult
    public static func removeOrphans(in context: ModelContext) throws -> Int {
        let ids = Set(try context.fetch(FetchDescriptor<Subscription>()).map(\.id))
        let orphanArticles = #Predicate<Article> { !ids.contains($0.subscriptionID) }
        let count = try context.fetchCount(FetchDescriptor<Article>(predicate: orphanArticles))
        try context.delete(model: Article.self, where: orphanArticles)
        try context.delete(model: FeedFetchState.self, where: #Predicate { !ids.contains($0.subscriptionID) })
        try context.save()
        return count
    }
}
