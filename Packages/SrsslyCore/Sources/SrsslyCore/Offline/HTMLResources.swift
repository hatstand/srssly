import Foundation
import SwiftSoup

/// An image referenced from HTML.
public struct ImageReference: Sendable, Hashable {
    public var url: URL
    public var alt: String?
    /// The `title` attribute: the hover text on comics such as xkcd.
    public var title: String?

    public init(url: URL, alt: String? = nil, title: String? = nil) {
        self.url = url
        self.alt = alt
        self.title = title
    }
}

/// The resources an HTML document needs to display offline.
public struct HTMLResources: Sendable, Equatable {
    /// Images in document order, without duplicates or tracking pixels.
    public var images: [ImageReference]
    public var stylesheets: [URL]
    /// The page's `og:image` or `twitter:image`, for thumbnails.
    public var previewImage: URL?

    public init(images: [ImageReference] = [], stylesheets: [URL] = [], previewImage: URL? = nil) {
        self.images = images
        self.stylesheets = stylesheets
        self.previewImage = previewImage
    }

    /// Everything to download, images first.
    public var downloadURLs: [URL] {
        var seen = Set<URL>()
        return (images.map(\.url) + stylesheets).filter { seen.insert($0).inserted }
    }

    /// Lists the images and stylesheets in `html`, resolving relative URLs
    /// against the document's `<base href>` or `baseURL`. Never fails: broken
    /// HTML parses as a browser would, and unparseable input has no resources.
    public static func scan(_ html: String, baseURL: URL?) -> HTMLResources {
        guard let doc = try? SwiftSoup.parse(html, baseURL?.absoluteString ?? ""),
              let elements = try? doc.select("base[href], img, source, link[rel][href], meta[content]")
        else { return HTMLResources() }

        var base = baseURL
        var result = HTMLResources()
        var seenImages = Set<URL>()
        var seenStyles = Set<URL>()
        var sawBase = false
        for element in elements {
            let attr = { (name: String) -> String? in
                guard element.hasAttr(name), let value = try? element.attr(name) else { return nil }
                return value
            }
            switch element.tagNameNormal() {
            case "base":
                // Only the first <base> counts, as in browsers.
                guard !sawBase else { continue }
                sawBase = true
                if let href = attr("href"), let url = resolve(href, against: baseURL) { base = url }
            case "img", "source":
                guard !isTrackingPixel(attr), let url = imageURL(attr, base: base), !isTracker(url) else { continue }
                if seenImages.insert(url).inserted {
                    result.images.append(ImageReference(url: url, alt: nonEmpty(attr("alt")), title: nonEmpty(attr("title"))))
                }
            case "link":
                let rel = (attr("rel") ?? "").lowercased().split(separator: " ")
                guard rel.contains("stylesheet"), let href = attr("href"), let url = resolve(href, against: base) else { continue }
                if seenStyles.insert(url).inserted { result.stylesheets.append(url) }
            case "meta":
                let key = (attr("property") ?? attr("name") ?? "").lowercased()
                guard key == "og:image" || key == "twitter:image", result.previewImage == nil,
                      let content = attr("content") else { continue }
                result.previewImage = resolve(content, against: base)
            default:
                break
            }
        }
        return result
    }

    /// Roughly how many visible characters the HTML has, ignoring
    /// whitespace, scripts and styles. Tells a full post from a teaser.
    public static func visibleTextLength(_ html: String) -> Int {
        guard let doc = try? SwiftSoup.parseBodyFragment(html), let text = try? doc.text() else { return 0 }
        return text.filter { !$0.isWhitespace }.count
    }

    // MARK: - Helpers

    /// The best URL for an image: the largest `srcset` candidate, else the
    /// lazy-loading attributes, else `src` (which lazy loaders often point
    /// at a placeholder).
    static func imageURL(_ attr: (String) -> String?, base: URL?) -> URL? {
        if let srcset = attr("srcset") ?? attr("data-srcset"), let best = largestCandidate(srcset), let url = resolve(best, against: base) {
            return url
        }
        for attribute in ["data-src", "data-lazy-src", "data-original", "src"] {
            if let value = attr(attribute), let url = resolve(value, against: base) { return url }
        }
        return nil
    }

    /// Picks the candidate with the biggest width or density descriptor.
    static func largestCandidate(_ srcset: String) -> String? {
        var best: (url: String, size: Double)?
        for candidate in srcset.split(separator: ",") {
            let parts = candidate.split(whereSeparator: \.isWhitespace)
            guard let url = parts.first else { continue }
            var size = 1.0
            if parts.count > 1, let descriptor = parts.last, let unit = descriptor.last, unit == "w" || unit == "x" {
                size = Double(descriptor.dropLast()) ?? 1
            }
            if best == nil || size > best!.size { best = (String(url), size) }
        }
        return best?.url
    }

    static func resolve(_ value: String, against base: URL?) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func isTrackingPixel(_ attr: (String) -> String?) -> Bool {
        attr("width")?.trimmingCharacters(in: .whitespaces) == "1" && attr("height")?.trimmingCharacters(in: .whitespaces) == "1"
    }

    /// FeedBurner and similar services append tracking images to every item.
    private static func isTracker(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        if host.hasSuffix("feedburner.com"), path.hasPrefix("/~r/") || path.hasPrefix("/~ff/") { return true }
        if host.hasSuffix("feedsportal.com") || host == "pixel.wp.com" || host == "stats.wordpress.com" { return true }
        return false
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
