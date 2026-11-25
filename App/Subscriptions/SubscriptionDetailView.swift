import SrsslyCore
import SrsslyStore
import SwiftData
import SwiftUI

/// One feed: its articles, name, folder and offline setting, and its
/// refresh status.
struct SubscriptionDetailView: View {
    @Bindable var subscription: Subscription
    @Query private var fetchStates: [FeedFetchState]
    @Environment(\.modelContext) private var context

    @State private var title = ""
    @State private var folder = ""

    init(subscription: Subscription) {
        self.subscription = subscription
        let id = subscription.id
        _fetchStates = Query(filter: #Predicate<FeedFetchState> { $0.subscriptionID == id })
    }

    private var fetchState: FeedFetchState? { fetchStates.first }

    var body: some View {
        Form {
            Section {
                NavigationLink("Articles") {
                    ArticleTimeline(subscriptions: [subscription], only: subscription.id)
                        .navigationTitle(subscription.title)
                }
            }
            Section("Name") {
                TextField("Name", text: $title)
                    .onSubmit(saveTitle)
                TextField("Folder", text: $folder)
                    .onSubmit(saveFolder)
            }
            Section {
                Picker("Save for Offline", selection: cacheMode) {
                    Text(automaticLabel).tag(CacheMode.automatic)
                    Text("Feed Content").tag(CacheMode.feedContent)
                    Text("Article").tag(CacheMode.extractedArticle)
                    Text("Full Page").tag(CacheMode.fullPage)
                }
            } header: {
                Text("Offline Reading")
            } footer: {
                Text("Feed Content keeps what the feed sends, with its images. Article saves the article from the linked web page, for feeds that only send a summary. Full Page keeps the whole web page as the site shows it.")
            }
            Section("Status") {
                if let url = subscription.feedURL {
                    LabeledContent("Feed", value: url.absoluteString)
                        .textSelection(.enabled)
                }
                if let last = fetchState?.lastSuccessAt {
                    LabeledContent("Updated") { Text(last, format: .relative(presentation: .named)) }
                }
                if let error = fetchState?.lastError {
                    LabeledContent("Last Error", value: error)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(subscription.title.isEmpty ? "Feed" : subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            title = subscription.title
            folder = subscription.folder ?? ""
        }
        .onDisappear {
            saveTitle()
            saveFolder()
        }
    }

    private var automaticLabel: String {
        let rule = SiteRules.rule(article: subscription.siteURL, feed: subscription.feedURL)
        let detected = CacheModeDetector.effectiveMode(.automatic, siteRule: rule?.cacheMode, detected: fetchState?.detectedCacheMode ?? .feedContent)
        let name = switch detected {
        case .fullPage: "Full Page"
        case .extractedArticle: "Article"
        default: "Feed Content"
        }
        return "Automatic (\(name))"
    }

    /// The cacheMode setter bumps modifiedAt, so the change syncs.
    private var cacheMode: Binding<CacheMode> {
        Binding(
            get: { subscription.cacheMode },
            set: { subscription.cacheMode = $0; try? context.save() }
        )
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != subscription.title else { return }
        subscription.title = trimmed
        subscription.modifiedAt = .now
        try? context.save()
    }

    private func saveFolder() {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != subscription.folder else { return }
        subscription.folder = value
        subscription.modifiedAt = .now
        try? context.save()
    }
}
