#!/bin/sh
#
# Xcode Cloud pre-build hook. Sets CURRENT_PROJECT_VERSION to the total count
# of git commits — keeps build numbers monotonic and consistent with local
# `xcodebuild -archive` runs.
#

set -e  # exit on error; do NOT use -u (CI env vars may be unset)

echo "════════════════════════════════════════"
echo "▸ ci_pre_xcodebuild.sh — Calarm build bump"
echo "════════════════════════════════════════"
echo "▸ PWD: $(pwd)"
echo "▸ CI_PRIMARY_REPOSITORY_PATH: ${CI_PRIMARY_REPOSITORY_PATH:-NOT SET}"
echo "▸ CI_WORKSPACE: ${CI_WORKSPACE:-NOT SET}"

# Locate the repo root. Xcode Cloud uses CI_PRIMARY_REPOSITORY_PATH; fall back
# to walking up from the script's location for local execution.
if [ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]; then
    REPO_PATH="$CI_PRIMARY_REPOSITORY_PATH"
else
    REPO_PATH="$(cd "$(dirname "$0")/.." && pwd)"
fi
echo "▸ Repo path: $REPO_PATH"

# Xcode Cloud clones shallow by default → `rev-list --count` would be tiny.
# Deepen the history; ignore failures (already-complete clones, no remote, etc).
git -C "$REPO_PATH" fetch --unshallow 2>/dev/null \
    || git -C "$REPO_PATH" fetch --deepen=10000 2>/dev/null \
    || true

BUILD_NUMBER=$(git -C "$REPO_PATH" rev-list --count HEAD)
echo "▸ Target build number: $BUILD_NUMBER"

# Find the project.pbxproj. Each .xcodeproj contains exactly one.
PBXPROJ=$(find "$REPO_PATH" -maxdepth 3 -name "project.pbxproj" -type f | head -1)
if [ -z "$PBXPROJ" ]; then
    echo "✗ Could not find project.pbxproj under $REPO_PATH"
    exit 1
fi
echo "▸ Found pbxproj: $PBXPROJ"

# Show current value for sanity.
echo "▸ Current CURRENT_PROJECT_VERSION lines:"
grep "CURRENT_PROJECT_VERSION = " "$PBXPROJ" || echo "  (none found)"

# Direct sed replacement — pbxproj is a plain-text plist, safe to edit this way.
# Pattern matches `CURRENT_PROJECT_VERSION = <anything>;` (number, decimal, or string).
sed -i.bak -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" "$PBXPROJ"
rm -f "$PBXPROJ.bak"

# Verify the change took.
echo "▸ Updated CURRENT_PROJECT_VERSION lines:"
grep "CURRENT_PROJECT_VERSION = " "$PBXPROJ" || echo "  (none found)"

UPDATED_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = $BUILD_NUMBER;" "$PBXPROJ" || true)
echo "✓ Set CURRENT_PROJECT_VERSION = $BUILD_NUMBER in $UPDATED_COUNT build configurations"
echo "════════════════════════════════════════"
