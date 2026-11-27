#!/usr/bin/env bash
# Builds the Rust key core (rust/srssly-keys-ffi) for iOS devices and the
# Apple-silicon simulator, and writes the two generated parts of
# Packages/SrsslyKeys: SrsslyKeysFFI.xcframework and the Swift bindings.
# Needs rustup (https://rustup.rs). `make project`, CI and Xcode Cloud run it.
set -euo pipefail
cd "$(dirname "$0")/.."

targets=(aarch64-apple-ios aarch64-apple-ios-sim)
pkg=Packages/SrsslyKeys
out=rust/target/ios
cargo=(cargo --quiet)
manifest=(--manifest-path rust/Cargo.toml --locked)

rustup target add "${targets[@]}"
export IPHONEOS_DEPLOYMENT_TARGET=26.0
xcframework_args=()
for target in "${targets[@]}"; do
  "${cargo[@]}" build "${manifest[@]}" --release -p srssly-keys-ffi --lib --target "$target"
  xcframework_args+=(-library "rust/target/$target/release/libsrssly_keys_ffi.a" -headers "$out/headers")
done

rm -rf "$out" "$pkg/SrsslyKeysFFI.xcframework"
# uniffi-bindgen runs `cargo metadata` in its working directory to find the
# crate's uniffi.toml, so run it from the workspace.
(cd rust && "${cargo[@]}" run --locked -p uniffi-bindgen -- generate --language swift \
  --library "target/${targets[0]}/release/libsrssly_keys_ffi.a" --out-dir "target/ios/bindings")
mkdir -p "$out/headers" "$pkg/Sources/SrsslyKeys"
cp "$out/bindings/SrsslyKeysFFI.h" "$out/headers/"
cp "$out/bindings/SrsslyKeysFFI.modulemap" "$out/headers/module.modulemap"
cp "$out/bindings/SrsslyKeys.swift" "$pkg/Sources/SrsslyKeys/"
xcodebuild -create-xcframework "${xcframework_args[@]}" -output "$pkg/SrsslyKeysFFI.xcframework"
