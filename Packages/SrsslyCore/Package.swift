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
    targets: [
        .target(name: "SrsslyCore"),
        .target(name: "SrsslyStore", dependencies: ["SrsslyCore"]),
        .testTarget(name: "SrsslyCoreTests", dependencies: ["SrsslyCore"]),
        .testTarget(name: "SrsslyStoreTests", dependencies: ["SrsslyStore"]),
    ]
)
