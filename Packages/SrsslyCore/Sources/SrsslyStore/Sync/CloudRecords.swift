@preconcurrency import CloudKit
import Foundation
import SrsslyCore

/// The CloudKit schema, documented for other clients in docs/cloudkit-schema.md.
///
/// Records live in the user's private database, in a custom zone. Field
/// values are plain types (strings, Int64, dates) so CloudKit JS and the
/// CloudKit web services can use them directly. Booleans are Int64 0/1.
public enum CloudSchema {
    public static let zoneName = "Srssly"
    public static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    public enum RecordType {
        public static let subscription = "Subscription"
        public static let articleState = "ArticleState"
    }

    public enum SubscriptionField {
        public static let feedURL = "feedURL"
        public static let siteURL = "siteURL"
        public static let title = "title"
        public static let folder = "folder"
        public static let sortIndex = "sortIndex"
        public static let cacheMode = "cacheMode"
        public static let addedAt = "addedAt"
        public static let modifiedAt = "modifiedAt"
    }

    public enum ArticleStateField {
        public static let articleKey = "articleKey"
        public static let subscriptionID = "subscriptionID"
        public static let isRead = "isRead"
        public static let isStarred = "isStarred"
        public static let modifiedAt = "modifiedAt"
    }

    /// Subscriptions use their UUID as the record name.
    public static func recordID(subscriptionID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: subscriptionID.uuidString.lowercased(), zoneID: zoneID)
    }

    /// Article states use their `ArticleKey` as the record name.
    public static func recordID(articleKey: String) -> CKRecord.ID {
        CKRecord.ID(recordName: articleKey, zoneID: zoneID)
    }

    static func archive(systemFieldsOf record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// A record carrying the saved system fields (so the server sees the right
    /// change tag), or a fresh one.
    static func record(type: String, id: CKRecord.ID, systemFields: Data?) -> CKRecord {
        if let systemFields,
           let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            if let record = CKRecord(coder: coder), record.recordID == id {
                return record
            }
        }
        return CKRecord(recordType: type, recordID: id)
    }
}

extension Subscription {
    public var cloudRecordID: CKRecord.ID { CloudSchema.recordID(subscriptionID: id) }

    /// This subscription as a CloudKit record, ready to save.
    public func makeRecord() -> CKRecord {
        typealias F = CloudSchema.SubscriptionField
        let record = CloudSchema.record(type: CloudSchema.RecordType.subscription, id: cloudRecordID, systemFields: cloudKitSystemFields)
        record[F.feedURL] = feedURLString
        record[F.siteURL] = siteURLString
        record[F.title] = title
        record[F.folder] = folder
        record[F.sortIndex] = Int64(sortIndex)
        record[F.cacheMode] = cacheModeRaw
        record[F.addedAt] = addedAt
        record[F.modifiedAt] = modifiedAt
        return record
    }

    /// Copies a fetched record's values into this subscription.
    public func apply(_ record: CKRecord) {
        typealias F = CloudSchema.SubscriptionField
        if let url = record[F.feedURL] as? String, let parsed = URL(string: url) {
            feedURLString = url
            canonicalKey = FeedURL.canonicalKey(for: parsed)
        }
        siteURLString = record[F.siteURL] as? String
        title = record[F.title] as? String ?? title
        folder = record[F.folder] as? String
        sortIndex = Int(record[F.sortIndex] as? Int64 ?? Int64(sortIndex))
        cacheModeRaw = record[F.cacheMode] as? String ?? cacheModeRaw
        addedAt = record[F.addedAt] as? Date ?? addedAt
        modifiedAt = record[F.modifiedAt] as? Date ?? modifiedAt
        cloudKitSystemFields = CloudSchema.archive(systemFieldsOf: record)
    }

    /// A new subscription from a record fetched from another device.
    public convenience init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.subscription,
              let id = UUID(uuidString: record.recordID.recordName),
              let url = (record[CloudSchema.SubscriptionField.feedURL] as? String).flatMap(URL.init(string:))
        else { return nil }
        self.init(feedURL: url, title: "")
        self.id = id
        apply(record)
    }
}

extension ArticleState {
    public var cloudRecordID: CKRecord.ID { CloudSchema.recordID(articleKey: articleKey) }

    public func makeRecord() -> CKRecord {
        typealias F = CloudSchema.ArticleStateField
        let record = CloudSchema.record(type: CloudSchema.RecordType.articleState, id: cloudRecordID, systemFields: cloudKitSystemFields)
        record[F.articleKey] = articleKey
        // The part of the key before ":" is the subscription's ID; stored on
        // its own so a web client can query by subscription.
        record[F.subscriptionID] = articleKey.split(separator: ":").first.map(String.init)
        record[F.isRead] = Int64(isRead ? 1 : 0)
        record[F.isStarred] = Int64(isStarred ? 1 : 0)
        record[F.modifiedAt] = updatedAt
        return record
    }

    public func apply(_ record: CKRecord) {
        typealias F = CloudSchema.ArticleStateField
        isRead = (record[F.isRead] as? Int64 ?? 0) != 0
        isStarred = (record[F.isStarred] as? Int64 ?? 0) != 0
        updatedAt = record[F.modifiedAt] as? Date ?? updatedAt
        cloudKitSystemFields = CloudSchema.archive(systemFieldsOf: record)
    }

    public convenience init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.articleState else { return nil }
        let key = record[CloudSchema.ArticleStateField.articleKey] as? String ?? record.recordID.recordName
        self.init(articleKey: key)
        apply(record)
    }
}

/// Last writer wins, by each record's `modifiedAt`.
public enum CloudMerge {
    /// Whether a fetched record should overwrite the local copy. On a tie the
    /// server wins, so all devices converge.
    public static func remoteWins(local: Date, remote: Date?) -> Bool {
        guard let remote else { return false }
        return remote >= local
    }

    static func modifiedAt(of record: CKRecord) -> Date? {
        switch record.recordType {
        case CloudSchema.RecordType.subscription: record[CloudSchema.SubscriptionField.modifiedAt] as? Date
        case CloudSchema.RecordType.articleState: record[CloudSchema.ArticleStateField.modifiedAt] as? Date
        default: nil
        }
    }
}
