import Foundation
import SwiftData

// Models in this file stay on the device. They are a cache of what the feeds
// returned and can be rebuilt by fetching again.

/// An item from a feed.
@Model
public final class Article {
    #Index<Article>([\.publishedAt], [\.subscriptionID, \.publishedAt])

    /// `ArticleKey` for this item; joins to the synced `ArticleState`.
    @Attribute(.unique) public var key: String
    public var subscriptionID: UUID
    public var guid: String?
    public var title: String
    public var linkString: String?
    public var author: String?
    public var publishedAt: Date
    public var summaryHTML: String?
    public var contentHTML: String?
    public var fetchedAt: Date

    public init(
        key: String,
        subscriptionID: UUID,
        guid: String?,
        title: String,
        link: URL?,
        author: String? = nil,
        publishedAt: Date,
        summaryHTML: String? = nil,
        contentHTML: String? = nil,
        fetchedAt: Date = .now
    ) {
        self.key = key
        self.subscriptionID = subscriptionID
        self.guid = guid
        self.title = title
        self.linkString = link?.absoluteString
        self.author = author
        self.publishedAt = publishedAt
        self.summaryHTML = summaryHTML
        self.contentHTML = contentHTML
        self.fetchedAt = fetchedAt
    }

    public var link: URL? { linkString.flatMap(URL.init(string:)) }
}

/// Per-device bookkeeping for fetching one subscription.
@Model
public final class FeedFetchState {
    @Attribute(.unique) public var subscriptionID: UUID
    /// Where the feed actually lives after following redirects.
    public var resolvedURLString: String?
    public var etag: String?
    public var lastModified: String?
    /// Hash of the last response body, for servers that ignore conditional GET
    /// (all the FeedBurner feeds do).
    public var contentHash: String?
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var lastError: String?
    public var consecutiveFailures: Int = 0

    public init(subscriptionID: UUID) {
        self.subscriptionID = subscriptionID
    }
}
