import Foundation
import SrsslyCore
import SwiftData

// Models in this file are synced by `CloudSync` as the CloudKit record types
// in docs/cloudkit-schema.md. When adding a synced field, add it there and in
// CloudRecords.swift, and set `modifiedAt` whenever the user changes something
// (last writer wins).
//
// Only small, user-authored state syncs. Articles are fetched by each device
// and live in the local store (see LocalModels.swift).

/// A feed the user subscribes to.
@Model
public final class Subscription {
    /// Stable across devices. Articles and read state refer to this.
    public var id: UUID = UUID()
    public var feedURLString: String = ""
    /// `FeedURL.canonicalKey` of the feed URL, for finding duplicates (two
    /// devices may import the same OPML). Derived locally, not synced.
    public var canonicalKey: String = ""
    public var siteURLString: String?
    public var title: String = ""
    public var folder: String?
    public var addedAt: Date = Date.now
    public var sortIndex: Int = 0
    public var cacheModeRaw: String = CacheMode.automatic.rawValue
    /// When this was last changed on any device; decides sync conflicts.
    public var modifiedAt: Date = Date.now
    /// The CloudKit record's system fields (change tag etc.), archived.
    public var cloudKitSystemFields: Data?

    public init(feedURL: URL, title: String, folder: String? = nil, siteURL: URL? = nil) {
        self.feedURLString = feedURL.absoluteString
        self.canonicalKey = FeedURL.canonicalKey(for: feedURL)
        self.title = title
        self.folder = folder
        self.siteURLString = siteURL?.absoluteString
    }

    public var feedURL: URL? { URL(string: feedURLString) }
    public var siteURL: URL? { siteURLString.flatMap(URL.init(string:)) }

    public var cacheMode: CacheMode {
        get { CacheMode(rawValue: cacheModeRaw) ?? .automatic }
        set {
            cacheModeRaw = newValue.rawValue
            modifiedAt = .now
        }
    }

    /// Point the subscription at a new feed URL, e.g. after a permanent redirect.
    public func updateFeedURL(_ url: URL) {
        feedURLString = url.absoluteString
        canonicalKey = FeedURL.canonicalKey(for: url)
        modifiedAt = .now
    }
}

/// Read and starred state for one article, keyed by `ArticleKey`.
///
/// Rows only exist for articles the user has touched, so the synced data stays
/// small even with thousands of fetched articles.
@Model
public final class ArticleState {
    public var articleKey: String = ""
    public var isRead: Bool = false
    public var isStarred: Bool = false
    /// When this was last changed on any device; decides sync conflicts.
    public var updatedAt: Date = Date.now
    /// The CloudKit record's system fields (change tag etc.), archived.
    public var cloudKitSystemFields: Data?

    public init(articleKey: String, isRead: Bool = false, isStarred: Bool = false) {
        self.articleKey = articleKey
        self.isRead = isRead
        self.isStarred = isStarred
    }
}
