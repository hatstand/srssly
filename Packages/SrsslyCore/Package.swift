// swift-tools-version: 6.2
import PackageDescription

// Logic that doesn't need UIKit lives here so it can be tested with `swift test`
// on a Mac, without a simulator.
//  - SrsslyCore: pure logic (parsing, normalisation, scheduling).
//  - SrsslyStore: SwiftData models and the persistent container.
let package = Package(
    name: "SrsslyCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SrsslyCore", targets: ["SrsslyCore"]),
        .library(name: "SrsslyStore", targets: ["SrsslyStore"]),
    ],
    dependencies: [
        // HTML parsing (a port of jsoup). Pinned exactly: Package.resolved
        // isn't committed, and a parser sees untrusted pages.
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
    ],
    targets: [
        .target(name: "SrsslyCore", dependencies: ["SwiftSoup"]),
        .target(name: "SrsslyStore", dependencies: ["SrsslyCore"]),
        .testTarget(name: "SrsslyCoreTests", dependencies: ["SrsslyCore", "SwiftSoup"]),
        .testTarget(name: "SrsslyStoreTests", dependencies: ["SrsslyStore"]),
    ]
)
