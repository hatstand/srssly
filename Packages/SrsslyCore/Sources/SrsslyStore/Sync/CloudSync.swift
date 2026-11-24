@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData

/// Syncs subscriptions and read/starred state with CloudKit using
/// `CKSyncEngine`, in the record format described by `CloudSchema`.
///
/// Local changes are picked up automatically: any save of a synced model on
/// any `ModelContext` (other than the one this uses to apply remote changes)
/// queues that record for upload. Deleting a subscription must go through
/// `deleteSubscription(id:)` so the deletion can be sent too.
public actor CloudSync: CKSyncEngineDelegate {
    private let container: ModelContainer
    private let database: CKDatabase
    private let stateURL: URL
    private let log = Logger(subsystem: "com.purplehatstands.srssly", category: "sync")

    private var engine: CKSyncEngine?
    /// Applies fetched changes. Saves from it aren't echoed back as uploads.
    private var applyContext: ModelContext
    private nonisolated(unsafe) var saveObserver: (any NSObjectProtocol)?

    public init(container: ModelContainer, cloudContainerID: String, stateDirectory: URL) {
        self.container = container
        self.database = CKContainer(identifier: cloudContainerID).privateCloudDatabase
        self.stateURL = stateDirectory.appending(path: "CloudSyncState.json")
        self.applyContext = ModelContext(container)
        self.applyContext.autosaveEnabled = false
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    /// Starts syncing. Call once at launch, after the first frame.
    public func start() {
        guard engine == nil else { return }
        let saved = loadState()
        let engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: database, stateSerialization: saved, delegate: self
        ))
        self.engine = engine
        observeLocalSaves()
        if saved == nil {
            // First run (or after an account change): create the zone and
            // upload everything already on this device.
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID))])
            enqueueAllLocalRecords()
        }
    }

    /// Fetches and sends now, e.g. on pull to refresh.
    public func syncNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            log.error("Sync failed: \(error, privacy: .public)")
        }
    }

    /// Deletes a subscription here and on every device.
    public func deleteSubscription(id: UUID) throws {
        let context = ModelContext(container)
        let subs = try context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == id }))
        subs.forEach(context.delete)
        try context.save()
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(CloudSchema.recordID(subscriptionID: id))])
    }

    // MARK: - Local changes

    private func observeLocalSaves() {
        guard saveObserver == nil else { return }
        let applyID = ObjectIdentifier(applyContext)
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] note in
            guard let context = note.object as? ModelContext, ObjectIdentifier(context) != applyID else { return }
            let keys = [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers]
            let ids = keys.flatMap { note.userInfo?[$0.rawValue] as? [PersistentIdentifier] ?? [] }
            guard !ids.isEmpty, let self else { return }
            Task { await self.localModelsSaved(ids) }
        }
    }

    private func localModelsSaved(_ ids: [PersistentIdentifier]) {
        guard let engine else { return }
        let context = ModelContext(container)
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for id in ids {
            switch context.model(for: id) {
            case let sub as Subscription: changes.append(.saveRecord(sub.cloudRecordID))
            case let state as ArticleState: changes.append(.saveRecord(state.cloudRecordID))
            default: break
            }
        }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
    }

    private func enqueueAllLocalRecords() {
        guard let engine else { return }
        let context = ModelContext(container)
        let subs = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
        let states = (try? context.fetch(FetchDescriptor<ArticleState>())) ?? []
        let changes = subs.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.cloudRecordID) }
            + states.map { .saveRecord($0.cloudRecordID) }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
    }

    // MARK: - CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == CloudSchema.zoneID }) {
                // The zone was deleted (e.g. the user reset iCloud data):
                // forget sync metadata, keep the data, and re-upload it.
                clearSystemFields()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID))])
                enqueueAllLocalRecords()
            }

        case .fetchedRecordZoneChanges(let changes):
            applyFetched(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map { ($0.recordID, $0.recordType) }
            )

        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine)

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        let records = records(for: pending)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            records[id]
        }
    }

    /// Current local values for the pending saves. A record whose model no
    /// longer exists is left out, which drops it from the queue.
    private func records(for pending: [CKSyncEngine.PendingRecordZoneChange]) -> [CKRecord.ID: CKRecord] {
        let context = ModelContext(container)
        var result: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            guard case .saveRecord(let id) = change else { continue }
            let name = id.recordName
            if let uuid = UUID(uuidString: name),
               let sub = try? context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == uuid })).first {
                result[id] = sub.makeRecord()
            } else if let state = try? context.fetch(FetchDescriptor<ArticleState>(predicate: #Predicate { $0.articleKey == name })).first {
                result[id] = state.makeRecord()
            }
        }
        return result
    }

    // MARK: - Applying remote changes

    func applyFetched(modifications: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)]) {
        let context = applyContext
        var reupload: [CKRecord.ID] = []
        for record in modifications {
            let name = record.recordID.recordName
            switch record.recordType {
            case CloudSchema.RecordType.subscription:
                guard let uuid = UUID(uuidString: name) else { continue }
                if let local = try? context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == uuid })).first {
                    if CloudMerge.remoteWins(local: local.modifiedAt, remote: CloudMerge.modifiedAt(of: record)) {
                        local.apply(record)
                    } else {
                        local.cloudKitSystemFields = CloudSchema.archive(systemFieldsOf: record)
                        reupload.append(record.recordID)
                    }
                } else if let sub = Subscription(record: record) {
                    context.insert(sub)
                }
            case CloudSchema.RecordType.articleState:
                if let local = try? context.fetch(FetchDescriptor<ArticleState>(predicate: #Predicate { $0.articleKey == name })).first {
                    if CloudMerge.remoteWins(local: local.updatedAt, remote: CloudMerge.modifiedAt(of: record)) {
                        local.apply(record)
                    } else {
                        local.cloudKitSystemFields = CloudSchema.archive(systemFieldsOf: record)
                        reupload.append(record.recordID)
                    }
                } else if let state = ArticleState(record: record) {
                    context.insert(state)
                }
            default:
                continue
            }
        }
        for (id, type) in deletions where type == CloudSchema.RecordType.subscription {
            guard let uuid = UUID(uuidString: id.recordName) else { continue }
            let doomed = (try? context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == uuid }))) ?? []
            doomed.forEach(context.delete)
        }
        do {
            try context.save()
        } catch {
            log.error("Applying fetched changes failed: \(error, privacy: .public)")
        }
        if !reupload.isEmpty {
            engine?.state.add(pendingRecordZoneChanges: reupload.map { .saveRecord($0) })
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        let context = applyContext
        // Keep the server's system fields so the next save has the right change tag.
        for record in sent.savedRecords {
            storeSystemFields(of: record, in: context)
        }
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var needsZone = false
        var conflicts: [CKRecord] = []
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord { conflicts.append(server) }
            case .zoneNotFound:
                needsZone = true
                retry.append(.saveRecord(id))
            case .unknownItem:
                // Deleted on the server: forget our system fields and recreate it.
                clearSystemFields(for: id, in: context)
                retry.append(.saveRecord(id))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited:
                // CKSyncEngine retries these itself.
                break
            default:
                log.error("Saving \(id.recordName, privacy: .public) failed: \(failure.error, privacy: .public)")
            }
        }
        try? context.save()
        if needsZone {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID))])
        }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        // A conflict is just a fetched change that arrived late: merge it the
        // same way (newer wins; if ours is newer, it's queued again).
        if !conflicts.isEmpty { applyFetched(modifications: conflicts, deletions: []) }
    }

    private func storeSystemFields(of record: CKRecord, in context: ModelContext) {
        let name = record.recordID.recordName
        let data = CloudSchema.archive(systemFieldsOf: record)
        if record.recordType == CloudSchema.RecordType.subscription, let uuid = UUID(uuidString: name) {
            try? context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == uuid })).first?.cloudKitSystemFields = data
        } else if record.recordType == CloudSchema.RecordType.articleState {
            try? context.fetch(FetchDescriptor<ArticleState>(predicate: #Predicate { $0.articleKey == name })).first?.cloudKitSystemFields = data
        }
    }

    private func clearSystemFields(for id: CKRecord.ID, in context: ModelContext) {
        let name = id.recordName
        if let uuid = UUID(uuidString: name) {
            try? context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == uuid })).first?.cloudKitSystemFields = nil
        }
        try? context.fetch(FetchDescriptor<ArticleState>(predicate: #Predicate { $0.articleKey == name })).first?.cloudKitSystemFields = nil
    }

    private func clearSystemFields() {
        let context = applyContext
        (try? context.fetch(FetchDescriptor<Subscription>()))?.forEach { $0.cloudKitSystemFields = nil }
        (try? context.fetch(FetchDescriptor<ArticleState>()))?.forEach { $0.cloudKitSystemFields = nil }
        try? context.save()
    }

    // MARK: - Account changes

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            // Upload what was created while signed out.
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID))])
            enqueueAllLocalRecords()
        case .signOut:
            // Keep using the data locally; it uploads to whichever account
            // signs in next.
            clearSystemFields()
            resetEngine()
        case .switchAccounts:
            // Another person's iCloud: their data must not mix with this one's.
            deleteAllSyncedData()
            resetEngine()
        @unknown default:
            break
        }
    }

    private func deleteAllSyncedData() {
        let context = applyContext
        try? context.delete(model: Subscription.self)
        try? context.delete(model: ArticleState.self)
        try? context.save()
    }

    private func resetEngine() {
        try? FileManager.default.removeItem(at: stateURL)
        engine = nil
        start()
    }

    // MARK: - State persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            log.error("Saving sync state failed: \(error, privacy: .public)")
        }
    }
}
