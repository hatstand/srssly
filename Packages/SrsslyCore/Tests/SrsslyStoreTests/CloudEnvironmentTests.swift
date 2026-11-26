import Foundation
import Testing
@testable import SrsslyStore

struct CloudEnvironmentTests {
    /// A profile's shape: binary CMS wrapping around a plain XML plist.
    private func profile(aps: String) -> Data {
        var data = Data([0x30, 0x82, 0x4e, 0x1f, 0x06, 0x09])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>iOS Team Provisioning Profile</string>
        <key>Entitlements</key><dict><key>aps-environment</key><string>\(aps)</string></dict>
        </dict></plist>
        """.utf8))
        data.append(Data([0xa0, 0x82, 0x0d, 0x00]))
        return data
    }

    @Test func developmentProfile() {
        #expect(CloudEnvironment.environment(profile: profile(aps: "development")) == "development")
    }

    @Test func distributionProfile() {
        #expect(CloudEnvironment.environment(profile: profile(aps: "production")) == "production")
    }

    @Test func noProfileIsProduction() {
        #expect(CloudEnvironment.environment(profile: nil) == "production")
        #expect(CloudEnvironment.environment(profile: Data([0x30, 0x82])) == "production")
    }
}
