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
        sub.sortKey = "a0V"
        sub.cacheMode = .fullPage
        let record = sub.makeRecord()

        #expect(record.recordType == "Subscription")
        #expect(record.recordID.zoneID.zoneName == "Srssly")
        #expect(record.recordID.recordName == sub.id.uuidString.lowercased())
        #expect(record["feedURL"] as? String == "https://xkcd.com/rss.xml")
        #expect(record["sortKey"] as? String == "a0V")
        #expect(record["cacheMode"] as? String == "fullPage")

        let copy = try #require(Subscription(record: record))
        #expect(copy.id == sub.id)
        #expect(copy.title == "xkcd")
        #expect(copy.folder == "Comics")
        #expect(copy.siteURLString == "https://xkcd.com/")
        #expect(copy.sortKey == "a0V")
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

    @Test func fieldsChangedOnDifferentDevicesBothSurvive() throws {
        // This device renamed it; another device moved it to a folder.
        let sub = Subscription(feedURL: URL(string: "https://a.test/feed")!, title: "Old name")
        let server = sub.makeRecord()
        sub.merge(server) // in sync: base = server copy
        sub.title = "My name"
        sub.modifiedAt = Date(timeIntervalSinceNow: 10)

        let remote = sub.makeRecord()
        remote["title"] = "Old name"
        remote["folder"] = "Comics"
        remote["modifiedAt"] = Date(timeIntervalSinceNow: 20)

        let needsUpload = sub.merge(remote)
        #expect(sub.title == "My name")
        #expect(sub.folder == "Comics")
        #expect(needsUpload, "the merged copy has our rename, which the server lacks")
    }

    @Test func sameFieldConflictGoesToTheLaterChange() throws {
        let sub = Subscription(feedURL: URL(string: "https://a.test/feed")!, title: "Base")
        sub.merge(sub.makeRecord())
        sub.title = "Local"
        sub.modifiedAt = Date(timeIntervalSince1970: 1_800_000_100)

        let remote = sub.makeRecord()
        remote["title"] = "Remote"
        remote["modifiedAt"] = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(sub.merge(remote))
        #expect(sub.title == "Local")

        sub.merge(sub.makeRecord()) // pretend that uploaded
        sub.title = "Local again"
        sub.modifiedAt = Date(timeIntervalSince1970: 1_800_000_200)
        let newer = sub.makeRecord()
        newer["title"] = "Remote wins"
        newer["modifiedAt"] = Date(timeIntervalSince1970: 1_800_000_300)
        #expect(!sub.merge(newer))
        #expect(sub.title == "Remote wins")
    }

    @Test func noLocalChangesTakesServerCopy() throws {
        let sub = Subscription(feedURL: URL(string: "https://a.test/feed")!, title: "A")
        sub.merge(sub.makeRecord())
        let remote = sub.makeRecord()
        remote["title"] = "B"
        remote["modifiedAt"] = Date(timeIntervalSince1970: 0) // even with an older clock
        #expect(!sub.merge(remote))
        #expect(sub.title == "B")
    }

    @Test func readOnOneDeviceStarOnAnotherBothSurvive() throws {
        let state = ArticleState(articleKey: "k")
        state.merge(state.makeRecord())
        state.isRead = true
        let remote = state.makeRecord()
        remote["isRead"] = Int64(0)
        remote["isStarred"] = Int64(1)
        #expect(state.merge(remote))
        #expect(state.isRead && state.isStarred)
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
