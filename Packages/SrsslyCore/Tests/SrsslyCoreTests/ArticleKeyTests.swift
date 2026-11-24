import Foundation
import Testing
@testable import SrsslyCore

@Suite struct ArticleKeyTests {
    let sub = UUID(uuidString: "6F1C2D3E-0000-4000-8000-000000000001")!

    @Test func isStableAndScopedToSubscription() {
        let a = ArticleKey.make(subscriptionID: sub, guid: "https://xkcd.com/3000/", link: nil, title: nil, published: nil)
        let b = ArticleKey.make(subscriptionID: sub, guid: "https://xkcd.com/3000/", link: "ignored", title: "x", published: .now)
        #expect(a == b)
        #expect(a.hasPrefix("6f1c2d3e-0000-4000-8000-000000000001:"))
        let other = ArticleKey.make(subscriptionID: UUID(), guid: "https://xkcd.com/3000/", link: nil, title: nil, published: nil)
        #expect(a != other)
    }

    @Test func fallsBackToLinkThenTitleAndDate() {
        let byLink = ArticleKey.make(subscriptionID: sub, guid: "  ", link: "https://a/1", title: nil, published: nil)
        #expect(byLink == ArticleKey.make(subscriptionID: sub, guid: nil, link: "https://a/1", title: "other", published: nil))

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let byTitle = ArticleKey.make(subscriptionID: sub, guid: nil, link: nil, title: "Hi", published: date)
        #expect(byTitle != ArticleKey.make(subscriptionID: sub, guid: nil, link: nil, title: "Hi", published: date.addingTimeInterval(60)))
    }

    @Test func guidAndLinkWithSameTextDoNotCollide() {
        let g = ArticleKey.make(subscriptionID: sub, guid: "x", link: nil, title: nil, published: nil)
        let l = ArticleKey.make(subscriptionID: sub, guid: nil, link: "x", title: nil, published: nil)
        #expect(g != l)
    }
}
