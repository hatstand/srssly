import CryptoKit
import Foundation

public enum FeedURL {
    /// A canonical string used to spot duplicate subscriptions, such as
    /// `http://www.popehat.com/feed/` and `https://popehat.com/feed`.
    ///
    /// It ignores the scheme, a leading `www.`, default ports, the fragment and a
    /// trailing slash. It is only for comparison: always fetch the real URL.
    public static func canonicalKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let port = components.port, port != 80, port != 443 {
            host += ":\(port)"
        }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        components.fragment = nil
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return host + path + query
    }

    /// The subscription ID for a feed: a version 5 UUID of its canonical key.
    ///
    /// Deterministic, so two devices that subscribe to the same feed (e.g. by
    /// importing the same OPML before they have synced) create the same
    /// CloudKit record, which then merges instead of duplicating. The ID is
    /// kept if the feed later moves.
    public static func subscriptionID(for url: URL) -> UUID {
        uuidV5(namespace: namespace, name: canonicalKey(for: url))
    }

    /// Srssly's UUIDv5 namespace for feed URLs.
    static let namespace = UUID(uuidString: "3b0f6f1e-6a3c-5d2b-9a57-5352535353c1")!

    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(Data(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
