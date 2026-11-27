#!/usr/bin/env bash
# Fails if a built srssly-keys-ffi static library contains SoftPasskey or
# RecoveryKey::words. The real guard is that the FFI crate enables none of
# srssly-keys' test-only features (rust.yml checks that); this is a backstop.
# It matches mangled names (v0 and legacy both length-prefix identifiers), so
# it can't see code that was inlined away: RootSecret::export and
# PrfOutput::export always are, so only the feature check covers them.
# Usage: scripts/check-app-lib.sh <lib.a>...
set -euo pipefail
pattern='SoftPasskey|RecoveryKey5words'
# Xcode's nm can be on an older LLVM than rustc and then can't read Rust's
# objects, so prefer the llvm-nm shipped with the Rust toolchain
# (`rustup component add llvm-tools`), and let NM override both.
if [ -z "${NM:-}" ]; then
  NM=nm
  host=$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')
  rust_nm="$(rustc --print sysroot 2>/dev/null)/lib/rustlib/$host/bin/llvm-nm"
  [ -x "$rust_nm" ] && NM=$rust_nm
fi
for lib in "$@"; do
  # Not in a pipeline, so a failing nm fails the script.
  symbols=$("$NM" "$lib")
  if [ -z "$symbols" ]; then
    echo "$lib: nm listed no symbols" >&2
    exit 1
  fi
  if grep -E "$pattern" <<<"$symbols"; then
    echo "$lib contains test-only or secret-export code" >&2
    exit 1
  fi
done
