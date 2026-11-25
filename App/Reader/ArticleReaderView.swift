import SrsslyCore
import SrsslyStore
import SwiftData
import SwiftUI

/// Opening an article from a list: the articles that list showed, in its
/// order, and where to start. The list is copied when opened, so marking
/// articles read doesn't pull them out from under the reader when the list
/// is filtered to unread.
struct ReaderRoute: Hashable {
    var keys: [String]
    var start: String
}

/// Reads the articles of a list one at a time, swiping left for the next
/// (older) one and right for the previous. Each article is marked read as
/// it comes on screen.
struct ArticlePager: View {
    let route: ReaderRoute
    let subscriptions: [Subscription]

    @Environment(\.modelContext) private var context
    @State private var current: String?
    @State private var articles: [String: Article] = [:]
    @State private var showingWebPage = false

    init(route: ReaderRoute, subscriptions: [Subscription]) {
        self.route = route
        self.subscriptions = subscriptions
        // Starting here also makes the scroll view open on this page.
        _current = State(initialValue: route.start)
    }

    private var keys: [String] {
        var seen = Set<String>()
        return route.keys.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let article = current.flatMap { articles[$0] }
        ScrollView(.horizontal) {
            // Lazy, so only the pages near the current one exist.
            LazyHStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    Group {
                        if let page = articles[key] {
                            ArticleReaderView(
                                article: page,
                                subscription: subscription(for: page),
                                showingWebPage: showingWebPage && key == current
                            )
                        } else {
                            Color.clear
                        }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .bottom)
        .accessibilityIdentifier("reader-pager")
        .accessibilityValue(current ?? "")
        .navigationTitle(article.flatMap { subscription(for: $0)?.title } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let link = article?.link {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(
                        showingWebPage ? "Reader" : "Web Page",
                        systemImage: showingWebPage ? "doc.plaintext" : "safari"
                    ) { showingWebPage.toggle() }
                    ShareLink(item: link)
                }
            }
        }
        .onAppear {
            if articles.isEmpty { articles = fetchArticles() }
        }
        .onChange(of: current, initial: true) { _, key in
            // The next article opens as a reader, not the last one's web page.
            showingWebPage = false
            // Reading an article marks it read. Synced to other devices.
            if let key { try? ArticleStates.set(read: true, for: [key], in: context) }
        }
    }

    private func subscription(for article: Article) -> Subscription? {
        subscriptions.first { $0.id == article.subscriptionID }
    }

    private func fetchArticles() -> [String: Article] {
        let keys = route.keys
        let found = (try? context.fetch(FetchDescriptor<Article>(predicate: #Predicate { keys.contains($0.key) }))) ?? []
        return Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Reads one article: the saved page when there is one, else the feed's
/// content (with hover text and any extra images from site rules), all from
/// the offline cache where possible. `showingWebPage` shows the live site.
struct ArticleReaderView: View {
    let article: Article
    let subscription: Subscription?
    var showingWebPage = false

    @Environment(\.offlineCacher) private var offlineCacher
    @State private var content: ReaderWebView.Content?

    var body: some View {
        ReaderWebView(content: content ?? .html("", base: nil), cache: offlineCacher?.cache)
            .task(id: showingWebPage) { content = await makeContent() }
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
