import Foundation
import SwiftData

public enum SrsslyStore {
    /// Synced through the app's CloudKit private database.
    public static var syncedModels: [any PersistentModel.Type] { [Subscription.self, ArticleState.self] }
    /// Kept on this device only.
    public static var localModels: [any PersistentModel.Type] { [Article.self, FeedFetchState.self] }

    /// Builds the app's container: a synced store and a local store.
    ///
    /// - Parameters:
    ///   - inMemory: for tests and previews.
    ///   - cloudKit: sync the synced store via CloudKit. With `.automatic`,
    ///     SwiftData uses the container in the app's entitlements, and stays
    ///     local when there are none (unsigned simulator builds, CI).
    public static func makeContainer(inMemory: Bool = false, cloudKit: Bool = true) throws -> ModelContainer {
        let synced = ModelConfiguration(
            "Synced",
            schema: Schema(syncedModels),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloudKit ? .automatic : .none
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
