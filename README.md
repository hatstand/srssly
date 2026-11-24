# Srssly

A fast, local-first RSS reader for iOS.

- **Instant launch.** The app always renders from on-device data first. No splash screens, no loading walls.
- **Offline reading.** Articles, images and (for summary-only feeds) full pages are cached on device.
- **iCloud sync.** Subscriptions and read/starred state sync across devices through CloudKit. Each device fetches feeds itself; there is no Srssly server.

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make open        # generate Srssly.xcodeproj and open it
make test-core   # run SrsslyCore tests (no simulator needed)
make test        # run app tests on a simulator
```

The Xcode project is generated from `project.yml` and not committed. Set your development team in Xcode before running on a device.

## Layout

- `App/`: the SwiftUI app target.
- `Packages/SrsslyCore/`: platform-independent logic, testable with `swift test`.
