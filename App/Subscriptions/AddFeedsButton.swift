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

    private static let opmlTypes: [UTType] = [
        UTType(filenameExtension: "opml") ?? .xml, .xml,
    ]

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
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let feeds = try OPML.parse(try Data(contentsOf: url))
            let summary = try SubscriptionImporter.add(feeds, to: context)
            message = summary.duplicates > 0
                ? "Added \(summary.added) feeds. \(summary.duplicates) were already subscribed."
                : "Added \(summary.added) feeds."
            refreshSoon()
        } catch {
            message = "Couldn't import that file: \(error.localizedDescription)"
        }
    }

    private func refreshSoon() {
        guard let refresher else { return }
        Task { await refresher.refresh() }
    }
}
