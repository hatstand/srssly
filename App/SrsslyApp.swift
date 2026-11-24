import OSLog
import SrsslyStore
import SwiftData
import SwiftUI

@main
struct SrsslyApp: App {
    let container: ModelContainer = Self.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }

    private static func makeContainer() -> ModelContainer {
        do {
            return try SrsslyStore.makeContainer()
        } catch {
            Logger(subsystem: "org.srssly.Srssly", category: "store")
                .fault("Opening the store failed: \(error, privacy: .public)")
            // Never block launch on the store: fall back to an empty in-memory
            // one so the UI still renders, and surface the problem in-app later.
            do {
                return try SrsslyStore.makeContainer(inMemory: true, cloudKit: false)
            } catch {
                fatalError("Could not create even an in-memory store: \(error)")
            }
        }
    }
}
