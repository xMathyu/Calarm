#!/bin/sh
#
# Xcode Cloud pre-build hook. Runs before `xcodebuild`.
# Bumps CFBundleVersion (CURRENT_PROJECT_VERSION) to the total count of git
# commits — same logic as the local Archive scheme pre-action so build numbers
# stay consistent whether you archive locally or via Xcode Cloud.
#

set -euo pipefail

echo "▸ ci_pre_xcodebuild.sh: setting build number from git commit count"

# Xcode Cloud clones the repo with shallow history by default, which makes
# `git rev-list --count HEAD` return a low/wrong number. Deepen to full history
# before counting. Ignore failures (e.g. when already complete locally).
git -C "$CI_PRIMARY_REPOSITORY_PATH" fetch --unshallow 2>/dev/null \
    || git -C "$CI_PRIMARY_REPOSITORY_PATH" fetch --deepen=10000 2>/dev/null \
    || true

BUILD_NUMBER=$(git -C "$CI_PRIMARY_REPOSITORY_PATH" rev-list --count HEAD)
echo "▸ Build number: $BUILD_NUMBER"

# `agvtool` requires the working directory to contain the .xcodeproj.
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcrun agvtool new-version -all "$BUILD_NUMBER"

echo "✓ Build number set to $BUILD_NUMBER"
