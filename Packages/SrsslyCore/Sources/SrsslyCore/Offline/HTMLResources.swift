import Foundation

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
    /// against the document's `<base href>` or `baseURL`.
    public static func scan(_ html: String, baseURL: URL?) -> HTMLResources {
        let tags = HTMLScanner.tags(in: html, named: ["base", "img", "source", "link", "meta"])
        var base = baseURL
        if let href = tags.first(where: { $0.name == "base" })?["href"], let url = resolve(href, against: baseURL) {
            base = url
        }

        var result = HTMLResources()
        var seenImages = Set<URL>()
        var seenStyles = Set<URL>()
        for tag in tags {
            switch tag.name {
            case "img", "source":
                guard !isTrackingPixel(tag), let url = imageURL(tag, base: base), !isTracker(url) else { continue }
                if seenImages.insert(url).inserted {
                    result.images.append(ImageReference(url: url, alt: nonEmpty(tag["alt"]), title: nonEmpty(tag["title"])))
                }
            case "link":
                let rel = (tag["rel"] ?? "").lowercased().split(separator: " ")
                guard rel.contains("stylesheet"), let href = tag["href"], let url = resolve(href, against: base) else { continue }
                if seenStyles.insert(url).inserted { result.stylesheets.append(url) }
            case "meta":
                let key = (tag["property"] ?? tag["name"] ?? "").lowercased()
                guard key == "og:image" || key == "twitter:image", result.previewImage == nil,
                      let content = tag["content"] else { continue }
                result.previewImage = resolve(content, against: base)
            default:
                break
            }
        }
        return result
    }

    // MARK: - Helpers

    /// The best URL for an image: the largest `srcset` candidate, else the
    /// lazy-loading attributes, else `src` (which lazy loaders often point
    /// at a placeholder).
    static func imageURL(_ tag: HTMLTag, base: URL?) -> URL? {
        if let srcset = tag["srcset"] ?? tag["data-srcset"], let best = largestCandidate(srcset), let url = resolve(best, against: base) {
            return url
        }
        for attribute in ["data-src", "data-lazy-src", "data-original", "src"] {
            if let value = tag[attribute], let url = resolve(value, against: base) { return url }
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

    private static func isTrackingPixel(_ tag: HTMLTag) -> Bool {
        tag["width"]?.trimmingCharacters(in: .whitespaces) == "1" && tag["height"]?.trimmingCharacters(in: .whitespaces) == "1"
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
