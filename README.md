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

`rust/` holds the Rust sync core, starting with key management for end-to-end encrypted sync ([rust/srssly-keys](rust/srssly-keys/README.md)). Run `cargo test` there.

### iCloud setup (once)

CI runs the app with `-SrsslySampleData`, which never starts sync. Local builds are signed with the team in `project.yml`, which includes the iCloud entitlement that sync needs. To sync for real:

1. The development team (`CZ8XD8GTGZ`) and bundle ID (`com.purplehatstands.srssly`) are set in `project.yml`.
2. In the Apple Developer portal, create the iCloud container `iCloud.com.purplehatstands.srssly` (Xcode offers to do this under Signing & Capabilities).
3. Run on two devices or simulators signed in to the same Apple Account.
4. Before the first TestFlight build, deploy the CloudKit schema to production (see [docs/cloudkit-schema.md](docs/cloudkit-schema.md#deploying)).

### TestFlight

See [docs/testflight.md](docs/testflight.md) for the Xcode Cloud workflow and the one-time App Store Connect setup.

## Data

- **Synced store**: `Subscription` and `ArticleState` (read/starred, only for articles you have touched). `CloudSync` syncs these with `CKSyncEngine` using our own CloudKit record types, so a web client can share them. See [docs/cloudkit-schema.md](docs/cloudkit-schema.md).
- **Local store** (this device only): `Article` and `FeedFetchState`. Each device fetches feeds itself, so this is a rebuildable cache.

- **Offline cache** (this device only): saved pages, images and stylesheets in Application Support/OfflineCache, excluded from backups. `OfflineCacher` fills it for articles from the last 30 days, newest first. It keeps starred articles and prunes everything else after 30 days or past 1 GB. Each subscription's cache mode decides what's saved: the feed's own content and its images, or the full linked page. `automatic` picks one from the feed with `CacheModeDetector`.

Articles join to their state by `ArticleKey`, derived from the subscription's synced ID and the item's GUID (or link), so it matches across devices.

## CI

- **GitHub Actions** (`.github/workflows/ci.yml`) runs on every pull request: package tests and app tests on a simulator.
- **Xcode Cloud** builds for TestFlight and the App Store. `ci_scripts/ci_post_clone.sh` sets the build number to Xcode Cloud's and generates the Xcode project, since it isn't committed. `ci_scripts/ci_post_xcodebuild.sh` writes TestFlight's "What to Test" notes from recent merges.

## Layout

- `App/`: the SwiftUI app target.
- `Packages/SrsslyCore/`: two libraries testable with `swift test` on a Mac: `SrsslyCore` (pure logic) and `SrsslyStore` (SwiftData models and container).
