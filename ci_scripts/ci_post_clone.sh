#!/bin/sh
# Xcode Cloud runs this after cloning. The Xcode project isn't committed
# (it's generated from project.yml), so generate it before Xcode Cloud
# looks for the project and scheme.
set -eu

brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

# Xcode Cloud builds with automatic package resolution off, so it needs a
# Package.resolved. That lives inside the generated project, so resolve
# packages (SwiftSoup) here to create it. Versions are pinned exactly in
# Packages/SrsslyCore/Package.swift.
xcodebuild -resolvePackageDependencies -project Srssly.xcodeproj -scheme Srssly
