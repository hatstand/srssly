/// How an article is kept for offline reading.
public enum CacheMode: String, Codable, CaseIterable, Sendable {
    /// Pick a mode from what the feed provides (the default).
    case automatic
    /// The feed's own content is enough, e.g. full-text blogs and most comics.
    case feedContent
    /// Download the linked page and extract the article text and images.
    case extractedArticle
    /// Archive the whole linked page, e.g. comics whose feed only links out.
    case fullPage
}
