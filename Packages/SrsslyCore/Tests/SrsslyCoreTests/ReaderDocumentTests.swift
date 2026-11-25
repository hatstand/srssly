import Foundation
import SwiftSoup
import Testing
@testable import SrsslyCore

@Suite struct ReaderDocumentTests {
    let link = URL(string: "https://comic.test/1/")!
    let noCache: ReaderDocument.CacheLookup = { _ in nil }

    private func parse(_ html: String) throws -> Document { try SwiftSoup.parse(html) }

    @Test func wrapsFeedContentWithEscapedHeader() throws {
        let html = ReaderDocument.feedContent(
            .init(title: "Cats & <Dogs>", byline: "Feed · today", link: link, html: "<p>Body</p>"),
            cached: noCache
        )
        let doc = try parse(html)
        #expect(try doc.select("h1.srssly-title").text() == "Cats & <Dogs>")
        #expect(try doc.select("p.srssly-byline").text() == "Feed · today")
        #expect(try doc.select("#srssly-content p").text() == "Body")
    }

    @Test func pointsCachedImagesAtTheCacheAndResolvesTheRest() throws {
        let cached: ReaderDocument.CacheLookup = { $0.lastPathComponent == "a.png" ? "abc.png" : nil }
        let html = ReaderDocument.feedContent(
            .init(title: "T", byline: "", link: link, html: #"<img src="/a.png" srcset="/a.png 1x"><img data-src="b.png" src="placeholder.gif" loading="lazy">"#),
            cached: cached
        )
        let imgs = try parse(html).select("img").array()
        #expect(try imgs[0].attr("src") == "srssly-cache://resource/abc.png")
        #expect(!imgs[0].hasAttr("srcset"))
        #expect(try imgs[1].attr("src") == "https://comic.test/1/b.png")
        #expect(!imgs[1].hasAttr("loading"))
    }

    @Test func showsHoverTextAsCaptionsWhenTheSiteUsesIt() throws {
        let item = ReaderDocument.Item(
            title: "xkcd", byline: "", link: link,
            html: #"<a href="https://xkcd.com/1/"><img src="https://imgs.xkcd.test/c.png" title="Hover text" alt="Alt"></a>"#,
            showsImageTitles: true
        )
        let doc = try parse(ReaderDocument.feedContent(item, cached: noCache))
        let caption = try #require(try doc.select("p.srssly-hover-text").first())
        #expect(try caption.text() == "Hover text")
        #expect(caption.parent()?.id() == "srssly-content", "caption goes after the link, not inside it")

        var plain = item
        plain.showsImageTitles = false
        #expect(try parse(ReaderDocument.feedContent(plain, cached: noCache)).select("p.srssly-hover-text").isEmpty())
    }

    @Test func appendsPageExtrasAndBorrowsTheirHoverText() throws {
        let comic = URL(string: "https://www.smbc-comics.com/comics/today.png")!
        let bonus = URL(string: "https://www.smbc-comics.com/comics/todayafter.png")!
        let item = ReaderDocument.Item(
            title: "SMBC", byline: "", link: link,
            html: #"<img src="https://www.smbc-comics.com/comics/today.png">"#,
            extraImages: [ImageReference(url: comic, title: "Page hover text"), ImageReference(url: bonus)],
            showsImageTitles: true
        )
        let doc = try parse(ReaderDocument.feedContent(item, cached: { $0 == bonus ? "bonus.png" : nil }))
        let imgs = try doc.select("img").array()
        #expect(imgs.count == 2, "the feed's comic isn't repeated")
        #expect(try imgs[0].attr("title") == "Page hover text")
        #expect(try doc.select("p.srssly-hover-text").text() == "Page hover text")
        #expect(try doc.select("figure.srssly-extra img").attr("src") == "srssly-cache://resource/bonus.png")
    }

    @Test func removesScriptsAndHandlers() throws {
        let html = ReaderDocument.feedContent(
            .init(title: "T", byline: "", link: link, html: #"<p onclick="evil()">Hi</p><script>evil()</script><a href="javascript:evil()">x</a>"#),
            cached: noCache
        )
        let doc = try parse(html)
        #expect(try doc.select("script").isEmpty())
        #expect(try doc.select("[onclick]").isEmpty())
        #expect(try doc.select("a").attr("href") == "")
    }

    @Test func savedPagesAreKeptToTheScreenWidth() throws {
        let html = #"<html><head><link rel="stylesheet" href="/site.css"></head><body><img src="/hero.png" width="4608"></body></html>"#
        let doc = try parse(ReaderDocument.savedPage(html, pageURL: link, cached: noCache))
        let style = try #require(try doc.select("head > style#srssly-fit").first())
        #expect(try style.data().contains("max-width: 100%"))
        #expect(doc.head()?.children().last() === style, "after the site's own CSS, so it wins")
    }

    @Test func savedPagesUseCachedStylesheetsAndImages() throws {
        let page = URL(string: "https://news.test/story")!
        let cached: ReaderDocument.CacheLookup = { url in
            ["s.css": "s1.css", "hero.jpg": "h1.jpg", "big.webp": "b1.webp"][url.lastPathComponent]
        }
        let html = """
        <html><head><link rel="Stylesheet" href="/s.css"><script>track()</script></head>
        <body><img src="hero.jpg"><picture><source srcset="small.webp 1x, big.webp 2x"><img src="x.jpg"></picture></body></html>
        """
        let doc = try parse(ReaderDocument.savedPage(html, pageURL: page, cached: cached))
        #expect(try doc.select("link").attr("href") == "srssly-cache://resource/s1.css")
        #expect(try doc.select("img").first()?.attr("src") == "srssly-cache://resource/h1.jpg")
        #expect(try doc.select("source").attr("srcset") == "srssly-cache://resource/b1.webp")
        #expect(try doc.select("img").last()?.attr("src") == "https://news.test/x.jpg")
        #expect(try doc.select("script").isEmpty())
        #expect(try !doc.select("meta[name=viewport]").isEmpty())
    }

    @Test func cacheURLsRoundTrip() {
        let url = ReaderDocument.cacheURL(fileName: "abc.png")
        #expect(ReaderDocument.fileName(from: url) == "abc.png")
        #expect(ReaderDocument.fileName(from: URL(string: "srssly-cache://resource/..")!) == nil)
        #expect(ReaderDocument.fileName(from: URL(string: "https://resource/abc.png")!) == nil)
    }
}
