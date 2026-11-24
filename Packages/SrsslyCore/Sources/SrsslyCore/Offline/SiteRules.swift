import Foundation
import SwiftSoup

/// Special handling for one site, where generic feed handling misses
/// something people care about.
public struct SiteRule: Sendable, Equatable {
    public var name: String
    /// Hosts this rule covers, without `www.`. Subdomains match too.
    public var hosts: [String]
    /// Overrides cache-mode detection (the subscription's own setting still
    /// wins). For feeds that include only a thumbnail of the real content.
    public var cacheMode: CacheMode?
    /// CSS selectors for images on the article's page that the feed leaves
    /// out, such as SMBC's red-button bonus panel. When set, the page is
    /// fetched for these even if the feed's content is otherwise enough.
    public var pageImageSelectors: [String]
    /// Whether images' `title` text is part of the content (hover text),
    /// so the reader shows it on tap or as a caption. iOS has no hover.
    public var showsImageTitles: Bool

    public init(
        name: String, hosts: [String], cacheMode: CacheMode? = nil,
        pageImageSelectors: [String] = [], showsImageTitles: Bool = false
    ) {
        self.name = name
        self.hosts = hosts
        self.cacheMode = cacheMode
        self.pageImageSelectors = pageImageSelectors
        self.showsImageTitles = showsImageTitles
    }

    public func matches(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

public enum SiteRules {
    public static let builtIn: [SiteRule] = [
        // Hover text is in the feed's <img title>.
        SiteRule(name: "xkcd", hosts: ["xkcd.com"], showsImageTitles: true),
        // The comic and its hover text are on the page (#cc-comic); the
        // red-button bonus panel is a hidden image under #aftercomic that
        // the feed never includes.
        SiteRule(
            name: "SMBC", hosts: ["smbc-comics.com"],
            pageImageSelectors: ["#cc-comic", "#aftercomic img"], showsImageTitles: true
        ),
        // Feeds that carry only a thumbnail or teaser of the comic.
        SiteRule(name: "The Oatmeal", hosts: ["theoatmeal.com"], cacheMode: .fullPage),
        SiteRule(name: "Looking For Group", hosts: ["lfg.co"], cacheMode: .fullPage),
        SiteRule(name: "Penny Arcade", hosts: ["penny-arcade.com"], cacheMode: .fullPage),
        SiteRule(name: "Tapas", hosts: ["tapas.io", "tapastic.com"], cacheMode: .fullPage),
        SiteRule(name: "Photoshop Phriday", hosts: ["somethingawful.com"], cacheMode: .fullPage),
    ]

    /// The rule for an article: by its link, else by its feed's URL (for
    /// feeds served from FeedBurner and the like that link through).
    public static func rule(article link: URL?, feed: URL?, rules: [SiteRule] = builtIn) -> SiteRule? {
        for url in [link, feed].compactMap({ $0 }) {
            if let rule = rules.first(where: { $0.matches(url) }) { return rule }
        }
        return nil
    }

    /// The images on a page that match the rule's selectors, in page order,
    /// with relative URLs resolved.
    public static func pageImages(_ html: String, pageURL: URL, selectors: [String]) -> [ImageReference] {
        guard !selectors.isEmpty, let doc = try? SwiftSoup.parse(html, pageURL.absoluteString),
              let elements = try? doc.select(selectors.joined(separator: ", "))
        else { return [] }
        var seen = Set<URL>()
        return elements.compactMap { element -> ImageReference? in
            guard element.tagNameNormal() == "img" else { return nil }
            let attr = { (name: String) -> String? in
                guard element.hasAttr(name), let value = try? element.attr(name) else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard let url = HTMLResources.imageURL(attr, base: pageURL), seen.insert(url).inserted else { return nil }
            return ImageReference(url: url, alt: attr("alt"), title: attr("title"))
        }
    }
}
