import SrsslyCore
import SrsslyStore
import SwiftUI

/// Reads one article: the saved page when there is one, else the feed's
/// content (with hover text and any extra images from site rules), all from
/// the offline cache where possible. "Web Page" switches to the live site.
struct ArticleReaderView: View {
    let article: Article
    let subscription: Subscription?

    @Environment(\.offlineCacher) private var offlineCacher
    @Environment(\.modelContext) private var context
    @State private var showingWebPage = false
    @State private var content: ReaderWebView.Content?

    var body: some View {
        ReaderWebView(content: content ?? .html("", base: nil), cache: offlineCacher?.cache)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(subscription?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let link = article.link {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(
                            showingWebPage ? "Reader" : "Web Page",
                            systemImage: showingWebPage ? "doc.plaintext" : "safari"
                        ) { showingWebPage.toggle() }
                        ShareLink(item: link)
                    }
                }
            }
            .task(id: showingWebPage) { content = await makeContent() }
            .onAppear {
                // Opening an article reads it. Synced to other devices.
                try? ArticleStates.set(read: true, for: [article.key], in: context)
            }
    }

    /// Builds the reader HTML off the main actor; parsing a big page can
    /// take a moment.
    private func makeContent() async -> ReaderWebView.Content {
        let link = article.link
        if showingWebPage, let link { return .url(link) }

        let cache = offlineCacher?.cache
        let savedPage = article.offlinePageFile.flatMap { cache?.page(named: $0) }
        let rule = SiteRules.rule(article: link, feed: subscription?.feedURL)
        let byline = [subscription?.title, article.publishedAt.formatted(date: .abbreviated, time: .shortened)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let item = ReaderDocument.Item(
            title: article.title, byline: byline, link: link,
            html: article.contentHTML ?? article.summaryHTML,
            extraImages: article.extraImages, showsImageTitles: rule?.showsImageTitles ?? false
        )
        return await Task.detached(priority: .userInitiated) {
            let lookup: ReaderDocument.CacheLookup = { url in
                guard let cache, cache.hasResource(url) else { return nil }
                return OfflineFileName.resource(url)
            }
            if let savedPage, let link {
                return .html(ReaderDocument.savedPage(String(decoding: savedPage, as: UTF8.self), pageURL: link, cached: lookup), base: link)
            }
            return .html(ReaderDocument.feedContent(item, cached: lookup), base: link)
        }.value
    }
}
