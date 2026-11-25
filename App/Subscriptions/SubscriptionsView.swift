import SrsslyCore
import SrsslyStore
import SwiftData
import SwiftUI

/// Every subscription, grouped by folder, in the user's order. Drag to
/// reorder, swipe to unsubscribe, tap for a feed's articles and settings.
struct SubscriptionsView: View {
    @Query(sort: [SortDescriptor(\Subscription.sortKey), SortDescriptor(\Subscription.title)])
    private var subscriptions: [Subscription]
    @Query private var fetchStates: [FeedFetchState]
    @Environment(\.modelContext) private var context
    @Environment(\.cloudSync) private var cloudSync

    var body: some View {
        let errors = Dictionary(fetchStates.compactMap { s in s.lastError.map { (s.subscriptionID, $0) } }, uniquingKeysWith: { a, _ in a })
        List {
            ForEach(folders, id: \.self) { folder in
                let subs = subscriptions.filter { ($0.folder ?? "") == folder }
                Section(folder.isEmpty ? "Feeds" : folder) {
                    ForEach(subs) { sub in
                        NavigationLink(value: sub) {
                            SubscriptionRow(subscription: sub, hasError: errors[sub.id] != nil)
                        }
                    }
                    .onMove { move(subs, from: $0, to: $1) }
                    .onDelete { offsets in offsets.map { subs[$0] }.forEach(unsubscribe) }
                }
            }
        }
        .navigationTitle("Subscriptions")
        .toolbar { EditButton() }
        .overlay {
            if subscriptions.isEmpty {
                ContentUnavailableView("No Subscriptions", systemImage: "dot.radiowaves.up.forward")
            }
        }
    }

    /// Folder names in the order their first feed appears.
    private var folders: [String] {
        var seen = Set<String>()
        return subscriptions.map { $0.folder ?? "" }.filter { seen.insert($0).inserted }
    }

    /// Gives the moved feed a sort key between its new neighbours, so
    /// nothing else is renumbered (and concurrent reorders merge).
    private func move(_ subs: [Subscription], from source: IndexSet, to destination: Int) {
        guard let from = source.first, source.count == 1 else { return }
        var reordered = subs
        reordered.move(fromOffsets: source, toOffset: destination)
        guard let index = reordered.firstIndex(where: { $0.id == subs[from].id }) else { return }
        let before = index > 0 ? reordered[index - 1].sortKey : nil
        let after = index + 1 < reordered.count ? reordered[index + 1].sortKey : nil
        if let before, let after, before >= after { return } // Duplicate keys; leave as is.
        let moved = reordered[index]
        moved.sortKey = SortKey.between(before, after)
        moved.modifiedAt = .now
        try? context.save()
    }

    private func unsubscribe(_ sub: Subscription) {
        let id = sub.id
        context.delete(sub)
        try? context.save()
        try? SubscriptionCleanup.removeOrphans(in: context)
        // Deletes the CloudKit record so other devices drop it too.
        if let cloudSync { Task { try? await cloudSync.deleteSubscription(id: id) } }
    }
}

struct SubscriptionRow: View {
    let subscription: Subscription
    let hasError: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.title.isEmpty ? (subscription.feedURL?.host ?? "Untitled") : subscription.title)
                if let host = (subscription.siteURL ?? subscription.feedURL)?.host {
                    Text(host).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Last refresh failed")
            }
        }
    }
}
