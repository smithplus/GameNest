#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
STAGE_DIR="${TMPDIR:-/tmp}GameNestRelease-$VERSION"
DMG_DIR="$ROOT_DIR/Releases"
DMG_PATH="$DMG_DIR/GameNest-$VERSION.dmg"

"$ROOT_DIR/package_app.sh" >/dev/null

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
mkdir -p "$DMG_DIR"

ditto "$ROOT_DIR/build/GameNest.app" "$STAGE_DIR/GameNest.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "GameNest" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "$DMG_PATH"
