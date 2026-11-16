#!/usr/bin/env bash
set -euo pipefail

# UI smoke suite: builds the unsigned app bundle, makes an ad-hoc signed copy with its own bundle id (so it never
# collides with an installed OpenOats), and runs UITests against it. OATS_APP=<path to .app> skips the build.

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.build/ui-smoke/DerivedData}"
SMOKE_APP="$PWD/.build/ui-smoke/OpenOats.app"

if [[ -z "${OATS_APP:-}" ]]; then
  SKIP_SIGN=1 SKIP_INSTALL=1 ./scripts/build_swift_app.sh
  OATS_APP="$PWD/dist/OpenOats.app"
fi
rm -rf "$SMOKE_APP"
mkdir -p "$(dirname "$SMOKE_APP")"
cp -R "$OATS_APP" "$SMOKE_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.openoats.ui-smoke" "$SMOKE_APP/Contents/Info.plist"
codesign --force --deep --sign - "$SMOKE_APP"
xattr -r -d com.apple.quarantine "$SMOKE_APP" 2>/dev/null || true

COMMON_ARGS=(
  -project UITests/OpenOatsUITestHost.xcodeproj
  -scheme OpenOatsUITestHost
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA_PATH"
  ONLY_ACTIVE_ARCH=YES
  AD_HOC_CODE_SIGNING_ALLOWED=YES
)

xcodebuild "${COMMON_ARGS[@]}" build-for-testing

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Debug"
if [[ -d "$PRODUCTS_DIR" ]]; then
  while IFS= read -r path; do
    xattr -r -d com.apple.quarantine "$path" 2>/dev/null || true
  done < <(
    find "$PRODUCTS_DIR" \
      \( -name 'OpenOatsUITestHost.app' -o -name 'OpenOatsUITests-Runner.app' -o -name '*.xctest' \) \
      -print
  )
fi

# TEST_RUNNER_-prefixed variables reach the test runner without the prefix.
TEST_RUNNER_OATS_APP="$SMOKE_APP" xcodebuild "${COMMON_ARGS[@]}" test-without-building
