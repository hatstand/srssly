import Foundation

/// Finds feeds advertised by an HTML page, for feed URLs that now serve the
/// site instead of the feed, and for adding a feed by its site address.
public enum FeedDiscovery {
    /// True when the bytes look like an HTML document rather than XML.
    public static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let start = head.drop(while: { $0 == "\u{feff}" })
        return start.hasPrefix("<!doctype html") || start.hasPrefix("<html")
    }

    /// Feed URLs from `<link rel="alternate" type="application/rss+xml" href=…>`
    /// (and Atom, RDF and JSON Feed types), in document order, resolved against
    /// `baseURL`.
    public static func feedLinks(inHTML html: String, baseURL: URL) -> [URL] {
        let feedTypes: Set<String> = [
            "application/rss+xml", "application/atom+xml", "application/rdf+xml",
            "application/feed+json", "application/json", "text/xml", "application/xml",
        ]
        var results: [URL] = []
        for tag in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let attrs = attributes(in: String(tag.output))
            guard
                let rel = attrs["rel"]?.lowercased().split(separator: " "), rel.contains("alternate"),
                let type = attrs["type"]?.lowercased(), feedTypes.contains(type),
                let href = attrs["href"], let url = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL
            else { continue }
            if !results.contains(url) { results.append(url) }
        }
        return results
    }

    private static func attributes(in tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
        for m in tag.matches(of: pattern) {
            let value = m.output.2 ?? m.output.3 ?? m.output.4 ?? ""
            attrs[String(m.output.1).lowercased()] = String(value)
        }
        return attrs
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
    }
}
