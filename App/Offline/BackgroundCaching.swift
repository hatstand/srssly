import BackgroundTasks
import OSLog
import SrsslyStore

/// Settings for the offline cache.
enum OfflineSettings {
    /// When true, pages and images also download on mobile data. Feeds
    /// themselves always refresh on any network.
    static let allowsCellularKey = "offlineCacheAllowsCellular"

    static var allowsCellular: Bool { UserDefaults.standard.bool(forKey: allowsCellularKey) }
}

/// Bulk page and image caching through BGProcessingTask, which iOS runs
/// when the device is idle, on a network and charging (typically overnight),
/// with minutes rather than seconds to work.
enum BackgroundCaching {
    static let taskID = "com.purplehatstands.srssly.cache"

    private static let log = Logger(subsystem: "com.purplehatstands.srssly", category: "background")

    /// Wraps the task so it can cross into the work's Task; BGTask is only
    /// touched to set the expiration handler and to complete it.
    private struct TaskBox: @unchecked Sendable { let task: BGTask }

    /// Registers the handler. Must run before the app finishes launching.
    static func register(refresher: FeedRefresher, cacher: OfflineCacher) {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            let box = TaskBox(task: task)
            schedule()
            let work = Task {
                await refresher.refresh()
                await cacher.run(allowsCellular: OfflineSettings.allowsCellular)
                await cacher.prune()
            }
            box.task.expirationHandler = { work.cancel() }
            Task {
                await work.value
                box.task.setTaskCompleted(success: !work.isCancelled)
            }
        }
        if !registered { log.error("Couldn't register \(taskID, privacy: .public)") }
    }

    /// Asks for the next run. A newer request replaces the pending one.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.info("Couldn't schedule background caching: \(error, privacy: .public)")
        }
    }
}
