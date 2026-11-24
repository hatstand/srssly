import Foundation
import Testing
@testable import SrsslyCore

@Suite struct RefreshPolicyTests {
    let policy = RefreshPolicy.standard
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func neverFetchedIsDue() {
        #expect(policy.isDue(lastAttempt: nil, consecutiveFailures: 0, latestItem: nil, now: now))
    }

    @Test func activeFeedWaitsMinimumInterval() {
        let recent = now.addingTimeInterval(-60)
        #expect(!policy.isDue(lastAttempt: now.addingTimeInterval(-10 * 60), consecutiveFailures: 0, latestItem: recent, now: now))
        #expect(policy.isDue(lastAttempt: now.addingTimeInterval(-16 * 60), consecutiveFailures: 0, latestItem: recent, now: now))
    }

    @Test func dormantFeedWaitsADay() {
        let old = now.addingTimeInterval(-200 * 86_400)
        #expect(!policy.isDue(lastAttempt: now.addingTimeInterval(-3_600), consecutiveFailures: 0, latestItem: old, now: now))
        #expect(policy.isDue(lastAttempt: now.addingTimeInterval(-86_401), consecutiveFailures: 0, latestItem: old, now: now))
    }

    @Test func failuresBackOffExponentiallyWithCap() {
        let last = now
        func wait(_ failures: Int) -> TimeInterval {
            policy.nextRefresh(lastAttempt: last, consecutiveFailures: failures, latestItem: nil, now: now).timeIntervalSince(last)
        }
        #expect(wait(1) == 15 * 60)
        #expect(wait(2) == 30 * 60)
        #expect(wait(3) == 60 * 60)
        #expect(wait(20) == 86_400)
        #expect(wait(1_000) == 86_400)
    }
}
