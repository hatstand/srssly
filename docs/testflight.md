# TestFlight

Xcode Cloud archives `main` and uploads it to TestFlight. Most of it is in
the repo; the steps below happen in Apple's web consoles and Xcode, and only
the account holder can do them.

## What the repo handles

- **Build number**: `ci_post_clone.sh` sets `CURRENT_PROJECT_VERSION` to
  `CI_BUILD_NUMBER`, so every upload is unique. The marketing version is
  `MARKETING_VERSION` in `project.yml`; bump it by hand per release.
- **Export compliance**: `ITSAppUsesNonExemptEncryption = NO` (only HTTPS
  and CloudKit, which are exempt), so builds don't stop at the encryption
  question.
- **Privacy manifest**: `App/PrivacyInfo.xcprivacy`. No tracking, no data
  collected; declares `UserDefaults` (reason `CA92.1`).
- **Usage strings**: none needed. The app uses no camera, photos, location,
  contacts or other protected resources. Background modes (fetch,
  processing, remote notifications) don't need one.
- **Entitlements**: iCloud/CloudKit and push. The archive is signed with
  `aps-environment = development`; the App Store Connect export re-signs it
  for production push and the production CloudKit environment.
- **What to Test notes**: `ci_post_xcodebuild.sh` lists recent merges.

## One-time setup

1. **App record.** In [App Store Connect](https://appstoreconnect.apple.com/apps)
   → Apps → + → New App: platform iOS, name (e.g. "Srssly"; must be unique on
   the store), primary language, bundle ID `com.purplehatstands.srssly`, SKU
   (anything, e.g. `srssly`), full access.
2. **CloudKit production schema.** Follow
   [cloudkit-schema.md → Deploying](cloudkit-schema.md#deploying). Without it
   TestFlight builds can't sync (saves fail with "unknown record type").
3. **Xcode Cloud workflow.** In Xcode: Integrate → Manage Workflows (or App
   Store Connect → the app → Xcode Cloud → Manage Workflows), edit the
   default workflow or add one named "TestFlight":
   - Start condition: branch changes on `main` (and "auto-cancel builds" on).
   - Environment: latest release Xcode 26, latest macOS.
   - Actions: **Archive**, platform iOS, scheme `Srssly`, deployment
     preparation **TestFlight (Internal Testing Only)** for now, or
     **TestFlight and App Store** once external testers or release are near.
   - Post-actions: **TestFlight Internal Testing**, group from step 4.
   - Leave the existing PR-checks out of Xcode Cloud: GitHub Actions does
     those, and Xcode Cloud compute hours are limited (25 a month free).
   - If Xcode Cloud asks for access to Swift package repos (SwiftSoup on
     GitHub), grant it.
4. **Internal testers.** App Store Connect → the app → TestFlight →
   Internal Testing → +: create a group (e.g. "Me"), add yourself, and turn
   on "Automatic distribution". Install the TestFlight app on the phone and
   accept the invite.
5. **First build.** Push or merge to `main` (or Start Build on the workflow).
   After processing (~10–30 min), it shows up in TestFlight. If App Store
   Connect rejects a build number as already used, set "Next Build Number"
   in the Xcode Cloud settings above the highest one uploaded.

## Before external testers or the App Store

External TestFlight groups go through Beta App Review, which needs:

- Beta App Information: feedback email, description, and a privacy policy
  URL. A short page saying "Srssly collects no data; subscriptions and read
  state sync through your own iCloud account" is enough (GitHub Pages works).
- App Privacy (App Store Connect → the app → App Privacy): answer
  **Data Not Collected**, matching the privacy manifest.
- Age rating questionnaire (a reader showing arbitrary web content usually
  lands at 17+ via "Unrestricted Web Access" — check the current wording).
- Contact info and sign-in notes for the reviewer (no sign-in needed).

## Checking a TestFlight build

- Launch on a device signed in to iCloud; add a feed; on a second device (or
  after reinstalling) the subscription should appear. If not, check the
  CloudKit Console's **Production** environment for records in the `Srssly`
  zone, and the device log for CKError messages.
- Development data does not carry over: production starts empty, so
  re-import the OPML on the TestFlight build.
