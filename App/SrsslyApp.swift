import OSLog
import SrsslyStore
import SwiftData
import SwiftUI

@main
@MainActor
struct SrsslyApp: App {
    let container: ModelContainer
    let refresher: FeedRefresher?

    @Environment(\.scenePhase) private var scenePhase

    init() {
        container = Self.makeContainer()
        #if DEBUG
        // Sample data is for previews and UI tests: never touch the network.
        refresher = SampleData.isRequested ? nil : FeedRefresher(container: container)
        #else
        refresher = FeedRefresher(container: container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.feedRefresher, refresher)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, refresher != nil { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.refreshID)) { [refresher] in
            // Schedule the next one first, in case this run is cut short.
            BackgroundRefresh.schedule()
            await refresher?.refresh()
        }
    }

    private static func makeContainer() -> ModelContainer {
        #if DEBUG
        if SampleData.isRequested { return SampleData.container() }
        #endif
        do {
            return try SrsslyStore.makeContainer()
        } catch {
            Logger(subsystem: "com.purplehatstands.srssly", category: "store")
                .fault("Opening the store failed: \(error, privacy: .public)")
            // Never block launch on the store: fall back to an empty in-memory
            // one so the UI still renders, and surface the problem in-app later.
            do {
                return try SrsslyStore.makeContainer(inMemory: true, cloudKit: false)
            } catch {
                fatalError("Could not create even an in-memory store: \(error)")
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var feedRefresher: FeedRefresher? = nil
}
