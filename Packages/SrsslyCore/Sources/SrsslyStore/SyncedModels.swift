import Foundation
import SrsslyCore
import SwiftData

// Models in this file sync through CloudKit, which requires that every
// property is optional or has a default, that there are no unique
// constraints, and that relationships are optional. Keep it that way.
//
// Only small, user-authored state syncs. Articles are fetched by each device
// and live in the local store (see LocalModels.swift).

/// A feed the user subscribes to.
@Model
public final class Subscription {
    /// Stable across devices. Articles and read state refer to this.
    public var id: UUID = UUID()
    public var feedURLString: String = ""
    /// `FeedURL.canonicalKey` of the feed URL, for finding duplicates (CloudKit
    /// can't enforce uniqueness, and two devices may import the same OPML).
    public var canonicalKey: String = ""
    public var siteURLString: String?
    public var title: String = ""
    public var folder: String?
    public var addedAt: Date = Date.now
    public var sortIndex: Int = 0
    public var cacheModeRaw: String = CacheMode.automatic.rawValue

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
        set { cacheModeRaw = newValue.rawValue }
    }

    /// Point the subscription at a new feed URL, e.g. after a permanent redirect.
    public func updateFeedURL(_ url: URL) {
        feedURLString = url.absoluteString
        canonicalKey = FeedURL.canonicalKey(for: url)
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
    public var updatedAt: Date = Date.now

    public init(articleKey: String, isRead: Bool = false, isStarred: Bool = false) {
        self.articleKey = articleKey
        self.isRead = isRead
        self.isStarred = isStarred
    }
}
