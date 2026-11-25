import SrsslyStore
import SwiftData
import SwiftUI

struct ContentView: View {
    // @Query reads synchronously from the local store, so the first frame
    // already has content. Nothing here waits on the network.
    @Query(sort: [SortDescriptor(\Subscription.sortKey), SortDescriptor(\Subscription.title)])
    private var subscriptions: [Subscription]

    @Environment(\.feedRefresher) private var refresher
    @Environment(\.offlineCacher) private var offlineCacher
    @Environment(\.modelContext) private var context
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if subscriptions.isEmpty {
                    ContentUnavailableView(
                        "No Subscriptions",
                        systemImage: "dot.radiowaves.up.forward",
                        description: Text("Tap + to add a feed or import an OPML file from another reader.")
                    )
                } else {
                    ArticleTimeline(subscriptions: subscriptions)
                }
            }
            .navigationTitle("Srssly")
            // Registered once here, for the timeline and per-feed lists.
            .navigationDestination(for: Article.self) { article in
                ArticleReaderView(article: article, subscription: subscriptions.first { $0.id == article.subscriptionID })
            }
            .navigationDestination(for: Subscription.self) { SubscriptionDetailView(subscription: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { AddFeedsButton() }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    NavigationLink { SubscriptionsView() } label: {
                        Label("Subscriptions", systemImage: "list.bullet")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onAppear { LaunchMetrics.firstContentAppeared() }
        // Refresh after the first frame, and again on returning to the app.
        // The policy skips feeds fetched in the last few minutes.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresher?.refresh()
            // Then save new articles for offline reading, newest first. Wi-Fi
            // only unless mobile data is allowed in Settings.
            await offlineCacher?.run(allowsCellular: OfflineSettings.allowsCellular)
            // Drop articles of feeds unsubscribed on another device, then
            // the offline files only they used.
            try? SubscriptionCleanup.removeOrphans(in: context)
            await offlineCacher?.prune()
        }
    }
}

#Preview("Empty") {
    ContentView()
        .modelContainer(try! SrsslyStore.makeContainer(inMemory: true))
}

#if DEBUG
#Preview("With articles") {
    ContentView()
        .modelContainer(SampleData.container())
}
#endif
