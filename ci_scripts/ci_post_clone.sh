#!/bin/sh
# Xcode Cloud runs this after cloning. The Xcode project isn't committed
# (it's generated from project.yml), so generate it before Xcode Cloud
# looks for the project and scheme.
set -eu

brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"

# Build number: Xcode Cloud's own counter, so every upload to App Store
# Connect is unique and the binary's CFBundleVersion matches the build
# shown in Xcode Cloud and TestFlight. Local builds keep project.yml's "1".
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
    sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$CI_BUILD_NUMBER\"/" project.yml
    grep -q "CURRENT_PROJECT_VERSION: \"$CI_BUILD_NUMBER\"" project.yml
fi

# The Rust key core (Packages/SrsslyKeys) is built from source. Xcode Cloud
# has no Rust, so install rustup first, then the toolchain rust-toolchain.toml
# pins.
if ! command -v rustup >/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
    . "$HOME/.cargo/env"
fi
rustup toolchain install
./scripts/build-rust-ios.sh

xcodegen generate

# Xcode Cloud builds with automatic package resolution off, so it needs a
# Package.resolved. That lives inside the generated project, so resolve
# packages (SwiftSoup) here to create it, turning resolution back on just
# for this step. Versions are pinned exactly in
# Packages/SrsslyCore/Package.swift, so this can't pick up anything new.
defaults write com.apple.dt.Xcode IDEPackageOnlyUseVersionsFromResolvedFile -bool NO
defaults write com.apple.dt.Xcode IDEDisableAutomaticPackageResolution -bool NO
xcodebuild -resolvePackageDependencies -project Srssly.xcodeproj -scheme Srssly
