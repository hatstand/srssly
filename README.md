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

The Xcode project is generated from `project.yml` and not committed.

### iCloud setup (once)

Unsigned simulator builds (and CI) run without iCloud: the synced store just stays local. To sync for real:

1. In Xcode, set your development team on the Srssly target. The bundle ID is `com.purplehatstands.srssly`.
2. In the Apple Developer portal, create the iCloud container `iCloud.com.purplehatstands.srssly` (Xcode offers to do this under Signing & Capabilities).
3. Run on two devices or simulators signed in to the same Apple Account.
4. Before the first TestFlight build, deploy the CloudKit schema to production in the CloudKit Console.

## Data

- **Synced store** (CloudKit private database): `Subscription` and `ArticleState` (read/starred, only for articles you have touched). CloudKit rules apply: no unique constraints, every property optional or defaulted.
- **Local store** (this device only): `Article` and `FeedFetchState`. Each device fetches feeds itself, so this is a rebuildable cache.

Articles join to their state by `ArticleKey`, derived from the subscription's synced ID and the item's GUID (or link), so it matches across devices.

## Layout

- `App/`: the SwiftUI app target.
- `Packages/SrsslyCore/`: two libraries testable with `swift test` on a Mac: `SrsslyCore` (pure logic) and `SrsslyStore` (SwiftData models and container).
