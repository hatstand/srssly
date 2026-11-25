import CryptoKit
import Foundation

/// Picks how to keep a feed's articles offline when its subscription is set
/// to `CacheMode.automatic`.
///
/// Most feeds either carry the whole post (full-text blogs, and most comics,
/// whose items are just the image) or only a teaser that links out. A feed
/// whose items mostly have real content is `.feedContent`; otherwise the
/// article is extracted from the linked page (`.extractedArticle`). Whole
/// pages (`.fullPage`) are only kept when a site rule or the subscription
/// asks for them, e.g. comics whose page *is* the content.
public enum CacheModeDetector {
    /// Visible characters above which an item counts as a full post.
    public static let fullTextThreshold = 500

    /// The mode for a feed, from its latest items.
    public static func detect(_ items: [ParsedItem]) -> CacheMode {
        let linked = items.filter { $0.link != nil }
        // Nothing to fetch: the feed's content is all there is.
        guard !linked.isEmpty else { return .feedContent }
        let complete = linked.filter(hasContent).count
        return complete * 2 >= linked.count ? .feedContent : .extractedArticle
    }

    /// The mode to use for an item: the subscription's choice; when that is
    /// automatic, a site rule's mode; else the mode detected from the feed.
    ///
    /// Detection used to say `.fullPage` for summary-only feeds; that is
    /// read as `.extractedArticle` until the feed is next refreshed.
    public static func effectiveMode(_ chosen: CacheMode, siteRule: CacheMode? = nil, detected: CacheMode) -> CacheMode {
        if chosen != .automatic { return chosen }
        if let siteRule { return siteRule }
        return detected == .fullPage ? .extractedArticle : detected
    }

    /// Whether an item's own HTML is worth reading on its own: long enough
    /// to be the post, or carrying an image (a comic).
    public static func hasContent(_ item: ParsedItem) -> Bool {
        let html = item.contentHTML ?? item.summaryHTML ?? ""
        if !HTMLResources.scan(html, baseURL: item.link).images.isEmpty { return true }
        if item.enclosures.contains(where: { $0.mimeType?.hasPrefix("image/") == true }) { return true }
        return HTMLResources.visibleTextLength(html) >= fullTextThreshold
    }
}

/// File names for the offline cache: stable, safe on any file system, and
/// the same for the same URL so shared images download once.
public enum OfflineFileName {
    /// The name for a downloaded resource. Keeps a short extension so the
    /// file's type is obvious when serving it.
    public static func resource(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let safeExt = ext.count <= 5 && !ext.isEmpty && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? "." + ext : ""
        return hash(url.absoluteString) + safeExt
    }

    /// The name for an article's saved page.
    public static func page(articleKey: String) -> String {
        hash(articleKey) + ".html"
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
