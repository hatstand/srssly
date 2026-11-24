import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses RSS 2.0, RSS 1.0 (RDF) and Atom feeds.
///
/// Lenient by design: it takes what it can from each item and ignores
/// elements it doesn't know. Relative links are resolved against the feed's
/// URL.
public enum FeedParser {
    public static func parse(_ data: Data, url: URL? = nil) throws(FeedParseError) -> ParsedFeed {
        if FeedDiscovery.looksLikeHTML(data) { throw .htmlPage }
        let delegate = ParserDelegate(baseURL: url)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let error = delegate.error { throw error }
        guard let feed = delegate.feed else {
            if !ok {
                throw .malformed(parser.parserError?.localizedDescription ?? "unknown error")
            }
            throw .unrecognizedFormat(rootElement: delegate.rootElement ?? "")
        }
        // Keep what was parsed even if the document is truncated or has a
        // stray error after the items (common with hand-rolled feeds).
        return feed
    }
}

private enum NS {
    static let atom = "http://www.w3.org/2005/Atom"
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let rss1 = "http://purl.org/rss/1.0/"
    static let content = "http://purl.org/rss/1.0/modules/content/"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let media = "http://search.yahoo.com/mrss/"
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    let baseURL: URL?
    let dates = FeedDates()

    var rootElement: String?
    var feed: ParsedFeed?
    var error: FeedParseError?

    private var text = ""
    private var item: ParsedItem?
    private var inAuthor = false
    private var inImageOrTextInput = 0
    private var guidIsPermaLink = true

    // Atom `type="xhtml"` content is inline XML; re-serialise it.
    private var xhtmlDepth = 0
    private var xhtml = ""
    private var xhtmlTarget: String?

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    private func resolve(_ s: String?) -> URL? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let url = URL(string: s, relativeTo: baseURL)?.absoluteURL { return url }
        let escaped = s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? s
        return URL(string: escaped, relativeTo: baseURL)?.absoluteURL
    }

    private func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI ns: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        let ns = ns ?? ""

        if xhtmlDepth > 0 {
            xhtmlDepth += 1
            let attrs = attributes.map { " \($0.key)=\"\(escape($0.value))\"" }.sorted().joined()
            xhtml += "<\(name)\(attrs)>"
            return
        }

        if rootElement == nil {
            rootElement = name
            switch (name, ns) {
            case ("rss", _): feed = ParsedFeed(format: .rss2)
            case ("RDF", NS.rdf): feed = ParsedFeed(format: .rss1)
            case ("feed", NS.atom): feed = ParsedFeed(format: .atom)
            case ("html", _), ("HTML", _):
                error = .htmlPage
                parser.abortParsing()
            default:
                error = .unrecognizedFormat(rootElement: name)
                parser.abortParsing()
            }
            return
        }

        text = ""

        switch (name, ns) {
        case ("item", ""), ("item", NS.rss1), ("entry", NS.atom):
            item = ParsedItem()
            guidIsPermaLink = true
        case ("image", ""), ("image", NS.rss1), ("textInput", _), ("textinput", _):
            inImageOrTextInput += 1
        case ("author", NS.atom):
            inAuthor = true
        case ("guid", ""):
            guidIsPermaLink = attributes["isPermaLink"]?.lowercased() != "false"
        case ("link", NS.atom):
            let rel = attributes["rel"] ?? "alternate"
            guard rel == "alternate", let href = resolve(attributes["href"]) else { break }
            if item != nil {
                if item?.link == nil { item?.link = href }
            } else if feed?.siteURL == nil {
                feed?.siteURL = href
            }
        case ("enclosure", ""), ("content", NS.media):
            if let url = resolve(attributes["url"]) {
                item?.enclosures.append(Enclosure(
                    url: url,
                    mimeType: attributes["type"],
                    length: (attributes["length"] ?? attributes["fileSize"]).flatMap(Int.init)
                ))
            }
        case ("content", NS.atom), ("summary", NS.atom):
            if attributes["type"] == "xhtml" {
                xhtmlDepth = 1
                xhtml = ""
                xhtmlTarget = name
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if xhtmlDepth > 0 { xhtml += escape(string) } else { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        let s = String(decoding: data, as: UTF8.self)
        if xhtmlDepth > 0 { xhtml += s } else { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI ns: String?, qualifiedName: String?) {
        let ns = ns ?? ""

        if xhtmlDepth > 0 {
            xhtmlDepth -= 1
            if xhtmlDepth > 0 {
                xhtml += "</\(name)>"
                return
            }
            // Closed the atom:content/summary element itself. Atom wraps
            // xhtml in a <div>; keep it, it's harmless.
            let html = nonEmpty(xhtml)
            if xhtmlTarget == "content" { item?.contentHTML = html } else { item?.summaryHTML = html }
            xhtmlTarget = nil
            text = ""
            return
        }

        let value = text
        text = ""

        if inImageOrTextInput > 0 {
            if ["image", "textInput", "textinput"].contains(name) { inImageOrTextInput -= 1 }
            return
        }

        if item != nil {
            endItemElement(name, ns, value)
        } else {
            endChannelElement(name, ns, value)
        }
    }

    private func endItemElement(_ name: String, _ ns: String, _ value: String) {
        switch (name, ns) {
        case ("item", ""), ("item", NS.rss1), ("entry", NS.atom):
            if var done = item {
                if done.link == nil, guidIsPermaLink, let guid = done.guid, guid.hasPrefix("http") {
                    done.link = resolve(guid)
                }
                feed?.items.append(done)
            }
            item = nil
        case ("title", _) where ns != NS.media:
            item?.title = nonEmpty(value)
        case ("link", ""), ("link", NS.rss1):
            item?.link = resolve(value) ?? item?.link
        case ("guid", ""), ("id", NS.atom):
            item?.guid = nonEmpty(value)
        case ("description", ""), ("description", NS.rss1), ("summary", NS.atom):
            item?.summaryHTML = nonEmpty(value)
        case ("encoded", NS.content), ("content", NS.atom):
            item?.contentHTML = nonEmpty(value)
        case ("pubDate", ""), ("published", NS.atom), ("issued", NS.atom):
            item?.published = dates.parse(value) ?? item?.published
        case ("date", NS.dc):
            if item?.published == nil { item?.published = dates.parse(value) }
        case ("updated", NS.atom), ("modified", NS.atom):
            item?.updated = dates.parse(value)
        case ("creator", NS.dc), ("author", ""):
            if item?.author == nil { item?.author = nonEmpty(value) }
        case ("name", NS.atom) where inAuthor:
            if item?.author == nil { item?.author = nonEmpty(value) }
        case ("author", NS.atom):
            inAuthor = false
        default:
            break
        }
    }

    private func endChannelElement(_ name: String, _ ns: String, _ value: String) {
        switch (name, ns) {
        case ("title", ""), ("title", NS.rss1), ("title", NS.atom):
            if feed?.title == nil { feed?.title = nonEmpty(value) }
        case ("link", ""), ("link", NS.rss1):
            if feed?.siteURL == nil { feed?.siteURL = resolve(value) }
        case ("author", NS.atom):
            inAuthor = false
        default:
            break
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
