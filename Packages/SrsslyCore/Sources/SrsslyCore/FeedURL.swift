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
}
