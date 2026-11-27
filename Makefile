.PHONY: project open test test-core

project:
	./scripts/build-rust-ios.sh
	xcodegen generate

open: project
	open Srssly.xcodeproj

test-core:
	swift test --package-path Packages/SrsslyCore

test: project
	./scripts/xcodebuild.sh test
