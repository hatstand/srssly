// swift-tools-version: 6.2
import PackageDescription

// Platform-independent logic (parsing, normalisation, scheduling) lives here so
// it can be tested with `swift test` without a simulator.
let package = Package(
    name: "SrsslyCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SrsslyCore", targets: ["SrsslyCore"]),
    ],
    targets: [
        .target(name: "SrsslyCore"),
        .testTarget(name: "SrsslyCoreTests", dependencies: ["SrsslyCore"]),
    ]
)
