import SrsslyStore
import SwiftData
import SwiftUI

struct ContentView: View {
    // @Query reads synchronously from the local store, so the first frame
    // already has content. Nothing here waits on the network.
    @Query(sort: [SortDescriptor(\Subscription.sortIndex), SortDescriptor(\Subscription.title)])
    private var subscriptions: [Subscription]

    @Environment(\.feedRefresher) private var refresher
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) { AddFeedsButton() }
            }
        }
        .onAppear { LaunchMetrics.firstContentAppeared() }
        // Refresh after the first frame, and again on returning to the app.
        // The policy skips feeds fetched in the last few minutes.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresher?.refresh()
        }
    }
}

#Preview("Empty") {
    ContentView()
        .modelContainer(try! SrsslyStore.makeContainer(inMemory: true, cloudKit: false))
}

#if DEBUG
#Preview("With articles") {
    ContentView()
        .modelContainer(SampleData.container())
}
#endif
