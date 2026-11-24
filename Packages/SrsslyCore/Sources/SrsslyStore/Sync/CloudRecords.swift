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
        public static let sortKey = "sortKey"
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

// MARK: - Field snapshots

/// The synced values of a subscription, for comparing and merging.
public struct SubscriptionFields: Codable, Equatable, Sendable {
    public var feedURL: String
    public var siteURL: String?
    public var title: String
    public var folder: String?
    public var sortKey: String
    public var cacheMode: String
    public var addedAt: Date

    init(_ sub: Subscription) {
        feedURL = sub.feedURLString
        siteURL = sub.siteURLString
        title = sub.title
        folder = sub.folder
        sortKey = sub.sortKey
        cacheMode = sub.cacheModeRaw
        addedAt = sub.addedAt
    }

    init?(record: CKRecord) {
        typealias F = CloudSchema.SubscriptionField
        guard let feedURL = record[F.feedURL] as? String else { return nil }
        self.feedURL = feedURL
        siteURL = record[F.siteURL] as? String
        title = record[F.title] as? String ?? ""
        folder = record[F.folder] as? String
        sortKey = record[F.sortKey] as? String ?? SortKey.middle
        cacheMode = record[F.cacheMode] as? String ?? CacheMode.automatic.rawValue
        addedAt = record[F.addedAt] as? Date ?? .distantPast
    }

    /// Three-way merge: each side keeps the fields it changed since `base`.
    /// When both changed the same field, `localWinsTies` decides.
    static func merge(base: Self?, local: Self, remote: Self, localWinsTies: Bool) -> Self {
        guard let base else { return localWinsTies ? local : remote }
        var m = remote
        func pick<T: Equatable>(_ kp: WritableKeyPath<Self, T>) {
            m[keyPath: kp] = ThreeWay.pick(base: base[keyPath: kp], local: local[keyPath: kp], remote: remote[keyPath: kp], localWinsTies: localWinsTies)
        }
        pick(\.feedURL); pick(\.siteURL); pick(\.title); pick(\.folder)
        pick(\.sortKey); pick(\.cacheMode); pick(\.addedAt)
        return m
    }
}

/// The synced values of an article's state.
public struct ArticleStateFields: Codable, Equatable, Sendable {
    public var isRead: Bool
    public var isStarred: Bool

    init(_ state: ArticleState) {
        isRead = state.isRead
        isStarred = state.isStarred
    }

    init(record: CKRecord) {
        typealias F = CloudSchema.ArticleStateField
        isRead = (record[F.isRead] as? Int64 ?? 0) != 0
        isStarred = (record[F.isStarred] as? Int64 ?? 0) != 0
    }

    static func merge(base: Self?, local: Self, remote: Self, localWinsTies: Bool) -> Self {
        guard let base else { return localWinsTies ? local : remote }
        return Self(
            isRead: ThreeWay.pick(base: base.isRead, local: local.isRead, remote: remote.isRead, localWinsTies: localWinsTies),
            isStarred: ThreeWay.pick(base: base.isStarred, local: local.isStarred, remote: remote.isStarred, localWinsTies: localWinsTies)
        )
    }

    init(isRead: Bool, isStarred: Bool) {
        self.isRead = isRead
        self.isStarred = isStarred
    }
}

enum ThreeWay {
    static func pick<T: Equatable>(base: T, local: T, remote: T, localWinsTies: Bool) -> T {
        if local == base { return remote }
        if remote == base { return local }
        if local == remote { return local }
        return localWinsTies ? local : remote
    }
}

private func encodeBase<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
private func decodeBase<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
    data.flatMap { try? JSONDecoder().decode(type, from: $0) }
}

// MARK: - Subscription <-> record

extension Subscription {
    public var cloudRecordID: CKRecord.ID { CloudSchema.recordID(subscriptionID: id) }

    var syncedFields: SubscriptionFields {
        get { SubscriptionFields(self) }
        set {
            feedURLString = newValue.feedURL
            if let url = URL(string: newValue.feedURL) { canonicalKey = FeedURL.canonicalKey(for: url) }
            siteURLString = newValue.siteURL
            title = newValue.title
            folder = newValue.folder
            sortKey = newValue.sortKey
            cacheModeRaw = newValue.cacheMode
            addedAt = newValue.addedAt
        }
    }

    /// True when there are local edits the server hasn't seen.
    var hasUnsyncedChanges: Bool {
        decodeBase(SubscriptionFields.self, cloudKitBase) != syncedFields
    }

    /// This subscription as a CloudKit record, ready to save.
    public func makeRecord() -> CKRecord {
        typealias F = CloudSchema.SubscriptionField
        let record = CloudSchema.record(type: CloudSchema.RecordType.subscription, id: cloudRecordID, systemFields: cloudKitSystemFields)
        record[F.feedURL] = feedURLString
        record[F.siteURL] = siteURLString
        record[F.title] = title
        record[F.folder] = folder
        record[F.sortKey] = sortKey
        record[F.cacheMode] = cacheModeRaw
        record[F.addedAt] = addedAt
        record[F.modifiedAt] = modifiedAt
        return record
    }

    /// Records that the server now has `record` (after a save or fetch).
    func markSynced(_ record: CKRecord) {
        cloudKitSystemFields = CloudSchema.archive(systemFieldsOf: record)
        cloudKitBase = SubscriptionFields(record: record).flatMap(encodeBase)
    }

    /// Merges a record from the server into this subscription.
    ///
    /// Returns true if the merged result differs from the server's copy, so
    /// it needs uploading again.
    @discardableResult
    public func merge(_ record: CKRecord) -> Bool {
        guard let remote = SubscriptionFields(record: record) else { return false }
        let remoteModified = CloudMerge.modifiedAt(of: record)
        let merged: SubscriptionFields
        if hasUnsyncedChanges {
            merged = SubscriptionFields.merge(
                base: decodeBase(SubscriptionFields.self, cloudKitBase), local: syncedFields, remote: remote,
                localWinsTies: !CloudMerge.remoteWins(local: modifiedAt, remote: remoteModified)
            )
        } else {
            merged = remote
        }
        syncedFields = merged
        modifiedAt = max(modifiedAt, remoteModified ?? modifiedAt)
        markSynced(record)
        return merged != remote
    }

    /// A new subscription from a record fetched from another device.
    public convenience init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.subscription,
              let id = UUID(uuidString: record.recordID.recordName),
              let fields = SubscriptionFields(record: record),
              let url = URL(string: fields.feedURL)
        else { return nil }
        self.init(feedURL: url, title: fields.title)
        self.id = id
        syncedFields = fields
        modifiedAt = CloudMerge.modifiedAt(of: record) ?? modifiedAt
        markSynced(record)
    }
}

// MARK: - ArticleState <-> record

extension ArticleState {
    public var cloudRecordID: CKRecord.ID { CloudSchema.recordID(articleKey: articleKey) }

    var hasUnsyncedChanges: Bool {
        decodeBase(ArticleStateFields.self, cloudKitBase) != ArticleStateFields(self)
    }

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

    func markSynced(_ record: CKRecord) {
        cloudKitSystemFields = CloudSchema.archive(systemFieldsOf: record)
        cloudKitBase = encodeBase(ArticleStateFields(record: record))
    }

    @discardableResult
    public func merge(_ record: CKRecord) -> Bool {
        let remote = ArticleStateFields(record: record)
        let remoteModified = CloudMerge.modifiedAt(of: record)
        let merged = hasUnsyncedChanges
            ? ArticleStateFields.merge(
                base: decodeBase(ArticleStateFields.self, cloudKitBase), local: ArticleStateFields(self), remote: remote,
                localWinsTies: !CloudMerge.remoteWins(local: updatedAt, remote: remoteModified))
            : remote
        isRead = merged.isRead
        isStarred = merged.isStarred
        updatedAt = max(updatedAt, remoteModified ?? updatedAt)
        markSynced(record)
        return merged != remote
    }

    public convenience init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.articleState else { return nil }
        let key = record[CloudSchema.ArticleStateField.articleKey] as? String ?? record.recordID.recordName
        let fields = ArticleStateFields(record: record)
        self.init(articleKey: key, isRead: fields.isRead, isStarred: fields.isStarred)
        updatedAt = CloudMerge.modifiedAt(of: record) ?? updatedAt
        markSynced(record)
    }
}

/// Tie-breaking for the rare case where both sides changed the same field.
public enum CloudMerge {
    /// Whether the remote side wins a same-field conflict: the later
    /// `modifiedAt` wins, and the server wins exact ties so devices converge.
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
