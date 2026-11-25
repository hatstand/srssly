import Foundation
import SwiftSoup

/// Pulls the article out of a web page, leaving the site's navigation,
/// banners, menus, share buttons and footers behind.
///
/// A small take on Mozilla's Readability: paragraphs score their ancestors,
/// the best-scoring container (less its share of link text) is the
/// article, and its content is cleaned of leftover chrome. The result is
/// an HTML fragment with absolute URLs that the reader styles itself, so it
/// reads the same on every site and follows dark mode.
public enum ArticleExtractor {
    /// Starts a saved page that holds an extracted article rather than the
    /// whole web page.
    public static let marker = "<!-- srssly:extracted-article -->\n"

    public struct Article: Sendable, Equatable {
        /// The article's content: an HTML fragment with absolute URLs.
        public var html: String
        /// The page's title, if it had one.
        public var title: String?
    }

    /// Visible characters below which extraction counts as a failure (the
    /// page is probably a teaser, a paywall or a single-page app shell).
    public static let minimumTextLength = 250

    /// The article in `html`, or nil if nothing on the page looks like one.
    public static func extract(_ html: String, pageURL: URL) -> Article? {
        guard let doc = try? SwiftSoup.parse(html, pageURL.absoluteString), let body = doc.body() else { return nil }
        do {
            let title = pageTitle(doc)
            try removeChrome(body)
            guard let root = try topCandidate(body) else { return nil }
            let content = try assemble(root, doc: doc)
            try clean(content, title: title)
            try absolutize(content, base: pageURL)
            if let lead = leadImage(doc, base: pageURL), try !startsWithImage(content) {
                try content.prependElement("img").attr("src", lead.absoluteString)
            }
            let text = try content.text().filter { !$0.isWhitespace }
            guard text.count >= minimumTextLength else { return nil }
            return Article(html: try content.html(), title: title)
        } catch {
            return nil
        }
    }

    /// The saved-page form of an extracted article.
    public static func savedPage(_ article: Article) -> Data {
        Data((marker + article.html).utf8)
    }

    /// The article fragment from a saved page, or nil if the page is a
    /// whole web page.
    public static func fragment(fromSavedPage page: String) -> String? {
        page.hasPrefix(marker) ? String(page.dropFirst(marker.count)) : nil
    }

    // MARK: - Finding the article

    private static let unlikely = try! NSRegularExpression(
        pattern: "-ad-|ai2html|banner|breadcrumbs|combx|comment|community|cover-wrap|disqus|extra|footer|gdpr|header|legends|menu|related|remark|replies|rss|shoutbox|sidebar|skyscraper|social|sponsor|supplemental|ad-break|agegate|pagination|pager|popup|yom-remote|navbar|nav-|cookie|newsletter|subscribe|signup|promo",
        options: .caseInsensitive
    )
    private static let maybe = try! NSRegularExpression(pattern: "and|article|body|column|content|main|shadow|prose|post|entry|story", options: .caseInsensitive)
    private static let positive = try! NSRegularExpression(
        pattern: "article|body|content|entry|hentry|h-entry|main|page|pagination|post|prose|text|blog|story",
        options: .caseInsensitive
    )
    private static let negative = try! NSRegularExpression(
        pattern: "-ad-|hidden|^hid$| hid$| hid |^hid |banner|combx|comment|com-|contact|footer|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|widget|author|byline|newsletter|subscribe|cta",
        options: .caseInsensitive
    )

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func classAndID(_ e: Element) -> String {
        ((try? e.className()) ?? "") + " " + e.id()
    }

    /// Removes what is never the article: scripts, forms, navigation,
    /// hidden elements, and containers whose class or id says they're
    /// chrome.
    private static func removeChrome(_ body: Element) throws {
        try body.select("script, style, noscript, template, link, meta, iframe, object, embed, form, button, input, select, textarea, nav, aside, footer, dialog, svg, canvas").remove()
        try body.select("[role=navigation], [role=banner], [role=contentinfo], [role=complementary], [role=dialog], [role=menu], [aria-hidden=true], [hidden]").remove()
        for e in try body.select("[style]").array() {
            let style = (try e.attr("style")).replacingOccurrences(of: " ", with: "").lowercased()
            if style.contains("display:none") || style.contains("visibility:hidden") { try e.remove() }
        }
        for e in try body.getAllElements().array() where e !== body && e.parent() != nil {
            let tag = e.tagNameNormal()
            guard !["body", "a", "article", "main", "html"].contains(tag) else { continue }
            let id = classAndID(e)
            guard matches(unlikely, id), !matches(maybe, id), !hasAncestor(e, tags: ["table", "code", "pre"]) else { continue }
            try e.remove()
        }
    }

    private static func hasAncestor(_ e: Element, tags: Set<String>) -> Bool {
        var p = e.parent()
        while let node = p {
            if tags.contains(node.tagNameNormal()) { return true }
            p = node.parent()
        }
        return false
    }

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset", "figure", "footer",
        "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
        "section", "table", "ul",
    ]

    /// The element whose paragraphs make it the article.
    private static func topCandidate(_ body: Element) throws -> Element? {
        var scores: [ObjectIdentifier: Double] = [:]
        var elements: [ObjectIdentifier: Element] = [:]

        func initialise(_ e: Element) {
            let key = ObjectIdentifier(e)
            guard scores[key] == nil else { return }
            elements[key] = e
            var score = classWeight(e)
            switch e.tagNameNormal() {
            case "div", "article", "main": score += 5
            case "pre", "td", "blockquote": score += 3
            case "address", "ol", "ul", "dl", "dd", "dt", "li": score -= 3
            case "h1", "h2", "h3", "h4", "h5", "h6", "th": score -= 5
            default: break
            }
            scores[key] = score
        }

        for e in try body.select("p, pre, td, div, section").array() {
            // A div holding only text and inline elements is a paragraph.
            if ["div", "section"].contains(e.tagNameNormal()),
               e.children().array().contains(where: { blockTags.contains($0.tagNameNormal()) }) { continue }
            let text = try e.text()
            guard text.count >= 25 else { continue }
            let score = 1 + Double(text.split(separator: ",").count - 1) + min(Double(text.count) / 100, 3)
            var ancestor = e.parent()
            var level = 0
            while let a = ancestor, level < 5, a.tagNameNormal() != "html" {
                initialise(a)
                let divider: Double = level == 0 ? 1 : (level == 1 ? 2 : Double(level) * 3)
                scores[ObjectIdentifier(a)]! += score / divider
                ancestor = a.parent()
                level += 1
            }
        }

        var best: (element: Element, score: Double)?
        for (key, score) in scores {
            guard let e = elements[key] else { continue }
            let adjusted = score * (1 - linkDensity(e))
            scores[key] = adjusted
            if best == nil || adjusted > best!.score { best = (e, adjusted) }
        }
        guard var top = best?.element else { return nil }

        // A wrapper with nothing else in it is the same article, and its
        // siblings (a lead image, say) are worth considering.
        while let parent = top.parent(), parent.tagNameNormal() != "body",
              parent.children().size() == 1 {
            top = parent
        }
        return top
    }

    private static func classWeight(_ e: Element) -> Double {
        var weight = 0.0
        for part in [(try? e.className()) ?? "", e.id()] where !part.isEmpty {
            if matches(negative, part) { weight -= 25 }
            if matches(positive, part) { weight += 25 }
        }
        return weight
    }

    private static func linkDensity(_ e: Element) -> Double {
        let length = Double(((try? e.text()) ?? "").count)
        guard length > 0 else { return 0 }
        let links = ((try? e.select("a").array()) ?? []).reduce(0) { $0 + (((try? $1.text()) ?? "").count) }
        return Double(links) / length
    }

    /// The top candidate plus siblings that belong with it: a lead image
    /// just before it, or paragraphs split off into their own containers.
    private static func assemble(_ top: Element, doc: Document) throws -> Element {
        let container = try doc.createElement("div")
        guard let parent = top.parent(), parent.tagNameNormal() != "body" else {
            try container.appendChild(top)
            return container
        }
        let topClass = (try? top.className()) ?? ""
        let siblings = parent.children().array()
        let topIndex = siblings.firstIndex { $0 === top } ?? 0
        for (index, sibling) in siblings.enumerated() {
            if sibling === top {
                try container.appendChild(sibling)
                continue
            }
            let tag = sibling.tagNameNormal()
            let text = try sibling.text()
            var keep = false
            if !topClass.isEmpty, (try? sibling.className()) == topClass, text.count > 80 {
                keep = true
            } else if tag == "p", text.count > 80, linkDensity(sibling) < 0.25 {
                keep = true
            } else if index == topIndex - 1, try isLeadImage(sibling) {
                keep = true
            }
            if keep { try container.appendChild(sibling) }
        }
        return container
    }

    /// An image (or figure) with little text, that isn't an avatar or icon.
    private static func isLeadImage(_ e: Element) throws -> Bool {
        let images = try e.tagNameNormal() == "img" ? [e] : e.select("img").array()
        guard images.count == 1, try e.text().count < 200 else { return false }
        let width = Int((try? images[0].attr("width")) ?? "") ?? 0
        return width == 0 || width >= 300
    }

    // MARK: - Cleaning up

    private static func clean(_ content: Element, title: String?) throws {
        // The reader shows its own title. Sites append their name to
        // og:title, so the page's heading may be just the start of it.
        if let title = title.map(normalised), !title.isEmpty {
            // Only before the article's text starts.
            for e in try content.select("h1, h2, h3, div, p, span").array().prefix(40) {
                let text = normalised(try e.text())
                guard !text.isEmpty, try e.select("img").isEmpty() else { continue }
                if text == title || (text.count >= 10 && title.hasPrefix(text)) {
                    try e.remove()
                    break
                }
                if e.tagNameNormal() == "p" { break }
            }
        }
        try content.select("h1").tagName("h2")

        // Leftover lists of links, share bars and tiny boxes.
        for e in try content.select("div, section, header, ul, ol, table, figure").array().reversed() where e.parent() != nil {
            let text = try e.text()
            let images = try e.select("img").size()
            let paragraphs = try e.select("p").size()
            if classWeight(e) < 0, text.count < 500 {
                try e.remove()
            } else if images == 0, text.count < 25, try e.select("pre, code, hr, br, table").isEmpty() {
                try e.remove()
            } else if e.tagNameNormal() != "figure", linkDensity(e) > 0.5, paragraphs < 2 {
                try e.remove()
            } else if e.tagNameNormal() == "header", images == 0, paragraphs == 0, text.count < 200 {
                // A post's header: title, author, date, already shown.
                try e.remove()
            }
        }

        // Avatars and icons.
        for img in try content.select("img").array() {
            let width = Int((try? img.attr("width")) ?? "") ?? 0
            let height = Int((try? img.attr("height")) ?? "") ?? 0
            if (width > 0 && width < 64) || (height > 0 && height < 64) { try img.remove(); continue }
            let cls = ((try? img.className()) ?? "").lowercased() + " " + ((try? img.attr("src")) ?? "").lowercased()
            if cls.contains("avatar") || cls.contains("rounded-full") { try img.remove() }
        }

        // Site styling is gone, so presentational attributes only get in
        // the way (fixed widths are what make pages scroll sideways).
        for e in try content.getAllElements().array() {
            guard let attributes = e.getAttributes() else { continue }
            let isCode = e.tagNameNormal() == "code"
            for key in attributes.map({ $0.getKey() })
            where !keptAttributes.contains(key.lowercased()) && !(isCode && key == "class") && !key.hasPrefix("data-src") && key != "srcset" {
                try e.removeAttr(key)
            }
        }
    }

    private static let keptAttributes: Set<String> = [
        "href", "src", "alt", "title", "colspan", "rowspan", "start", "reversed", "type", "datetime", "lang", "dir", "cite",
    ]

    private static func absolutize(_ content: Element, base: URL) throws {
        for a in try content.select("a[href]").array() {
            let href = try a.attr("href")
            if href.hasPrefix("#") || href.lowercased().hasPrefix("javascript:") {
                try a.removeAttr("href")
            } else if let url = URL(string: href, relativeTo: base)?.absoluteURL {
                try a.attr("href", url.absoluteString)
            }
        }
        for img in try content.select("img").array() {
            let attr = { (name: String) -> String? in
                guard img.hasAttr(name), let value = try? img.attr(name) else { return nil }
                return value
            }
            if let url = HTMLResources.imageURL(attr, base: base) {
                try img.attr("src", url.absoluteString)
            } else {
                try img.remove()
                continue
            }
            for attribute in ["srcset", "data-src", "data-srcset", "data-lazy-src", "data-original", "loading", "sizes", "decoding", "data-nimg"] {
                try img.removeAttr(attribute)
            }
        }
        // <picture> sources would override the chosen image.
        try content.select("picture > source").remove()
    }

    /// The page's sharing image, which on most sites is the article's
    /// hero image, kept in a header the extraction leaves behind. Generic
    /// site images are skipped.
    private static func leadImage(_ doc: Document, base: URL) -> URL? {
        for selector in ["meta[property=og:image]", "meta[name=twitter:image]"] {
            guard let value = try? doc.select(selector).first()?.attr("content"),
                  let url = HTMLResources.resolve(value, against: base) else { continue }
            let path = url.path.lowercased()
            if ["default", "logo", "placeholder", "fallback", "og-image"].contains(where: path.contains) { return nil }
            return url
        }
        return nil
    }

    /// Whether an image comes before the first paragraph of text.
    private static func startsWithImage(_ content: Element) throws -> Bool {
        for e in try content.select("img, p").array() {
            if e.tagNameNormal() == "img" { return true }
            if try e.text().count > 40 { return false }
        }
        return false
    }

    private static func pageTitle(_ doc: Document) -> String? {
        for selector in ["meta[property=og:title]", "meta[name=twitter:title]"] {
            if let value = try? doc.select(selector).first()?.attr("content"), !value.isEmpty { return value }
        }
        if let h1 = try? doc.select("h1").first()?.text(), !h1.isEmpty { return h1 }
        return try? doc.title()
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
