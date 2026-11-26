@preconcurrency import CloudKit
import Foundation

/// One-line descriptions of sync engine events for the "sync" log, so a
/// sysdiagnose shows what each device fetched, sent and failed. Record names
/// are subscription UUIDs and article keys (hashes), not user content.
enum CloudSyncLog {
    static func describe(_ event: CKSyncEngine.Event) -> String {
        switch event {
        case .stateUpdate:
            return "stateUpdate"
        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user): return "accountChange signIn user=\(short(user))"
            case .signOut(let user): return "accountChange signOut previous=\(short(user))"
            case .switchAccounts(let previous, let current):
                return "accountChange switchAccounts previous=\(short(previous)) current=\(short(current))"
            @unknown default: return "accountChange unknown"
            }
        case .fetchedDatabaseChanges(let changes):
            let mods = changes.modifications.map(\.zoneID.zoneName)
            let dels = changes.deletions.map { "\($0.zoneID.zoneName)(\($0.reason))" }
            return "fetchedDatabaseChanges modified=\(mods) deleted=\(dels)"
        case .fetchedRecordZoneChanges(let changes):
            let mods = Dictionary(grouping: changes.modifications, by: \.record.recordType).mapValues(\.count)
            let dels = Dictionary(grouping: changes.deletions, by: \.recordType).mapValues(\.count)
            return "fetchedRecordZoneChanges modified=\(mods.sorted { $0.key < $1.key }) deleted=\(dels.sorted { $0.key < $1.key })"
        case .sentDatabaseChanges(let sent):
            let failedSaves = sent.failedZoneSaves.map { "\($0.zone.zoneID.zoneName): \(code($0.error))" }
            let failedDeletes = sent.failedZoneDeletes.map { "\($0.key.zoneName): \(code($0.value))" }
            return "sentDatabaseChanges savedZones=\(sent.savedZones.map(\.zoneID.zoneName)) deletedZones=\(sent.deletedZoneIDs.map(\.zoneName)) failedSaves=\(failedSaves) failedDeletes=\(failedDeletes)"
        case .sentRecordZoneChanges(let sent):
            let saved = Dictionary(grouping: sent.savedRecords, by: \.recordType).mapValues(\.count)
            let failed = sent.failedRecordSaves.map { "\($0.record.recordType) \($0.record.recordID.recordName): \(code($0.error))" }
            let failedDeletes = sent.failedRecordDeletes.map { "\($0.key.recordName): \(code($0.value))" }
            return "sentRecordZoneChanges saved=\(saved.sorted { $0.key < $1.key }) deleted=\(sent.deletedRecordIDs.count) failedSaves=\(failed) failedDeletes=\(failedDeletes)"
        case .willFetchChanges:
            return "willFetchChanges"
        case .willFetchRecordZoneChanges(let e):
            return "willFetchRecordZoneChanges zone=\(e.zoneID.zoneName)"
        case .didFetchRecordZoneChanges(let e):
            return "didFetchRecordZoneChanges zone=\(e.zoneID.zoneName) error=\(e.error.map { code($0) } ?? "none")"
        case .didFetchChanges:
            return "didFetchChanges"
        case .willSendChanges(let e):
            return "willSendChanges reason=\(e.context.reason)"
        case .didSendChanges(let e):
            return "didSendChanges reason=\(e.context.reason)"
        @unknown default:
            return "unknown event"
        }
    }

    /// Pending work in the engine's state.
    static func pending(_ state: CKSyncEngine.State) -> String {
        var saves = 0, deletes = 0
        for change in state.pendingRecordZoneChanges {
            switch change {
            case .saveRecord: saves += 1
            case .deleteRecord: deletes += 1
            @unknown default: break
            }
        }
        return "pendingRecordSaves=\(saves) pendingRecordDeletes=\(deletes) pendingDatabaseChanges=\(state.pendingDatabaseChanges.count)"
    }

    /// An error's code name and description, e.g. "zoneNotFound (26): …".
    static func code(_ error: Error) -> String {
        guard let ck = error as? CKError else { return "\(error)" }
        var text = "CKError \(ck.code.rawValue): \(ck.localizedDescription)"
        if let underlying = ck.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " [underlying \(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    /// The first 8 characters of a user record name: enough to tell two
    /// accounts or environments apart.
    static func short(_ id: CKRecord.ID) -> String {
        String(id.recordName.prefix(8))
    }
}
