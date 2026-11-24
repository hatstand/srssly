import Foundation

/// Decides when each feed is next worth fetching.
///
/// - Active feeds: at most every `minimumInterval`, so reopening the app
///   doesn't refetch everything.
/// - Dormant feeds (nothing new for `dormantAfter`): once a day. The feed
///   evaluation found 15 of 42 working feeds had been quiet for 6+ months.
/// - Failing feeds: exponential backoff, capped at `maxBackoff`.
public struct RefreshPolicy: Sendable, Equatable {
    public var minimumInterval: TimeInterval
    public var dormantAfter: TimeInterval
    public var dormantInterval: TimeInterval
    public var maxBackoff: TimeInterval

    public init(
        minimumInterval: TimeInterval = 15 * 60,
        dormantAfter: TimeInterval = 180 * 86_400,
        dormantInterval: TimeInterval = 86_400,
        maxBackoff: TimeInterval = 86_400
    ) {
        self.minimumInterval = minimumInterval
        self.dormantAfter = dormantAfter
        self.dormantInterval = dormantInterval
        self.maxBackoff = maxBackoff
    }

    public static let standard = RefreshPolicy()

    public func nextRefresh(lastAttempt: Date?, consecutiveFailures: Int, latestItem: Date?, now: Date) -> Date {
        guard let lastAttempt else { return .distantPast }
        if consecutiveFailures > 0 {
            let exponent = Double(min(consecutiveFailures - 1, 20))
            return lastAttempt.addingTimeInterval(min(minimumInterval * pow(2, exponent), maxBackoff))
        }
        if let latestItem, now.timeIntervalSince(latestItem) > dormantAfter {
            return lastAttempt.addingTimeInterval(dormantInterval)
        }
        return lastAttempt.addingTimeInterval(minimumInterval)
    }

    public func isDue(lastAttempt: Date?, consecutiveFailures: Int, latestItem: Date?, now: Date) -> Bool {
        nextRefresh(lastAttempt: lastAttempt, consecutiveFailures: consecutiveFailures, latestItem: latestItem, now: now) <= now
    }
}
