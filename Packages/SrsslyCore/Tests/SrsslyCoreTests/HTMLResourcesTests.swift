import Foundation
import Testing
@testable import SrsslyCore

@Suite struct HTMLParsingTests {
    let page = URL(string: "https://comic.test/strip/")!

    @Test func readsQuotedUnquotedAndEncodedAttributes() {
        let html = #"<IMG SRC=a.png alt='A "b"' title="x &amp; y" hidden><p>t</p>"#
        #expect(HTMLResources.scan(html, baseURL: page).images == [
            ImageReference(url: URL(string: "https://comic.test/strip/a.png")!, alt: "A \"b\"", title: "x & y"),
        ])
    }

    @Test func ignoresCommentsScriptsAndStyles() {
        let html = """
        <!-- <img src="comment.png"> -->
        <script>document.write('<img src="script.png">')</script>
        <style>.a { background: url(style.png) }</style>
        <img src="real.png"/>
        """
        #expect(HTMLResources.scan(html, baseURL: page).images.map(\.url.lastPathComponent) == ["real.png"])
    }

    @Test func survivesBrokenMarkup() {
        let html = #"a < b <img src="x.png" <p>unterminated <img src="y"#
        #expect(HTMLResources.scan(html, baseURL: page).images.first?.url.lastPathComponent == "x.png")
    }

    @Test func countsVisibleTextOnly() {
        #expect(HTMLResources.visibleTextLength("<p>Hi <b>there</b></p><script>var x = 1</script>") == 7)
        #expect(HTMLResources.visibleTextLength("<p>héllo</p>") == 5)
        #expect(HTMLResources.visibleTextLength("") == 0)
    }
}

@Suite struct HTMLResourcesTests {
    let page = URL(string: "https://comic.test/2026/11/24/strip/")!

    @Test func resolvesImagesAndKeepsHoverText() {
        let html = """
        <img src="/comics/today.png" title="The hover text" alt="Today">
        <img src="//cdn.comic.test/b.jpg">
        <img src="/comics/today.png">
        """
        let resources = HTMLResources.scan(html, baseURL: page)
        #expect(resources.images == [
            ImageReference(url: URL(string: "https://comic.test/comics/today.png")!, alt: "Today", title: "The hover text"),
            ImageReference(url: URL(string: "https://cdn.comic.test/b.jpg")!),
        ])
    }

    @Test func prefersLargestSrcsetAndLazySources() {
        let html = """
        <img src="small.jpg" srcset="small.jpg 400w, big.jpg 1600w, medium.jpg 800w">
        <img src="placeholder.gif" data-src="lazy.jpg">
        <picture><source srcset="a.webp 1x, a@2x.webp 2x"><img src="a.jpg"></picture>
        """
        let urls = HTMLResources.scan(html, baseURL: page).images.map(\.url.lastPathComponent)
        #expect(urls == ["big.jpg", "lazy.jpg", "a@2x.webp", "a.jpg"])
    }

    @Test func dropsTrackersAndNonHTTP() {
        let html = """
        <img src="https://feeds.feedburner.com/~r/Comic/~4/abc" height="1" width="1">
        <img src="https://pixel.wp.com/b.gif?x=1">
        <img src="https://example.test/p.gif" width="1" height="1">
        <img src="data:image/png;base64,AAAA">
        <img src="javascript:alert(1)">
        <img src="ok.png">
        """
        #expect(HTMLResources.scan(html, baseURL: page).images.map(\.url.lastPathComponent) == ["ok.png"])
    }

    @Test func findsStylesheetsBaseAndPreview() {
        let html = """
        <head><base href="https://other.test/root/">
        <link rel="stylesheet" href="site.css"><link rel="icon" href="fav.ico">
        <meta property="og:image" content="https://other.test/og.png">
        </head><img src="i.png">
        """
        let resources = HTMLResources.scan(html, baseURL: page)
        #expect(resources.stylesheets == [URL(string: "https://other.test/root/site.css")!])
        #expect(resources.previewImage == URL(string: "https://other.test/og.png")!)
        #expect(resources.images.map(\.url) == [URL(string: "https://other.test/root/i.png")!])
        #expect(resources.downloadURLs == [URL(string: "https://other.test/root/i.png")!, URL(string: "https://other.test/root/site.css")!])
    }
}

@Suite struct CacheModeDetectorTests {
    let link = URL(string: "https://site.test/post")!

    @Test func comicsWithImagesInTheFeedUseFeedContent() {
        let items = (0..<5).map { ParsedItem(guid: "\($0)", link: link, summaryHTML: #"<img src="https://site.test/c\#($0).png">"#) }
        #expect(CacheModeDetector.detect(items) == .feedContent)
    }

    @Test func fullTextUsesFeedContent() {
        let body = "<p>" + String(repeating: "word ", count: 200) + "</p>"
        #expect(CacheModeDetector.detect([ParsedItem(link: link, contentHTML: body)]) == .feedContent)
    }

    @Test func teasersNeedTheFullPage() {
        let items = (0..<4).map { ParsedItem(guid: "\($0)", link: link, summaryHTML: "A new comic is up! <a href=\"x\">Read more</a>") }
        #expect(CacheModeDetector.detect(items) == .fullPage)
    }

    @Test func itemsWithoutLinksHaveNothingToFetch() {
        #expect(CacheModeDetector.detect([ParsedItem(title: "Note", summaryHTML: "short")]) == .feedContent)
        #expect(CacheModeDetector.detect([]) == .feedContent)
    }

    @Test func imageEnclosuresCount() {
        let item = ParsedItem(link: link, summaryHTML: "Short", enclosures: [Enclosure(url: URL(string: "https://site.test/c.jpg")!, mimeType: "image/jpeg")])
        #expect(CacheModeDetector.hasContent(item))
    }

    @Test func effectiveModeHonoursTheSubscription() {
        #expect(CacheModeDetector.effectiveMode(.automatic, detected: .fullPage) == .fullPage)
        #expect(CacheModeDetector.effectiveMode(.feedContent, detected: .fullPage) == .feedContent)
        #expect(CacheModeDetector.effectiveMode(.extractedArticle, detected: .feedContent) == .fullPage)
    }
}

@Suite struct OfflineFileNameTests {
    @Test func stableNamesWithSafeExtensions() {
        let a = OfflineFileName.resource(URL(string: "https://x.test/a/comic.PNG?v=1")!)
        #expect(a.hasSuffix(".png"))
        #expect(a == OfflineFileName.resource(URL(string: "https://x.test/a/comic.PNG?v=1")!))
        #expect(a != OfflineFileName.resource(URL(string: "https://x.test/a/comic.PNG?v=2")!))
        #expect(!OfflineFileName.resource(URL(string: "https://x.test/image")!).contains("."))
        #expect(!OfflineFileName.resource(URL(string: "https://x.test/a.toolongext")!).contains("."))
        #expect(OfflineFileName.page(articleKey: "k:1").hasSuffix(".html"))
    }
}

@Suite struct SiteRulesTests {
    @Test func matchesHostsAndSubdomains() {
        let rule = SiteRules.rule(article: URL(string: "https://www.smbc-comics.com/comic/2026-11-24"), feed: nil)
        #expect(rule?.name == "SMBC")
        #expect(SiteRules.rule(article: URL(string: "https://what-if.xkcd.com/1/"), feed: nil)?.name == "xkcd")
        #expect(SiteRules.rule(article: URL(string: "https://notxkcd.com/1"), feed: nil) == nil)
        #expect(SiteRules.rule(article: nil, feed: URL(string: "https://www.lfg.co/feed"))?.cacheMode == .fullPage)
        #expect(SiteRules.rule(article: URL(string: "https://example.test/"), feed: URL(string: "https://example.test/rss")) == nil)
    }

    @Test func findsSMBCComicHoverTextAndBonusPanel() throws {
        let html = """
        <div id="cc-comicbody"><img title="The hover text." src="https://www.smbc-comics.com/comics/1764000000-20261124.png" id="cc-comic" /></div>
        <div id="aftercomic" onclick='toggleBlock("aftercomic")' style="display:none;" class="mobilehide">
          <img src='/comics/1764000000-20261124after.png'>
        </div>
        <img src="/images/ad.png">
        """
        let rule = try #require(SiteRules.builtIn.first { $0.name == "SMBC" })
        let images = SiteRules.pageImages(html, pageURL: URL(string: "https://www.smbc-comics.com/comic/today")!, selectors: rule.pageImageSelectors)
        #expect(images == [
            ImageReference(url: URL(string: "https://www.smbc-comics.com/comics/1764000000-20261124.png")!, title: "The hover text."),
            ImageReference(url: URL(string: "https://www.smbc-comics.com/comics/1764000000-20261124after.png")!),
        ])
    }

    @Test func siteRuleSitsBetweenSubscriptionAndDetection() {
        #expect(CacheModeDetector.effectiveMode(.automatic, siteRule: .fullPage, detected: .feedContent) == .fullPage)
        #expect(CacheModeDetector.effectiveMode(.feedContent, siteRule: .fullPage, detected: .feedContent) == .feedContent)
        #expect(CacheModeDetector.effectiveMode(.automatic, siteRule: nil, detected: .fullPage) == .fullPage)
    }
}
