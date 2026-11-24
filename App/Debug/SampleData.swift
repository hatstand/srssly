#if DEBUG
import SrsslyCore
import SrsslyStore
import SwiftData
import SwiftUI

/// Fake data for previews and UI tests. Launch with `-SrsslySampleData` to
/// use it instead of the real store.
@MainActor
enum SampleData {
    static let launchArgument = "-SrsslySampleData"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static func container() -> ModelContainer {
        let container = try! SrsslyStore.makeContainer(inMemory: true)
        populate(container.mainContext)
        return container
    }

    static func populate(_ context: ModelContext) {
        let feeds: [(String, String, String)] = [
            ("xkcd", "https://xkcd.com/rss.xml", "Comics"),
            ("Saturday Morning Breakfast Cereal", "https://www.smbc-comics.com/comic/rss", "Comics"),
            ("Ars Technica", "https://feeds.arstechnica.com/arstechnica/index", "IT"),
            ("The Old New Thing", "https://devblogs.microsoft.com/oldnewthing/feed", "Programming"),
        ]
        let now = Date.now
        let sortKeys = SortKey.keys(between: nil, nil, count: feeds.count)
        for (index, (title, url, folder)) in feeds.enumerated() {
            let sub = Subscription(feedURL: URL(string: url)!, title: title, folder: folder)
            sub.sortKey = sortKeys[index]
            context.insert(sub)
            for n in 0..<25 {
                let guid = "\(url)#\(n)"
                let key = ArticleKey.make(subscriptionID: sub.id, guid: guid, link: nil, title: nil, published: nil)
                context.insert(Article(
                    key: key,
                    subscriptionID: sub.id,
                    guid: guid,
                    title: "\(title) sample article \(n + 1)",
                    link: URL(string: url),
                    publishedAt: now.addingTimeInterval(-Double(n * 3600 + index * 600)),
                    summaryHTML: "<p>Sample summary.</p>"
                ))
                if n % 3 == 0 { context.insert(ArticleState(articleKey: key, isRead: true)) }
            }
        }
        try? context.save()
    }
}
#endif
