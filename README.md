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

CI runs the app with `-SrsslySampleData`, which never starts sync. Local builds are signed with the team in `project.yml`, which includes the iCloud entitlement that sync needs. To sync for real:

1. The development team (`CZ8XD8GTGZ`) and bundle ID (`com.purplehatstands.srssly`) are set in `project.yml`.
2. In the Apple Developer portal, create the iCloud container `iCloud.com.purplehatstands.srssly` (Xcode offers to do this under Signing & Capabilities).
3. Run on two devices or simulators signed in to the same Apple Account.
4. Before the first TestFlight build, deploy the CloudKit schema to production in the CloudKit Console (see [docs/cloudkit-schema.md](docs/cloudkit-schema.md)).

## Data

- **Synced store**: `Subscription` and `ArticleState` (read/starred, only for articles you have touched). `CloudSync` syncs these with `CKSyncEngine` using our own CloudKit record types, so a web client can share them. See [docs/cloudkit-schema.md](docs/cloudkit-schema.md).
- **Local store** (this device only): `Article` and `FeedFetchState`. Each device fetches feeds itself, so this is a rebuildable cache.

Articles join to their state by `ArticleKey`, derived from the subscription's synced ID and the item's GUID (or link), so it matches across devices.

## CI

- **GitHub Actions** (`.github/workflows/ci.yml`) runs on every pull request: package tests and app tests on a simulator.
- **Xcode Cloud** builds for TestFlight and the App Store. `ci_scripts/ci_post_clone.sh` generates the Xcode project after Xcode Cloud clones the repo, since it isn't committed.

## Layout

- `App/`: the SwiftUI app target.
- `Packages/SrsslyCore/`: two libraries testable with `swift test` on a Mac: `SrsslyCore` (pure logic) and `SrsslyStore` (SwiftData models and container).
