import Foundation
import Testing
@testable import SrsslyCore

@Suite struct FeedURLTests {
    private func key(_ s: String) -> String { FeedURL.canonicalKey(for: URL(string: s)!) }

    @Test func ignoresSchemeWwwAndTrailingSlash() {
        #expect(key("http://www.popehat.com/feed/") == key("https://popehat.com/feed"))
    }

    @Test func ignoresCaseOfHostButNotPath() {
        #expect(key("https://XKCD.com/rss.xml") == "xkcd.com/rss.xml")
        #expect(key("https://xkcd.com/RSS.xml") != key("https://xkcd.com/rss.xml"))
    }

    @Test func keepsQueryAndDropsFragment() {
        #expect(key("http://feeds.feedburner.com/LookingForGroup?format=xml#top")
            == "feeds.feedburner.com/LookingForGroup?format=xml")
    }

    @Test func keepsNonDefaultPortsOnly() {
        #expect(key("https://example.com:443/feed") == "example.com/feed")
        #expect(key("https://example.com:8443/feed") == "example.com:8443/feed")
    }

    @Test func distinguishesDifferentFeedsOnSameSite() {
        #expect(key("https://popehat.substack.com/feed") != key("https://www.popehat.com/feed/"))
    }
}

@Suite struct SubscriptionIDTests {
    @Test func sameFeedGivesSameIDOnAnyDevice() {
        let a = FeedURL.subscriptionID(for: URL(string: "http://www.popehat.com/feed/")!)
        let b = FeedURL.subscriptionID(for: URL(string: "https://popehat.com/feed")!)
        #expect(a == b)
        #expect(a != FeedURL.subscriptionID(for: URL(string: "https://popehat.substack.com/feed")!))
    }

    @Test func isAVersion5UUID() {
        let id = FeedURL.subscriptionID(for: URL(string: "https://xkcd.com/rss.xml")!).uuidString
        let chars = Array(id)
        #expect(chars[14] == "5")
        #expect("89AB".contains(chars[19]))
    }

    @Test func matchesRFC4122TestVector() {
        // Python: uuid.uuid5(uuid.NAMESPACE_DNS, "python.org")
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        #expect(FeedURL.uuidV5(namespace: dns, name: "python.org").uuidString.lowercased() == "886313e1-3b8a-5372-9b90-0c9aee199e5d")
    }
}
