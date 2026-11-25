import SrsslyStore
import SwiftData
import SwiftUI

/// Newest articles across all subscriptions.
struct ArticleTimeline: View {
    let subscriptions: [Subscription]

    @Query(Self.descriptor) private var articles: [Article]
    @Query(filter: #Predicate<ArticleState> { $0.isRead }) private var readStates: [ArticleState]
    @Environment(\.feedRefresher) private var refresher

    /// Capped so the first frame never has to load the whole history.
    private static var descriptor: FetchDescriptor<Article> {
        var d = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        d.fetchLimit = 200
        return d
    }

    var body: some View {
        let titles = Dictionary(subscriptions.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let read = Set(readStates.map(\.articleKey))
        List(articles) { article in
            NavigationLink(value: article) {
                TimelineRow(
                    article: article,
                    feedTitle: titles[article.subscriptionID] ?? "",
                    isRead: read.contains(article.key)
                )
            }
            .accessibilityIdentifier("article-row")
        }
        .listStyle(.plain)
        .navigationDestination(for: Article.self) { article in
            ArticleReaderView(article: article, subscription: subscriptions.first { $0.id == article.subscriptionID })
        }
        .refreshable { await refresher?.refresh(force: true) }
        .overlay {
            if articles.isEmpty {
                ContentUnavailableView("Nothing Yet", systemImage: "tray", description: Text("New articles will appear here."))
            }
        }
    }
}

struct TimelineRow: View {
    let article: Article
    let feedTitle: String
    let isRead: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .lineLimit(3)
                HStack {
                    Text(feedTitle)
                    Spacer()
                    Text(article.publishedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
