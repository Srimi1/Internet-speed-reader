#!/usr/bin/env bash
# Build Internet Speed Reader in Release and install it to /Applications.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader}"
APP_NAME="InternetSpeedReader.app"

cd "$REPO"
echo "==> Generating Xcode project"
"${XCODEGEN:-/opt/homebrew/bin/xcodegen}" generate --spec project.yml

echo "==> Building Release"
xcodebuild -project InternetSpeedReader.xcodeproj \
  -scheme InternetSpeedReader \
  -configuration Release \
  -derivedDataPath "$DD" \
  build

BUILT="$DD/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || { echo "Build product missing at $BUILT" >&2; exit 1; }

echo "==> Quitting any running copy"
osascript -e 'tell application "InternetSpeedReader" to quit' 2>/dev/null || true
sleep 1

echo "==> Installing to /Applications"
rm -rf "/Applications/$APP_NAME"
ditto "$BUILT" "/Applications/$APP_NAME"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "/Applications/$APP_NAME"

echo "==> Launching"
open "/Applications/$APP_NAME"
echo "Done."
