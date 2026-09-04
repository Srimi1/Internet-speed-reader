#!/usr/bin/env bash
# Remove Internet Speed Reader and all of its local data.
set -euo pipefail

BUNDLE_ID="com.srimi.internetspeedreader"
APP="/Applications/InternetSpeedReader.app"

osascript -e 'tell application "InternetSpeedReader" to quit' 2>/dev/null || true
sleep 1

# Deregister the login item while the bundle still exists; the background task
# database keys off the bundle, so this must happen before the app is deleted.
if [ -x "$APP/Contents/MacOS/InternetSpeedReader" ]; then
  "$APP/Contents/MacOS/InternetSpeedReader" --unregister-login-item || true
fi

rm -rf "$APP"
rm -rf "$HOME/Library/Application Support/$BUNDLE_ID"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "Removed the app, its Application Support and Caches folders, and its preferences."
