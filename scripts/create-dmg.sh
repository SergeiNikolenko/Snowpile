#!/usr/bin/env bash
# Packs an app into a compressed DMG with an Applications shortcut.
# Usage: create-dmg.sh <app> <output.dmg>
set -euo pipefail
app="${1:?app}"
output="${2:?output dmg}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Snowpile -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$output" > /dev/null
