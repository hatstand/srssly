import Foundation
import Testing
@testable import SrsslyCore

// Fixtures are trimmed copies of the shapes used by feeds in the Feedly export.

@Suite struct FeedParserTests {
    private func parse(_ xml: String, url: String = "https://example.com/feed") throws -> ParsedFeed {
        try FeedParser.parse(Data(xml.utf8), url: URL(string: url)!)
    }

    @Test func rss2ComicWithHoverTextInEscapedHTML() throws {
        // xkcd: the comic and its title (hover) text are in an escaped description.
        let feed = try parse("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0"><channel>
          <title>xkcd.com</title><link>https://xkcd.com/</link>
          <description>xkcd.com: A webcomic</description>
          <item>
            <title>Orbital Mechanics</title>
            <link>https://xkcd.com/3001/</link>
            <description>&lt;img src="https://imgs.xkcd.com/comics/orbital.png" title="Hover &amp;amp; text" alt="Orbital" /&gt;</description>
            <pubDate>Mon, 23 Nov 2026 05:00:00 -0000</pubDate>
            <guid>https://xkcd.com/3001/</guid>
          </item>
        </channel></rss>
        """, url: "https://xkcd.com/rss.xml")
        #expect(feed.format == .rss2)
        #expect(feed.title == "xkcd.com")
        #expect(feed.siteURL == URL(string: "https://xkcd.com/"))
        let item = try #require(feed.items.first)
        #expect(item.title == "Orbital Mechanics")
        #expect(item.link == URL(string: "https://xkcd.com/3001/"))
        #expect(item.guid == "https://xkcd.com/3001/")
        #expect(item.summaryHTML?.contains(#"title="Hover &amp; text""#) == true)
        #expect(item.published == Date(timeIntervalSince1970: 1_795_410_000))
    }

    @Test func rss2WithContentEncodedCreatorAndEnclosure() throws {
        let feed = try parse("""
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
             xmlns:dc="http://purl.org/dc/elements/1.1/"
             xmlns:atom="http://www.w3.org/2005/Atom">
        <channel>
          <title>The Old New Thing</title>
          <atom:link href="https://devblogs.microsoft.com/oldnewthing/feed/" rel="self" type="application/rss+xml"/>
          <link>https://devblogs.microsoft.com/oldnewthing</link>
          <image><title>Image title</title><url>https://x/logo.png</url><link>https://x</link></image>
          <item>
            <title>Why is the sky blue?</title>
            <link>/oldnewthing/20261120-00/?p=1</link>
            <dc:creator><![CDATA[Raymond Chen]]></dc:creator>
            <pubDate>Fri, 20 Nov 2026 15:00:00 GMT</pubDate>
            <guid isPermaLink="false">https://devblogs.microsoft.com/oldnewthing/?p=111</guid>
            <description><![CDATA[<p>Short summary</p>]]></description>
            <content:encoded><![CDATA[<p>The whole <b>post</b>.</p>]]></content:encoded>
            <enclosure url="https://x/audio.mp3" length="1234" type="audio/mpeg"/>
          </item>
        </channel></rss>
        """, url: "https://devblogs.microsoft.com/oldnewthing/feed/")
        #expect(feed.title == "The Old New Thing")
        let item = try #require(feed.items.first)
        #expect(item.author == "Raymond Chen")
        #expect(item.summaryHTML == "<p>Short summary</p>")
        #expect(item.contentHTML == "<p>The whole <b>post</b>.</p>")
        #expect(item.link == URL(string: "https://devblogs.microsoft.com/oldnewthing/20261120-00/?p=1"))
        #expect(item.enclosures == [Enclosure(url: URL(string: "https://x/audio.mp3")!, mimeType: "audio/mpeg", length: 1234)])
    }

    @Test func nonPermalinkGuidIsNotUsedAsLink() throws {
        let feed = try parse("""
        <rss version="2.0"><channel><title>T</title>
          <item><title>A</title><guid isPermaLink="false">https://example.com/tag/123</guid></item>
          <item><title>B</title><guid>https://example.com/posts/b</guid></item>
        </channel></rss>
        """)
        #expect(feed.items[0].link == nil)
        #expect(feed.items[1].link == URL(string: "https://example.com/posts/b"))
    }

    @Test func atomWithHTMLAndXHTMLContent() throws {
        let feed = try parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title type="text">Project Zero</title>
          <link rel="self" href="https://googleprojectzero.blogspot.com/feeds/posts/default"/>
          <link rel="alternate" type="text/html" href="https://googleprojectzero.blogspot.com/"/>
          <author><name>Feed Author</name></author>
          <entry>
            <id>tag:blogger.com,1999:blog-1.post-2</id>
            <published>2026-11-10T09:30:00.000-08:00</published>
            <updated>2026-11-11T10:00:00Z</updated>
            <title type="text">A bug</title>
            <content type="html">&lt;p&gt;Exploit &lt;i&gt;details&lt;/i&gt;&lt;/p&gt;</content>
            <link rel="replies" href="https://x/comments"/>
            <link rel="alternate" type="text/html" href="https://googleprojectzero.blogspot.com/2026/11/a-bug.html"/>
            <author><name>Jann</name></author>
          </entry>
          <entry>
            <id>urn:uuid:2</id>
            <updated>2026-11-12T00:00:00Z</updated>
            <title>Inline</title>
            <link href="/2026/11/inline.html"/>
            <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Hello <a href="https://x">world</a> &amp; co</p></div></summary>
          </entry>
        </feed>
        """, url: "https://googleprojectzero.blogspot.com/feeds/posts/default")
        #expect(feed.format == .atom)
        #expect(feed.title == "Project Zero")
        #expect(feed.siteURL == URL(string: "https://googleprojectzero.blogspot.com/"))
        #expect(feed.items.count == 2)

        let first = feed.items[0]
        #expect(first.guid == "tag:blogger.com,1999:blog-1.post-2")
        #expect(first.link == URL(string: "https://googleprojectzero.blogspot.com/2026/11/a-bug.html"))
        #expect(first.contentHTML == "<p>Exploit <i>details</i></p>")
        #expect(first.author == "Jann")
        #expect(first.published == Date(timeIntervalSince1970: 1_794_331_800))
        #expect(first.updated != nil)

        let second = feed.items[1]
        #expect(second.link == URL(string: "https://googleprojectzero.blogspot.com/2026/11/inline.html"))
        #expect(second.published == nil)
        #expect(second.date == second.updated)
        #expect(second.summaryHTML == #"<div><p>Hello <a href="https://x">world</a> &amp; co</p></div>"#)
    }

    @Test func rss1RDFWithDublinCoreDates() throws {
        // VG Cats and A Softer World use RSS 1.0.
        let feed = try parse("""
        <?xml version="1.0"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns="http://purl.org/rss/1.0/"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel rdf:about="http://www.vgcats.com/">
            <title>VG Cats</title><link>http://www.vgcats.com/</link>
            <items><rdf:Seq><rdf:li rdf:resource="http://www.vgcats.com/comics/?strip_id=400"/></rdf:Seq></items>
          </channel>
          <item rdf:about="http://www.vgcats.com/comics/?strip_id=400">
            <title>Strip 400</title>
            <link>http://www.vgcats.com/comics/?strip_id=400</link>
            <dc:date>2026-10-01T12:00:00+00:00</dc:date>
            <dc:creator>Scott</dc:creator>
          </item>
        </rdf:RDF>
        """, url: "http://www.vgcats.com/vgcats.rdf.xml")
        #expect(feed.format == .rss1)
        #expect(feed.title == "VG Cats")
        let item = try #require(feed.items.first)
        #expect(item.title == "Strip 400")
        #expect(item.link == URL(string: "http://www.vgcats.com/comics/?strip_id=400"))
        #expect(item.published == Date(timeIntervalSince1970: 1_790_856_000))
        #expect(item.author == "Scott")
    }

    @Test func htmlPageIsRecognised() {
        let html = "<!DOCTYPE html><html><head><title>Site</title></head><body></body></html>"
        #expect(throws: FeedParseError.htmlPage) { try parse(html) }
    }

    @Test func nonFeedXMLIsRejected() {
        #expect(throws: FeedParseError.unrecognizedFormat(rootElement: "urlset")) {
            try parse(#"<?xml version="1.0"?><urlset><url><loc>x</loc></url></urlset>"#)
        }
    }

    @Test func garbageIsMalformed() {
        #expect(throws: (any Error).self) { try parse("this is not xml at all") }
    }

    @Test func truncatedFeedKeepsCompleteItems() throws {
        let feed = try parse("""
        <rss version="2.0"><channel><title>T</title>
          <item><title>Complete</title><guid>1</guid></item>
          <item><title>Cut off
        """)
        #expect(feed.items.map(\.title) == ["Complete"])
    }
}

@Suite struct FeedDatesTests {
    let dates = FeedDates()

    @Test(arguments: [
        ("Mon, 23 Nov 2026 05:00:00 -0000", 1_795_410_000.0),
        ("Mon, 23 Nov 2026 05:00:00 GMT", 1_795_410_000.0),
        ("Mon, 23 Nov 2026 05:00:00 UT", 1_795_410_000.0),
        ("Mon, 23 Nov 2026 00:00:00 EST", 1_795_410_000.0),
        ("Mon, 23 Nov 2026 05:00 +0000", 1_795_410_000.0),
        ("23 Nov 2026 05:00:00 +0000", 1_795_410_000.0),
        ("2026-11-23T05:00:00Z", 1_795_410_000.0),
        ("2026-11-23T05:00:00.123Z", 1_795_410_000.123),
        ("2026-11-23T06:00:00+01:00", 1_795_410_000.0),
        ("2026-11-23T05:00:00", 1_795_410_000.0),
        ("  2026-11-23T05:00:00Z \n", 1_795_410_000.0),
    ])
    func parses(raw: String, expected: Double) throws {
        let d = try #require(dates.parse(raw))
        #expect(abs(d.timeIntervalSince1970 - expected) < 0.01)
    }

    @Test func rejectsNonsense() {
        #expect(dates.parse("") == nil)
        #expect(dates.parse("yesterday") == nil)
    }
}

@Suite struct FeedDiscoveryTests {
    @Test func findsAlternateFeedLinks() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/rss.xml">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://www.happyassassin.net/atom.xml?a=1&amp;b=2'>
        <link type="application/rss+xml" rel="alternate home" href="/rss.xml">
        <link rel="alternate" hreflang="fr" type="text/html" href="/fr/">
        </head></html>
        """
        let links = FeedDiscovery.feedLinks(inHTML: html, baseURL: URL(string: "https://www.happyassassin.net/feed/")!)
        #expect(links == [
            URL(string: "https://www.happyassassin.net/rss.xml")!,
            URL(string: "https://www.happyassassin.net/atom.xml?a=1&b=2")!,
        ])
    }

    @Test func detectsHTML() {
        #expect(FeedDiscovery.looksLikeHTML(Data("\n  <!DOCTYPE html>\n<html>".utf8)))
        #expect(FeedDiscovery.looksLikeHTML(Data("<html lang=en>".utf8)))
        #expect(!FeedDiscovery.looksLikeHTML(Data(#"<?xml version="1.0"?><rss>"#.utf8)))
    }
}
