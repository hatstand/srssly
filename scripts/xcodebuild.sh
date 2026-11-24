#!/usr/bin/env bash
# Runs xcodebuild against the first available iPhone simulator.
# Usage: scripts/xcodebuild.sh build|test
set -euo pipefail
action="${1:-build}"
udid=$(xcrun simctl list devices available -j \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for k,v in sorted(d.items(), reverse=True) if "iOS" in k for x in v if x["name"].startswith("iPhone")))')
xcodebuild "$action" \
  -project Srssly.xcodeproj \
  -scheme Srssly \
  -destination "id=$udid" \
  CODE_SIGNING_ALLOWED=NO \
  | (command -v xcpretty >/dev/null && xcpretty || cat)
exit "${PIPESTATUS[0]}"
