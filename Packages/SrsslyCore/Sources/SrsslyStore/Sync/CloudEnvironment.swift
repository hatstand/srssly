import Foundation

/// Which CloudKit environment this build talks to.
///
/// iOS has no API for it, so read the app's provisioning profile:
/// development builds embed one with `aps-environment` set to
/// `development` and use the development database. TestFlight and App Store
/// builds have no embedded profile (or a distribution one) and use
/// production.
public enum CloudEnvironment {
    public static let development = "development"
    public static let production = "production"

    public static let current: String = environment(
        profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
    )

    /// The environment for a provisioning profile's contents (nil: none).
    static func environment(profile: Data?) -> String {
        guard let profile, let plist = plist(inProfile: profile),
              let entitlements = plist["Entitlements"] as? [String: Any],
              entitlements["aps-environment"] as? String == development
        else { return production }
        return development
    }

    /// A profile is a signed CMS message with the plist stored as plain XML.
    private static func plist(inProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let xml = data[start.lowerBound..<end.upperBound]
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }
}
