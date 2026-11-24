import CryptoKit
import Foundation

/// A stable identifier for an article, the same on every device.
///
/// Devices fetch feeds independently, so read/starred state (which syncs) is
/// keyed by this rather than by any local database ID. It is derived from the
/// subscription's synced ID plus the item's identity in the feed, so it
/// survives the feed URL changing.
public enum ArticleKey {
    public static func make(
        subscriptionID: UUID,
        guid: String?,
        link: String?,
        title: String?,
        published: Date?
    ) -> String {
        let identity: String
        if let guid = nonEmpty(guid) {
            identity = "g:" + guid
        } else if let link = nonEmpty(link) {
            identity = "l:" + link
        } else {
            let seconds = published.map { String(Int($0.timeIntervalSince1970)) } ?? ""
            identity = "t:" + (title ?? "") + "|" + seconds
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return subscriptionID.uuidString.lowercased() + ":" + hex
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
