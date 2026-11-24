import Foundation
import SwiftData

public enum SrsslyStore {
    /// User-authored state that `CloudSync` syncs through CloudKit.
    public static var syncedModels: [any PersistentModel.Type] { [Subscription.self, ArticleState.self] }
    /// Kept on this device only.
    public static var localModels: [any PersistentModel.Type] { [Article.self, FeedFetchState.self] }

    /// Builds the app's container: a store for synced models and one for
    /// device-only models.
    ///
    /// Both are plain local SwiftData stores. SwiftData's own CloudKit
    /// mirroring is deliberately off: `CloudSync` syncs the synced models
    /// with a CloudKit schema we define, so other clients (e.g. a web app
    /// using CloudKit JS) can read and write the same records.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let synced = ModelConfiguration(
            "Synced",
            schema: Schema(syncedModels),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "Local",
            schema: Schema(localModels),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(syncedModels + localModels),
            configurations: [synced, local]
        )
    }
}
