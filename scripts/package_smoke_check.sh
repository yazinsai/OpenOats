#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="dist/OpenOats.app"
APP_BINARY="$APP_PATH/Contents/MacOS/OpenOats"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
PKGINFO="$APP_PATH/Contents/PkgInfo"
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SWIFT_TRANSFORMERS_HUB_BUNDLE="$APP_PATH/Contents/Resources/swift-transformers_Hub.bundle"

SKIP_SIGN=1 SKIP_INSTALL=1 bash ./scripts/build_swift_app.sh

[[ -d "$APP_PATH" ]] || { echo "Missing app bundle at $APP_PATH"; exit 1; }
[[ -x "$APP_BINARY" ]] || { echo "Missing app binary at $APP_BINARY"; exit 1; }
[[ -f "$INFO_PLIST" ]] || { echo "Missing Info.plist at $INFO_PLIST"; exit 1; }
[[ -f "$PKGINFO" ]] || { echo "Missing PkgInfo at $PKGINFO"; exit 1; }
[[ -d "$SPARKLE_FW" ]] || { echo "Missing Sparkle framework at $SPARKLE_FW"; exit 1; }
[[ -d "$SWIFT_TRANSFORMERS_HUB_BUNDLE" ]] || { echo "Missing swift-transformers Hub resource bundle at $SWIFT_TRANSFORMERS_HUB_BUNDLE"; exit 1; }
[[ -f "$SWIFT_TRANSFORMERS_HUB_BUNDLE/gpt2_tokenizer_config.json" ]] || { echo "Missing GPT-2 tokenizer fallback config"; exit 1; }
[[ -f "$SWIFT_TRANSFORMERS_HUB_BUNDLE/t5_tokenizer_config.json" ]] || { echo "Missing T5 tokenizer fallback config"; exit 1; }

plutil -lint "$INFO_PLIST"

if ! otool -l "$APP_BINARY" | grep -Fq "@executable_path/../Frameworks"; then
  echo "Missing app Frameworks rpath"
  exit 1
fi

echo "Package smoke check passed"
