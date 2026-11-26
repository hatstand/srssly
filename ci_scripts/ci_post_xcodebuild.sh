#!/bin/sh
# Xcode Cloud runs this after each action. For archives it writes TestFlight's
# "What to Test" notes from the commits since the previous build, which
# Xcode Cloud picks up from TestFlight/WhatToTest.en-US.txt.
set -eu

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0
cd "$CI_PRIMARY_REPOSITORY_PATH"
mkdir -p TestFlight

# Xcode Cloud clones shallowly; fetch enough history to have something to list.
git fetch --deepen 50 --quiet 2>/dev/null || true
{
    echo "Build ${CI_BUILD_NUMBER:-?} from ${CI_BRANCH:-${CI_TAG:-unknown}} ($(git rev-parse --short HEAD))"
    echo
    # Merge commits carry the PR titles; fall back to plain commits.
    notes=$(git log -20 --merges --format='%b' | grep -v '^$' | head -15 | sed 's/^/- /')
    [ -n "$notes" ] || notes=$(git log -15 --no-merges --format='- %s')
    echo "$notes"
} | cut -c1-200 | head -c 3900 > TestFlight/WhatToTest.en-US.txt
cat TestFlight/WhatToTest.en-US.txt
