import BackgroundTasks
import OSLog

/// Background feed refresh through BGAppRefreshTask.
///
/// iOS decides when to run it, based on how often the app is used; asking
/// for every 30 minutes typically gets a few runs a day. Each run has about
/// 30 seconds, after which the refresh is cancelled and keeps what it got.
enum BackgroundRefresh {
    static let refreshID = "com.purplehatstands.srssly.refresh"
    static let interval: TimeInterval = 30 * 60

    private static let log = Logger(subsystem: "com.purplehatstands.srssly", category: "background")

    /// Asks for the next background refresh. Safe to call repeatedly: a
    /// newer request replaces the pending one.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Fails in the simulator and when Background App Refresh is off.
            log.info("Couldn't schedule background refresh: \(error, privacy: .public)")
        }
    }
}
