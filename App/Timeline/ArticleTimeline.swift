import SrsslyStore
import SwiftData
import SwiftUI

enum TimelineFilter: String, CaseIterable, Identifiable {
    case all, unread, starred
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .starred: "Starred"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .unread: "circle.fill"
        case .starred: "star.fill"
        }
    }
}

/// Newest articles across all subscriptions, or from one.
struct ArticleTimeline: View {
    let subscriptions: [Subscription]

    @Query private var articles: [Article]
    /// Only touched articles have a state, so this stays small.
    @Query private var states: [ArticleState]
    @Environment(\.feedRefresher) private var refresher
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    // Read articles are hidden unless the menu says otherwise.
    @AppStorage("timelineFilter") private var filter: TimelineFilter = .unread
    /// Articles that were read when the unread list last settled; only these
    /// are hidden. One read since then (in the reader or by swiping) stays
    /// listed, dimmed, so rows don't vanish from under a swipe and coming
    /// back from the reader keeps your place. The list settles when it first
    /// appears, on pull to refresh, on changing the filter, after Mark All as
    /// Read, from the menu's Hide Read, and on leaving the app.
    @State private var hiddenRead: Set<String>?

    init(subscriptions: [Subscription], only subscriptionID: UUID? = nil) {
        self.subscriptions = subscriptions
        var d = FetchDescriptor<Article>(
            predicate: subscriptionID.map { id in #Predicate<Article> { $0.subscriptionID == id } },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        // Capped so the first frame never has to load the whole history.
        d.fetchLimit = 500
        _articles = Query(d)
    }

    var body: some View {
        let titles = Dictionary(subscriptions.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let read = Set(states.lazy.filter(\.isRead).map(\.articleKey))
        let starred = Set(states.lazy.filter(\.isStarred).map(\.articleKey))
        let hidden = hiddenRead ?? read
        let shown = articles.filter { article in
            switch filter {
            case .all: true
            case .unread: !(read.contains(article.key) && hidden.contains(article.key))
            case .starred: starred.contains(article.key)
            }
        }
        let shownKeys = shown.map(\.key)
        List(shown) { article in
            let isRead = read.contains(article.key)
            let isStarred = starred.contains(article.key)
            NavigationLink(value: ReaderRoute(keys: shownKeys, start: article.key)) {
                TimelineRow(
                    article: article,
                    feedTitle: titles[article.subscriptionID] ?? "",
                    isRead: isRead,
                    isStarred: isStarred
                )
            }
            .accessibilityIdentifier("article-row")
            .swipeActions(edge: .leading) {
                Button(isRead ? "Unread" : "Read", systemImage: isRead ? "circle.fill" : "circle") {
                    update(read: !isRead, keys: [article.key])
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing) {
                Button(isStarred ? "Unstar" : "Star", systemImage: isStarred ? "star.slash" : "star") {
                    update(starred: !isStarred, keys: [article.key])
                }
                .tint(.yellow)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await refresher?.refresh(force: true)
            settle()
        }
        .onAppear { if hiddenRead == nil { settle() } }
        .onChange(of: filter) { settle() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { settle() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(TimelineFilter.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    Divider()
                    Button("Mark All as Read", systemImage: "checkmark.circle") {
                        let keys = shown.map(\.key)
                        update(read: true, keys: keys)
                        // The query hasn't seen the save yet.
                        settle(alsoRead: keys)
                    }
                    .disabled(shown.allSatisfy { read.contains($0.key) })
                    if filter == .unread, shown.contains(where: { read.contains($0.key) }) {
                        Button("Hide Read", systemImage: "eye.slash") { settle() }
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .overlay {
            if shown.isEmpty {
                switch filter {
                case .all:
                    ContentUnavailableView("Nothing Yet", systemImage: "tray", description: Text("New articles will appear here."))
                case .unread:
                    ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle", description: Text("No unread articles."))
                case .starred:
                    ContentUnavailableView("No Starred Articles", systemImage: "star", description: Text("Swipe left on an article to star it."))
                }
            }
        }
    }

    /// Hides articles read so far.
    private func settle(alsoRead keys: [String] = []) {
        hiddenRead = Set(states.lazy.filter(\.isRead).map(\.articleKey)).union(keys)
    }

    private func update(read: Bool? = nil, starred: Bool? = nil, keys: [String]) {
        do {
            try ArticleStates.set(read: read, starred: starred, for: keys, in: context)
        } catch {
            assertionFailure("Saving article state failed: \(error)")
        }
    }
}

struct TimelineRow: View {
    let article: Article
    let feedTitle: String
    let isRead: Bool
    var isStarred = false

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
                    if isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Starred")
                    }
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
