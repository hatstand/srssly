import Foundation

public enum FeedFormat: String, Sendable, Equatable {
    case rss2
    case rss1
    case atom
}

/// A feed as parsed from XML, before it touches the store.
public struct ParsedFeed: Sendable, Equatable {
    public var format: FeedFormat
    public var title: String?
    public var siteURL: URL?
    public var items: [ParsedItem]

    public init(format: FeedFormat, title: String? = nil, siteURL: URL? = nil, items: [ParsedItem] = []) {
        self.format = format
        self.title = title
        self.siteURL = siteURL
        self.items = items
    }
}

public struct ParsedItem: Sendable, Equatable {
    public var guid: String?
    public var title: String?
    public var link: URL?
    public var author: String?
    public var published: Date?
    public var updated: Date?
    /// RSS `description` or Atom `summary`. Often HTML.
    public var summaryHTML: String?
    /// RSS `content:encoded` or Atom `content`. Usually the full post when present.
    public var contentHTML: String?
    public var enclosures: [Enclosure]

    public init(
        guid: String? = nil, title: String? = nil, link: URL? = nil, author: String? = nil,
        published: Date? = nil, updated: Date? = nil, summaryHTML: String? = nil,
        contentHTML: String? = nil, enclosures: [Enclosure] = []
    ) {
        self.guid = guid
        self.title = title
        self.link = link
        self.author = author
        self.published = published
        self.updated = updated
        self.summaryHTML = summaryHTML
        self.contentHTML = contentHTML
        self.enclosures = enclosures
    }

    /// The best date to sort by.
    public var date: Date? { published ?? updated }
}

public struct Enclosure: Sendable, Equatable {
    public var url: URL
    public var mimeType: String?
    public var length: Int?

    public init(url: URL, mimeType: String? = nil, length: Int? = nil) {
        self.url = url
        self.mimeType = mimeType
        self.length = length
    }
}

public enum FeedParseError: Error, Equatable, Sendable {
    /// The document is an HTML page, not a feed. Look for a feed link in it
    /// with `FeedDiscovery` (some old feed URLs now redirect to the site).
    case htmlPage
    /// Well-formed XML, but not RSS or Atom.
    case unrecognizedFormat(rootElement: String)
    /// Not well-formed XML.
    case malformed(String)
}
