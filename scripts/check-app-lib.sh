#!/usr/bin/env bash
# Fails if a built srssly-keys-ffi static library contains test-only or
# secret-export code: SoftPasskey, RootSecret::export, PrfOutput::export or
# RecoveryKey::words. The real guard is that the FFI crate enables none of
# srssly-keys' features (rust.yml checks that too); this is a backstop. It
# matches mangled names, so it can't see code that was inlined away.
# Usage: scripts/check-app-lib.sh <lib.a>...
set -euo pipefail
pattern='SoftPasskey|RootSecret6export|PrfOutput6export|RecoveryKey5words'
for lib in "$@"; do
  # Not in a pipeline, so a failing nm fails the script.
  symbols=$(nm "$lib")
  if [ -z "$symbols" ]; then
    echo "$lib: nm listed no symbols" >&2
    exit 1
  fi
  if grep -E "$pattern" <<<"$symbols"; then
    echo "$lib contains test-only or secret-export code" >&2
    exit 1
  fi
done
