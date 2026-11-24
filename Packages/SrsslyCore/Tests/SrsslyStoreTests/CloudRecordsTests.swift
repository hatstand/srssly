import CloudKit
import Foundation
import SrsslyCore
import Testing
@testable import SrsslyStore

@Suite struct CloudRecordsTests {
    @Test func subscriptionRoundTripsThroughARecord() throws {
        let sub = Subscription(
            feedURL: URL(string: "https://xkcd.com/rss.xml")!, title: "xkcd",
            folder: "Comics", siteURL: URL(string: "https://xkcd.com/")
        )
        sub.sortIndex = 7
        sub.cacheMode = .fullPage
        let record = sub.makeRecord()

        #expect(record.recordType == "Subscription")
        #expect(record.recordID.zoneID.zoneName == "Srssly")
        #expect(record.recordID.recordName == sub.id.uuidString.lowercased())
        #expect(record["feedURL"] as? String == "https://xkcd.com/rss.xml")
        #expect(record["sortIndex"] as? Int64 == 7)
        #expect(record["cacheMode"] as? String == "fullPage")

        let copy = try #require(Subscription(record: record))
        #expect(copy.id == sub.id)
        #expect(copy.title == "xkcd")
        #expect(copy.folder == "Comics")
        #expect(copy.siteURLString == "https://xkcd.com/")
        #expect(copy.sortIndex == 7)
        #expect(copy.cacheMode == .fullPage)
        #expect(copy.canonicalKey == "xkcd.com/rss.xml")
        #expect(copy.modifiedAt == sub.modifiedAt)
        #expect(copy.cloudKitSystemFields != nil)
    }

    @Test func savedSystemFieldsAreReused() throws {
        let sub = Subscription(feedURL: URL(string: "https://a.test/feed")!, title: "A")
        let first = sub.makeRecord()
        sub.cloudKitSystemFields = CloudSchema.archive(systemFieldsOf: first)
        sub.title = "B"
        let second = sub.makeRecord()
        #expect(second.recordID == first.recordID)
        #expect(second["title"] as? String == "B")
    }

    @Test func articleStateRoundTripsWithIntBooleans() throws {
        let subID = UUID()
        let key = ArticleKey.make(subscriptionID: subID, guid: "x", link: nil, title: nil, published: nil)
        let state = ArticleState(articleKey: key, isRead: true, isStarred: false)
        let record = state.makeRecord()

        #expect(record.recordType == "ArticleState")
        #expect(record.recordID.recordName == key)
        #expect(record["isRead"] as? Int64 == 1)
        #expect(record["isStarred"] as? Int64 == 0)
        #expect(record["subscriptionID"] as? String == subID.uuidString.lowercased())

        let copy = try #require(ArticleState(record: record))
        #expect(copy.articleKey == key)
        #expect(copy.isRead)
        #expect(!copy.isStarred)
    }

    @Test func newerWinsAndServerWinsTies() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CloudMerge.remoteWins(local: t, remote: t.addingTimeInterval(1)))
        #expect(CloudMerge.remoteWins(local: t, remote: t))
        #expect(!CloudMerge.remoteWins(local: t.addingTimeInterval(1), remote: t))
        #expect(!CloudMerge.remoteWins(local: t, remote: nil))
    }

    @Test func recordsWithoutAUUIDNameAreIgnored() {
        let record = CKRecord(recordType: "Subscription", recordID: CKRecord.ID(recordName: "not-a-uuid", zoneID: CloudSchema.zoneID))
        record["feedURL"] = "https://a.test/feed"
        #expect(Subscription(record: record) == nil)
    }
}
