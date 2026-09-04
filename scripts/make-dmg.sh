#!/usr/bin/env bash
# Build a distributable disk image for Internet Speed Reader.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader}"
APP_NAME="InternetSpeedReader.app"
VOLUME_NAME="Internet Speed Reader"
IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$REPO"
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
# Stage OUTSIDE iCloud Drive. Staging inside it makes the file provider tag every
# file with its own extended attributes, which get baked into the image and then
# break `codesign --verify` on the installed copy.
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/isr-dmg-XXXXXX")"
OUTPUT="$REPO/dist/InternetSpeedReader-$VERSION.dmg"

echo "==> Building Release $VERSION"
"${XCODEGEN:-/opt/homebrew/bin/xcodegen}" generate --spec project.yml
xcodebuild -project InternetSpeedReader.xcodeproj \
  -scheme InternetSpeedReader -configuration Release \
  -derivedDataPath "$DD" build

BUILT="$DD/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || { echo "Build product missing at $BUILT" >&2; exit 1; }

echo "==> Staging"
rm -f "$OUTPUT"
mkdir -p "$REPO/dist"
ditto --noextattr --noqtn "$BUILT" "$STAGING/$APP_NAME"
# The Applications symlink is what makes the window a drag-to-install target.
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/READ ME FIRST.txt" <<'NOTE'
Internet Speed Reader
=====================

To install, drag the app onto the Applications folder shown beside it.

FIRST LAUNCH
------------
This build is signed for development but is not notarised by Apple, so the first
launch on another Mac is blocked with a message about an unidentified developer.

To open it:
  1. Right-click (or Control-click) the app in Applications.
  2. Choose Open, then Open again in the dialog.

You only need to do this once. Alternatively, run this in Terminal:
  xattr -dr com.apple.quarantine /Applications/InternetSpeedReader.app

WHAT IT DOES
------------
The app lives in the menu bar and shows live download and upload throughput with
a coloured dot for connection status. It turns red the moment the internet drops
and posts a notification, then tells you how long the outage lasted when it
returns. Click it to run a speed test.

Menu bar position is controlled by you: hold Command and drag the item to move it.

Source and issues: https://github.com/Srimi1/Internet-speed-reader
NOTE

# Strip anything that attached itself along the way; a stray Finder attribute is
# enough to make the signature fail verification after install.
xattr -cr "$STAGING/$APP_NAME"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$STAGING/$APP_NAME"
codesign --verify --strict "$STAGING/$APP_NAME"

echo "==> Creating disk image"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  -fs APFS \
  "$OUTPUT"

echo "==> Verifying"
hdiutil verify "$OUTPUT"
codesign --sign "$IDENTITY" "$OUTPUT" 2>/dev/null || echo "note: image signing skipped (identity unavailable)"

SIZE="$(du -h "$OUTPUT" | cut -f1)"
SHA="$(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
rm -rf "$STAGING"

echo
echo "Built $OUTPUT"
echo "Size    $SIZE"
echo "SHA-256 $SHA"
