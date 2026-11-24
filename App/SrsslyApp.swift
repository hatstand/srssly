import OSLog
import SrsslyStore
import SwiftData
import SwiftUI

@main
@MainActor
struct SrsslyApp: App {
    let container: ModelContainer
    let refresher: FeedRefresher?
    let offlineCacher: OfflineCacher?
    let cloudSync: CloudSync?

    static let cloudContainerID = "iCloud.com.purplehatstands.srssly"

    @Environment(\.scenePhase) private var scenePhase

    init() {
        container = Self.makeContainer()
        #if DEBUG
        // Sample data is for previews and UI tests: never touch the network.
        let online = !SampleData.isRequested
        #else
        let online = true
        #endif
        refresher = online ? FeedRefresher(container: container) : nil
        offlineCacher = online ? Self.makeOfflineCacher(container: container) : nil
        if let refresher, let offlineCacher {
            BackgroundCaching.register(refresher: refresher, cacher: offlineCacher)
        }
        cloudSync = online ? CloudSync(
            container: container,
            cloudContainerID: Self.cloudContainerID,
            stateDirectory: URL.applicationSupportDirectory
        ) : nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.feedRefresher, refresher)
                .environment(\.offlineCacher, offlineCacher)
                .task { await cloudSync?.start() }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, refresher != nil {
                BackgroundRefresh.schedule()
                if offlineCacher != nil { BackgroundCaching.schedule() }
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.refreshID)) { [refresher, offlineCacher] in
            // Schedule the next one first, in case this run is cut short.
            BackgroundRefresh.schedule()
            await refresher?.refresh()
            // Use what's left of the ~30 seconds to save the newest articles.
            await offlineCacher?.run(allowsCellular: OfflineSettings.allowsCellular)
        }
    }

    private static func makeOfflineCacher(container: ModelContainer) -> OfflineCacher? {
        do {
            return OfflineCacher(container: container, cache: try OfflineCache())
        } catch {
            Logger(subsystem: "com.purplehatstands.srssly", category: "offline")
                .error("Opening the offline cache failed: \(error, privacy: .public)")
            return nil
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
                return try SrsslyStore.makeContainer(inMemory: true)
            } catch {
                fatalError("Could not create even an in-memory store: \(error)")
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var feedRefresher: FeedRefresher? = nil
    @Entry var offlineCacher: OfflineCacher? = nil
}
