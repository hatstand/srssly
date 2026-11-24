import Foundation
import Testing
@testable import SrsslyCore

@Suite struct OPMLTests {
    @Test func parsesFeedlyExportWithFolders() throws {
        // Same shape as the Feedly export.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
            <head><title>John subscriptions in feedly Cloud</title></head>
            <body>
                <outline text="Comics" title="Comics">
                    <outline type="rss" text="xkcd" title="xkcd" xmlUrl="http://www.xkcd.com/rss.xml" htmlUrl="https://xkcd.com/"/>
                    <outline type="rss" text="Darths &amp; Droids" title="Darths &amp; Droids" xmlUrl="http://darthsanddroids.net/rss.xml" htmlUrl="http://www.darthsanddroids.net/"/>
                </outline>
                <outline text="Nested" title="Nested">
                    <outline text="Inner"><outline type="rss" text="Deep" xmlUrl="https://deep.test/feed"/></outline>
                </outline>
                <outline type="rss" text="Google Alerts - clementine player" title="Google Alerts - clementine player" xmlUrl="http://www.google.com/alerts/feeds/1/2"/>
                <outline text="Empty folder"/>
            </body>
        </opml>
        """
        let feeds = try OPML.parse(Data(xml.utf8))
        #expect(feeds.map(\.title) == ["xkcd", "Darths & Droids", "Deep", "Google Alerts - clementine player"])
        #expect(feeds.map(\.folder) == ["Comics", "Comics", "Nested", nil])
        #expect(feeds[0].feedURL == URL(string: "http://www.xkcd.com/rss.xml"))
        #expect(feeds[0].siteURL == URL(string: "https://xkcd.com/"))
        #expect(feeds[3].siteURL == nil)
    }

    @Test func usesTextWhenTitleMissing() throws {
        let feeds = try OPML.parse(Data(#"<opml><body><outline text="Only text" xmlUrl="https://a.test/feed"/></body></opml>"#.utf8))
        #expect(feeds.first?.title == "Only text")
    }

    @Test func rejectsNonOPML() {
        #expect(throws: OPMLError.notOPML) { try OPML.parse(Data("<rss><channel/></rss>".utf8)) }
        #expect(throws: (any Error).self) { try OPML.parse(Data("nope".utf8)) }
    }
}
