#!/bin/sh
# Xcode Cloud runs this after cloning. The Xcode project isn't committed
# (it's generated from project.yml), so generate it before Xcode Cloud
# looks for the project and scheme.
set -eu

brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
