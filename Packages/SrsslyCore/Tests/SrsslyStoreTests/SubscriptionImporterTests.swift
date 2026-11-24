import Foundation
import SrsslyCore
import SwiftData
import Testing
@testable import SrsslyStore

@MainActor
@Suite struct SubscriptionImporterTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try SrsslyStore.makeContainer(inMemory: true, cloudKit: false)
    }

    private func subscriptions() throws -> [Subscription] {
        try context.fetch(FetchDescriptor<Subscription>(sortBy: [SortDescriptor(\.sortIndex)]))
    }

    @Test func importsInOrderWithFoldersAndSkipsDuplicates() throws {
        let feeds = [
            OPMLFeed(title: "Popehat", feedURL: URL(string: "http://www.popehat.com/feed/")!, folder: "Random"),
            OPMLFeed(title: "xkcd", feedURL: URL(string: "http://www.xkcd.com/rss.xml")!, folder: "Comics"),
            OPMLFeed(title: "Popehat again", feedURL: URL(string: "https://popehat.com/feed")!, folder: "Random"),
        ]
        let summary = try SubscriptionImporter.add(feeds, to: context)
        #expect(summary == ImportSummary(added: 2, duplicates: 1))
        let subs = try subscriptions()
        #expect(subs.map(\.title) == ["Popehat", "xkcd"])
        #expect(subs.map(\.folder) == ["Random", "Comics"])
        #expect(subs.map(\.sortIndex) == [0, 1])

        // Importing the same file again adds nothing; new feeds go after the end.
        let again = try SubscriptionImporter.add(feeds + [OPMLFeed(title: "New", feedURL: URL(string: "https://new.test/feed")!)], to: context)
        #expect(again == ImportSummary(added: 1, duplicates: 3))
        #expect(try subscriptions().last?.sortIndex == 2)
    }

    @Test(arguments: [
        ("xkcd.com/rss.xml", "https://xkcd.com/rss.xml"),
        ("  https://xkcd.com/rss.xml ", "https://xkcd.com/rss.xml"),
        ("http://example.com", "http://example.com"),
        ("feed://example.com/rss", "https://example.com/rss"),
    ])
    func addsTypedURL(input: String, expected: String) throws {
        let sub = try #require(try SubscriptionImporter.add(typed: input, to: context))
        #expect(sub.feedURLString == expected)
        #expect(sub.title == "")
    }

    @Test func rejectsBadOrDuplicateTypedURL() throws {
        #expect(try SubscriptionImporter.add(typed: "", to: context) == nil)
        #expect(try SubscriptionImporter.add(typed: "ftp://x.test/feed", to: context) == nil)
        #expect(try SubscriptionImporter.add(typed: "https://a.test/feed", to: context) != nil)
        #expect(try SubscriptionImporter.add(typed: "a.test/feed/", to: context) == nil)
    }
}
