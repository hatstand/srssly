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
