import OSLog
import SrsslyCore
import SrsslyStore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Toolbar menu for subscribing: type a URL, or import an OPML file (e.g. a
/// Feedly export).
struct AddFeedsButton: View {
    @Environment(\.modelContext) private var context
    @Environment(\.feedRefresher) private var refresher

    @State private var showingURLPrompt = false
    @State private var typedURL = ""
    @State private var showingImporter = false
    @State private var message: String?

    private static let opmlTypes: [UTType] = [.opml, .xml]

    var body: some View {
        Menu {
            Button("Add Feed…", systemImage: "plus") { showingURLPrompt = true }
            Button("Import OPML…", systemImage: "square.and.arrow.down") { showingImporter = true }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .alert("Add Feed", isPresented: $showingURLPrompt) {
            TextField("Feed or site address", text: $typedURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Add") { addTyped() }
            Button("Cancel", role: .cancel) { typedURL = "" }
        } message: {
            Text("Paste a feed URL, or a site's address to find its feed.")
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.opmlTypes) { result in
            importOPML(result)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func addTyped() {
        defer { typedURL = "" }
        do {
            if try SubscriptionImporter.add(typed: typedURL, to: context) == nil {
                message = "That isn't a web address, or you're already subscribed to it."
                return
            }
            refreshSoon()
        } catch {
            message = "Couldn't add the feed: \(error.localizedDescription)"
        }
    }

    private func importOPML(_ result: Result<URL, Error>) {
        do {
            message = try OPMLFileImport.run(result.get(), context: context, refresher: refresher)
        } catch {
            message = "Couldn't import that file: \(error.localizedDescription)"
        }
    }

    private func refreshSoon() {
        guard let refresher else { return }
        Task { await refresher.refresh() }
    }
}

extension UTType {
    /// OPML subscription lists, declared in Info.plist so the app shows up
    /// for .opml files in Files, Drive and the share sheet.
    static let opml = UTType(importedAs: "org.opml.opml", conformingTo: .xml)
}

/// Subscribes to the feeds in an OPML file, whether picked in the app or
/// opened from another app (Files, Google Drive, the share sheet).
@MainActor
enum OPMLFileImport {
    /// Imports `url` and returns a message saying what happened.
    static func run(_ url: URL, context: ModelContext, refresher: FeedRefresher?) -> String {
        do {
            let feeds = try OPML.parse(try read(url))
            let summary = try SubscriptionImporter.add(feeds, to: context)
            if let refresher { Task { await refresher.refresh() } }
            return summary.duplicates > 0
                ? "Added \(summary.added) feeds. \(summary.duplicates) were already subscribed."
                : "Added \(summary.added) feeds."
        } catch {
            return "Couldn't import that file: \(error.localizedDescription)"
        }
    }

    /// Reads a file that may belong to another app or a cloud provider:
    /// asks for access, and coordinates so a not-yet-downloaded file is
    /// fetched first.
    private static func read(_ url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
