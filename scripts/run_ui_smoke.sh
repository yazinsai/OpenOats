#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.build/ui-smoke/DerivedData}"
SOURCE_PACKAGES_PATH="${SOURCE_PACKAGES_PATH:-$PWD/.build/ui-smoke/SourcePackages}"

COMMON_ARGS=(
  -project UITests/OpenOatsUITestHost.xcodeproj
  -scheme OpenOatsUITestHost
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA_PATH"
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH"
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

xcodebuild "${COMMON_ARGS[@]}" test-without-building
