import Foundation
import SwiftSoup
import Testing
@testable import SrsslyCore

@Suite struct ArticleExtractorTests {
    let pageURL = URL(string: "https://blog.test/posts/netmap")!
    let paragraph = "<p>" + String(repeating: "Tailscale keeps working, even when the connection does not, which is nice. ", count: 4) + "</p>"

    /// A page like a modern blog's: banner, nav menus, a header with the
    /// title and author, the post, related posts and a footer.
    private var page: String {
        """
        <html><head>
        <title>Netmap caching | Blog</title>
        <meta property="og:title" content="Netmap caching">
        <meta property="og:image" content="https://cdn.test/hero.png">
        </head><body>
        <section class="sticky banner"><a href="/events">Visit us at ReInvent</a></section>
        <header class="site-header"><ul><li><a href="/blog">Blog</a></li><li><a href="/docs">Docs</a></li><li><a href="/download">Download</a></li></ul></header>
        <div class="menu"><a href="/a">How it works</a><a href="/b">Features</a><a href="/c">Integrations</a></div>
        <main>
          <div class="post-header"><h1>Netmap caching</h1><img class="avatar" src="/me.png" width="32" height="32">By Claus</div>
          <div class="blog-content-prose" style="width: 1200px">
            \(paragraph)
            <h2>How it works</h2>
            \(paragraph)
            <figure><img src="/diagram.png" srcset="/diagram.png 1x, /diagram@2x.png 2x" width="3840" loading="lazy"><figcaption>The diagram</figcaption></figure>
            <p>Read <a href="../docs/caching">the docs</a> or <a href="#top">go up</a>.</p>
            <script>alert(1)</script>
            <div class="share-buttons"><a href="https://x.test/share">Share</a></div>
          </div>
        </main>
        <div class="related-posts"><a href="/1">Another post</a><a href="/2">And another</a></div>
        <footer><a href="/privacy">Privacy</a></footer>
        </body></html>
        """
    }

    private func extracted() throws -> (ArticleExtractor.Article, Document) {
        let article = try #require(ArticleExtractor.extract(page, pageURL: pageURL))
        return (article, try SwiftSoup.parseBodyFragment(article.html))
    }

    @Test func keepsTheArticleAndDropsTheSiteAroundIt() throws {
        let (article, doc) = try extracted()
        let text = try doc.text()
        #expect(text.contains("Tailscale keeps working"))
        #expect(text.contains("How it works"))
        #expect(try doc.select("figcaption").text() == "The diagram")
        for chrome in ["ReInvent", "Download", "Integrations", "Another post", "Privacy", "Share"] {
            #expect(!text.contains(chrome), "\(chrome) is site chrome")
        }
        #expect(!article.html.contains("<script"))
        #expect(article.title == "Netmap caching")
    }

    @Test func dropsTheTitleAndAvatarTheReaderAlreadyShows() throws {
        let (_, doc) = try extracted()
        #expect(try doc.select("h1").isEmpty())
        #expect(try !doc.text().hasPrefix("Netmap caching"))
        #expect(try doc.select("img[src*=me.png]").isEmpty())
    }

    @Test func removesFixedWidthsSoThePageFitsTheScreen() throws {
        let (article, doc) = try extracted()
        #expect(!article.html.contains("1200px"))
        #expect(try doc.select("[width], [style], [class]").isEmpty())
    }

    @Test func makesLinksAndImagesAbsolute() throws {
        let (_, doc) = try extracted()
        #expect(try doc.select("a").first()?.attr("href") == "https://blog.test/docs/caching")
        #expect(try doc.select("a:not([href])").text() == "go up", "in-page anchors don't lead anywhere in the reader")
        let diagram = try #require(try doc.select("figure img").first())
        #expect(try diagram.attr("src") == "https://blog.test/diagram@2x.png")
        #expect(!diagram.hasAttr("srcset"))
        #expect(!diagram.hasAttr("loading"))
    }

    @Test func leadsWithTheSharingImageWhenTheArticleDoesNot() throws {
        let (_, doc) = try extracted()
        #expect(try doc.select("img").first()?.attr("src") == "https://cdn.test/hero.png")

        let generic = page.replacingOccurrences(of: "https://cdn.test/hero.png", with: "https://cdn.test/default-og-image.png")
        let article = try #require(ArticleExtractor.extract(generic, pageURL: pageURL))
        #expect(!article.html.contains("default-og-image"))
    }

    @Test func pagesWithoutAnArticleGiveNothing() {
        #expect(ArticleExtractor.extract(#"<div id="root">Loading…</div><nav><a href="/">Home</a></nav>"#, pageURL: pageURL) == nil)
        #expect(ArticleExtractor.extract("", pageURL: pageURL) == nil)
    }

    @Test func savedPagesRoundTrip() throws {
        let article = ArticleExtractor.Article(html: "<p>Hi</p>", title: nil)
        let saved = String(decoding: ArticleExtractor.savedPage(article), as: UTF8.self)
        #expect(ArticleExtractor.fragment(fromSavedPage: saved) == "<p>Hi</p>")
        #expect(ArticleExtractor.fragment(fromSavedPage: "<html><body><p>Hi</p></body></html>") == nil)
    }
}
