#!/usr/bin/env bash
# Remove Internet Speed Reader and all of its local data.
set -euo pipefail

BUNDLE_ID="com.srimi.internetspeedreader"
APP="/Applications/InternetSpeedReader.app"

echo "NOTE: turn off 'Launch at login' in the app's Settings before uninstalling,"
echo "      otherwise a stale login item stays registered in the background task database."
echo

osascript -e 'tell application "InternetSpeedReader" to quit' 2>/dev/null || true
sleep 1

rm -rf "$APP"
rm -rf "$HOME/Library/Application Support/$BUNDLE_ID"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "Removed the app, its Application Support and Caches folders, and its preferences."
