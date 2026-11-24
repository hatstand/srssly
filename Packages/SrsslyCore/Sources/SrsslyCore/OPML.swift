import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A feed listed in an OPML subscription list.
public struct OPMLFeed: Sendable, Equatable {
    public var title: String
    public var feedURL: URL
    public var siteURL: URL?
    /// The top-level folder it was in, if any. Nested folders flatten to the
    /// outermost one (Feedly only uses one level).
    public var folder: String?

    public init(title: String, feedURL: URL, siteURL: URL? = nil, folder: String? = nil) {
        self.title = title
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.folder = folder
    }
}

public enum OPMLError: Error, Equatable, Sendable {
    case malformed(String)
    case notOPML
}

public enum OPML {
    /// Feeds in document order. Outlines without an `xmlUrl` are folders.
    public static func parse(_ data: Data) throws(OPMLError) -> [OPMLFeed] {
        let delegate = OPMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if delegate.wrongRoot { throw .notOPML }
        guard delegate.sawRoot else {
            if !ok { throw .malformed(parser.parserError?.localizedDescription ?? "unknown error") }
            throw .notOPML
        }
        if !ok, delegate.feeds.isEmpty {
            throw .malformed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        return delegate.feeds
    }
}

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    var sawRoot = false
    var wrongRoot = false
    var feeds: [OPMLFeed] = []
    /// One entry per open <outline>: the folder title it opened, or nil.
    private var stack: [String?] = []

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        if !sawRoot {
            guard name.lowercased() == "opml" else {
                wrongRoot = true
                parser.abortParsing()
                return
            }
            sawRoot = true
            return
        }
        guard name == "outline" else { return }
        let title = (attributes["title"] ?? attributes["text"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = attributes["xmlUrl"] ?? attributes["xmlurl"],
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil {
            let folder = stack.compactMap { $0 }.first
            let site = (attributes["htmlUrl"] ?? attributes["htmlurl"]).flatMap { URL(string: $0) }
            feeds.append(OPMLFeed(title: title ?? url.host() ?? raw, feedURL: url, siteURL: site, folder: folder))
            stack.append(nil)
        } else {
            stack.append(title.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "outline", !stack.isEmpty { stack.removeLast() }
    }
}
