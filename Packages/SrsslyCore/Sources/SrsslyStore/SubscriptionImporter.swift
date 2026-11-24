import Foundation
import SrsslyCore
import SwiftData

public struct ImportSummary: Sendable, Equatable {
    public var added: Int
    public var duplicates: Int

    public init(added: Int = 0, duplicates: Int = 0) {
        self.added = added
        self.duplicates = duplicates
    }
}

public enum SubscriptionImporter {
    /// Adds the feeds that aren't already subscribed (by `FeedURL.canonicalKey`),
    /// keeping the file's order and folders. Doesn't fetch; refresh afterwards.
    @discardableResult
    public static func add(_ feeds: [OPMLFeed], to context: ModelContext) throws -> ImportSummary {
        let existing = try context.fetch(FetchDescriptor<Subscription>())
        var keys = Set(existing.map(\.canonicalKey))
        var summary = ImportSummary()
        var toAdd: [OPMLFeed] = []
        for feed in feeds {
            guard keys.insert(FeedURL.canonicalKey(for: feed.feedURL)).inserted else {
                summary.duplicates += 1
                continue
            }
            toAdd.append(feed)
        }
        // New feeds go after the current end of the list, evenly spaced so
        // the keys stay short.
        let sortKeys = SortKey.keys(between: existing.map(\.sortKey).max(), nil, count: toAdd.count)
        for (feed, sortKey) in zip(toAdd, sortKeys) {
            let sub = Subscription(feedURL: feed.feedURL, title: feed.title, folder: feed.folder, siteURL: feed.siteURL)
            sub.sortKey = sortKey
            context.insert(sub)
            summary.added += 1
        }
        try context.save()
        return summary
    }

    /// Subscribes to a URL the user typed: a feed, or a site whose feed the
    /// first refresh will discover. Adds `https://` when there is no scheme.
    /// Returns nil if it isn't a usable URL or is already subscribed.
    @discardableResult
    public static func add(typed input: String, to context: ModelContext) throws -> Subscription? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("feed:") { text = String(text.dropFirst(5)).replacingOccurrences(of: "//", with: "", options: .anchored) }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
            return nil
        }
        let summary = try add([OPMLFeed(title: "", feedURL: url)], to: context)
        guard summary.added == 1 else { return nil }
        let key = FeedURL.canonicalKey(for: url)
        return try context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.canonicalKey == key })).first
    }
}
