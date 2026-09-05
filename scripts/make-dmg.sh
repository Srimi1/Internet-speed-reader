#!/usr/bin/env bash
# Build a universal, ad-hoc signed public image without a personal certificate.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader}"
APP_NAME="InternetSpeedReader.app"
cd "$REPO"
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/isr-dmg-XXXXXX")"
trap 'rm -r -- "$STAGING"' EXIT
OUTPUT="$REPO/dist/InternetSpeedReader-$VERSION.dmg"

"${XCODEGEN:-xcodegen}" generate --spec project.yml
xcodebuild -project InternetSpeedReader.xcodeproj \
  -scheme InternetSpeedReader -configuration Release \
  -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO build

BUILT="$DD/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || { echo "Release app is missing" >&2; exit 1; }
mkdir -p "$REPO/dist"
ditto --noextattr --noqtn "$BUILT" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/READ ME FIRST.txt" <<'NOTE'
Internet Speed Reader
=====================

Drag the app to Applications. macOS 14 or later is required.

This community build is ad-hoc signed. It has no personal signing certificate
and is NOT Developer ID signed or notarized by Apple. Gatekeeper may block it.
Do not disable system security protections. Review the source and build locally
if you cannot open this build under your security policy.

The menu bar shows current network traffic automatically while your Mac is awake.
Download is the default; sustained upload activity switches to upload. Click the
menu bar item for manual Go/Stop capacity tests and local history. A dash means
there is no fresh measurement. Capacity tests transfer data to external servers.

There are no API keys, user preferences, test history or private signing assets
included in this image. See the repository's privacy and security documentation.

Source, build instructions and SHA-256 checksums:
https://github.com/Srimi1/Internet-speed-reader
NOTE

# Staging outside cloud-synced folders avoids carrying file-provider metadata.
xattr -cr "$STAGING/$APP_NAME"
codesign --force --sign - --options runtime --timestamp=none "$STAGING/$APP_NAME"
codesign --verify --deep --strict "$STAGING/$APP_NAME"
hdiutil create -volname "Internet Speed Reader" -srcfolder "$STAGING" \
  -ov -format UDZO -fs APFS "$OUTPUT"
hdiutil verify "$OUTPUT"
codesign --sign - "$OUTPUT"
codesign --verify "$OUTPUT"
(cd "$REPO/dist" && shasum -a 256 "InternetSpeedReader-$VERSION.dmg" > SHA256SUMS)
echo "Built public image and SHA256SUMS in dist/"
