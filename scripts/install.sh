#!/usr/bin/env bash
# Build Internet Speed Reader in Release and install it to /Applications.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader}"
APP_NAME="InternetSpeedReader.app"

cd "$REPO"
echo "==> Generating Xcode project"
"${XCODEGEN:-xcodegen}" generate --spec project.yml

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
for attempt in {1..30}; do
  pgrep -x InternetSpeedReader >/dev/null || break
  sleep 1
done
if pgrep -x InternetSpeedReader >/dev/null; then
  echo "The app is still running. Quit it before installing." >&2
  exit 1
fi

# Verify before replacing the app and retain a rollback copy. Keep history/settings.
codesign --verify --deep --strict "$BUILT"
STAGED="$(mktemp -d /Applications/.isr-install-XXXXXX)"
trap 'rmdir "$STAGED" 2>/dev/null || true' EXIT
ditto --noextattr --noqtn "$BUILT" "$STAGED/$APP_NAME"
xattr -cr "$STAGED/$APP_NAME"
codesign --verify --deep --strict "$STAGED/$APP_NAME"
BACKUP="$HOME/Library/Application Support/InternetSpeedReader Backups/$(date -u +%Y%m%dT%H%M%SZ)"
if [ -d "/Applications/$APP_NAME" ]; then
  mkdir -p "$BACKUP"
  mv "/Applications/$APP_NAME" "$BACKUP/$APP_NAME"
fi
if ! mv "$STAGED/$APP_NAME" "/Applications/$APP_NAME"; then
  [ ! -d "$BACKUP/$APP_NAME" ] || mv "$BACKUP/$APP_NAME" "/Applications/$APP_NAME"
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "/Applications/$APP_NAME"

echo "==> Launching"
open "/Applications/$APP_NAME"
echo "Done."
