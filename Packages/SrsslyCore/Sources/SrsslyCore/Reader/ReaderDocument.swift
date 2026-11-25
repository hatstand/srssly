import Foundation
import SwiftSoup

/// Builds the HTML the reader shows, from a feed item or a saved page.
///
/// Images and stylesheets already in the offline cache are pointed at the
/// reader's `srssly-cache:` scheme, so articles read the same with or
/// without a network. Anything not cached keeps its web URL.
///
/// The reader runs with JavaScript off; scripts and inline event handlers
/// are removed anyway so nothing depends on them.
public enum ReaderDocument {
    public static let resourceScheme = "srssly-cache"

    /// The reader URL for a cached file.
    public static func cacheURL(fileName: String) -> URL {
        URL(string: "\(resourceScheme)://resource/\(fileName)")!
    }

    /// The cached file name a reader URL points to.
    public static func fileName(from url: URL) -> String? {
        guard url.scheme == resourceScheme, url.host == "resource" else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty || name.contains("/") || name.hasPrefix(".") ? nil : name
    }

    /// What the reader shows for a feed item.
    public struct Item: Sendable {
        public var title: String
        /// Feed name and date, already formatted.
        public var byline: String
        public var link: URL?
        public var html: String?
        /// Images from the page that the feed leaves out (site rules).
        public var extraImages: [ImageReference]
        /// Show image title text as captions (hover text on xkcd, SMBC).
        public var showsImageTitles: Bool

        public init(
            title: String, byline: String, link: URL?, html: String?,
            extraImages: [ImageReference] = [], showsImageTitles: Bool = false
        ) {
            self.title = title
            self.byline = byline
            self.link = link
            self.html = html
            self.extraImages = extraImages
            self.showsImageTitles = showsImageTitles
        }
    }

    /// Returns the cached file name for a remote URL, or nil if not cached.
    public typealias CacheLookup = (URL) -> String?

    /// A readable page from the feed's own content.
    public static func feedContent(_ item: Item, cached: CacheLookup) -> String {
        let template = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style></head><body>
        <header><h1 class="srssly-title"></h1><p class="srssly-byline"></p></header>
        <article id="srssly-content">\(item.html ?? "")</article>
        </body></html>
        """
        let base = item.link?.absoluteString ?? ""
        guard let doc = try? SwiftSoup.parse(template, base) else { return "" }
        do {
            try doc.select("h1.srssly-title").first()?.text(item.title)
            try doc.select("p.srssly-byline").first()?.text(item.byline)
            guard let content = try doc.select("#srssly-content").first() else { return try doc.outerHtml() }
            try sanitize(content)

            // Hover text from the page can fill in for a feed image without it.
            var titles: [URL: String] = [:]
            for extra in item.extraImages { if let t = extra.title { titles[extra.url] = t } }

            var present = Set<URL>()
            for img in try content.select("img") {
                guard let url = try rewriteImage(img, base: item.link, cached: cached) else { continue }
                present.insert(url)
                var title = nonEmpty(try? img.attr("title"))
                if title == nil, let t = titles[url] {
                    title = t
                    try img.attr("title", t)
                }
                if item.showsImageTitles, let title {
                    let caption = try doc.createElement("p")
                    try caption.addClass("srssly-hover-text")
                    try caption.text(title)
                    // After the link wrapping the image, if there is one.
                    let anchor = img.parent().flatMap { $0.tagNameNormal() == "a" ? $0 : nil } ?? img
                    try anchor.after(caption)
                }
            }

            for extra in item.extraImages where !present.contains(extra.url) {
                present.insert(extra.url)
                let figure = try content.appendElement("figure")
                try figure.addClass("srssly-extra")
                let img = try figure.appendElement("img")
                try img.attr("src", (cached(extra.url).map(cacheURL(fileName:)) ?? extra.url).absoluteString)
                if let alt = extra.alt { try img.attr("alt", alt) }
                if item.showsImageTitles, let title = extra.title {
                    try figure.appendElement("figcaption").text(title)
                }
            }
            return try doc.outerHtml()
        } catch {
            return (try? doc.outerHtml()) ?? ""
        }
    }

    /// A saved page, pointed at cached images and stylesheets.
    public static func savedPage(_ html: String, pageURL: URL, cached: CacheLookup) -> String {
        guard let doc = try? SwiftSoup.parse(html, pageURL.absoluteString) else { return html }
        do {
            if let root = doc.body()?.parent() { try sanitize(root) }
            for img in try doc.select("img") { _ = try rewriteImage(img, base: pageURL, cached: cached) }
            for source in try doc.select("source[srcset]") {
                let attr = attributeReader(source)
                if let best = attr("srcset").flatMap(HTMLResources.largestCandidate),
                   let url = HTMLResources.resolve(best, against: pageURL), let name = cached(url) {
                    try source.attr("srcset", cacheURL(fileName: name).absoluteString)
                }
            }
            for link in try doc.select("link[rel~=(?i)stylesheet][href]") {
                if let url = HTMLResources.resolve(try link.attr("href"), against: pageURL), let name = cached(url) {
                    try link.attr("href", cacheURL(fileName: name).absoluteString)
                }
            }
            if try doc.select("meta[name=viewport]").isEmpty() {
                try doc.head()?.appendElement("meta").attr("name", "viewport").attr("content", "width=device-width, initial-scale=1")
            }
            // Last, so it wins: whatever the site's CSS does (or if it never
            // loaded), keep the page to the screen's width so swiping
            // sideways moves between articles rather than across the page.
            try doc.head()?.appendElement("style").attr("id", "srssly-fit").append(fitToWidthCSS)
            return try doc.outerHtml()
        } catch {
            return (try? doc.outerHtml()) ?? html
        }
    }

    // MARK: - Helpers

    /// Points an image at its cached copy (or its resolved web URL), and
    /// drops lazy-loading and srcset attributes so that's what displays.
    /// Returns the image's web URL.
    @discardableResult
    static func rewriteImage(_ img: Element, base: URL?, cached: CacheLookup) throws -> URL? {
        guard let url = HTMLResources.imageURL(attributeReader(img), base: base) else { return nil }
        let src = cached(url).map(cacheURL(fileName:)) ?? url
        try img.attr("src", src.absoluteString)
        for attribute in ["srcset", "data-src", "data-srcset", "data-lazy-src", "data-original", "loading", "sizes"] {
            try img.removeAttr(attribute)
        }
        return url
    }

    private static func attributeReader(_ element: Element) -> (String) -> String? {
        { name in
            guard element.hasAttr(name), let value = try? element.attr(name) else { return nil }
            return value
        }
    }

    /// Removes scripts and inline event handlers.
    private static func sanitize(_ root: Element) throws {
        try root.select("script, noscript[data-srcset]").remove()
        for element in try root.getAllElements() {
            guard let attributes = element.getAttributes() else { continue }
            let handlers = attributes.map { $0.getKey() }.filter { $0.lowercased().hasPrefix("on") }
            for key in handlers { try element.removeAttr(key) }
            if let href = try? element.attr("href"), href.lowercased().hasPrefix("javascript:") {
                try element.removeAttr("href")
            }
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static let fitToWidthCSS = """
    html, body { max-width: 100% !important; overflow-x: hidden !important; }
    img, video, iframe, svg, canvas, table, pre { max-width: 100% !important; }
    img, video { height: auto !important; }
    pre { overflow-x: auto; }
    """

    static let css = """
    :root { color-scheme: light dark; }
    body { font: -apple-system-body; line-height: 1.5; margin: 0 auto; max-width: 42em;
           padding: 12px 20px 48px; -webkit-text-size-adjust: 100%; overflow-wrap: break-word; }
    .srssly-title { font: -apple-system-title1; font-weight: 700; margin: 0.4em 0 0.2em; }
    .srssly-byline { font: -apple-system-subheadline; color: #8e8e93; margin: 0 0 1.5em; }
    img, video, iframe { max-width: 100%; height: auto; }
    figure { margin: 1em 0; }
    .srssly-hover-text, figcaption { font: -apple-system-footnote; font-style: italic; color: #8e8e93;
           margin: 0.4em 0 1.4em; }
    html, body { overflow-x: hidden; }
    a { color: -apple-system-blue; }
    h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 0.5em; }
    h2 { font-size: 1.35em; } h3 { font-size: 1.15em; } h4 { font-size: 1em; }
    pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.875em; }
    pre { overflow-x: auto; padding: 0.8em; border-radius: 8px; background: #8e8e931f; }
    :not(pre) > code { padding: 0.1em 0.3em; border-radius: 4px; background: #8e8e931f; }
    table { display: block; overflow-x: auto; border-collapse: collapse; }
    td, th { padding: 0.3em 0.6em; border: 1px solid #8e8e9344; }
    hr { border: 0; border-top: 1px solid #8e8e9366; margin: 2em 0; }
    img { border-radius: 6px; }
    blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #8e8e9366; }
    """
}
