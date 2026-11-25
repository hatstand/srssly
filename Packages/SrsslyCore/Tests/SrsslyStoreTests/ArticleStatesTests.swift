import Foundation
import SwiftData
import Testing
@testable import SrsslyStore

@MainActor
@Suite struct ArticleStatesTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try SrsslyStore.makeContainer(inMemory: true)
    }

    private func states() throws -> [String: ArticleState] {
        Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<ArticleState>()).map { ($0.articleKey, $0) })
    }

    @Test func createsRowsOnlyWhenNeeded() throws {
        #expect(try ArticleStates.set(read: false, for: ["a"], in: context, now: now) == 0)
        #expect(try states().isEmpty, "no row just to say unread")

        #expect(try ArticleStates.set(read: true, for: ["a", "b"], in: context, now: now) == 2)
        let saved = try states()
        #expect(saved["a"]?.isRead == true)
        #expect(saved["a"]?.isStarred == false)
        #expect(saved["a"]?.updatedAt == now)
    }

    @Test func updatesExistingRowsAndBumpsTheirTime() throws {
        try ArticleStates.set(read: true, for: ["a"], in: context, now: now)
        let later = now.addingTimeInterval(60)

        #expect(try ArticleStates.set(read: true, for: ["a"], in: context, now: later) == 0, "no change, no bump")
        #expect(try states()["a"]?.updatedAt == now)

        #expect(try ArticleStates.set(starred: true, for: ["a"], in: context, now: later) == 1)
        let a = try #require(try states()["a"])
        #expect(a.isRead && a.isStarred)
        #expect(a.updatedAt == later)

        #expect(try ArticleStates.set(read: false, for: ["a"], in: context, now: later) == 1)
        #expect(try states()["a"]?.isRead == false)
    }
}
