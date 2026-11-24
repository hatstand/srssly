import Darwin
import Foundation
import OSLog

/// Measures time from process start to the first frame of real content.
///
/// Srssly's rule is that launch never waits on the network or a loading
/// state: the first frame comes straight from the local store. This logs
/// how long that takes and emits a signpost visible in Instruments
/// (Points of Interest), so regressions show up.
@MainActor
enum LaunchMetrics {
    private static let log = Logger(subsystem: "org.srssly.Srssly", category: "launch")
    private static let signposter = OSSignposter(subsystem: "org.srssly.Srssly", category: .pointsOfInterest)
    private static var reported = false

    static func firstContentAppeared() {
        guard !reported else { return }
        reported = true
        signposter.emitEvent("First content")
        if let ms = millisecondsSinceProcessStart() {
            log.notice("First content after \(ms, format: .fixed(precision: 1)) ms")
        }
    }

    private static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }
}
