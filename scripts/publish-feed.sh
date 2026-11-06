#!/usr/bin/env bash
# Adds a release to the Sparkle feed kept as appcast.xml on the "update-feed" GitHub release.
# Usage: publish-feed.sh <version>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?release version}"
repo=SergeiNikolenko/Snowpile
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

args=("$root/Snowpile-$version.zip" "$root/Snowpile-$version.dmg" "$root/build/Snowpile.app" "$work/appcast.xml")
exists=0
if gh release view update-feed --repo "$repo" > /dev/null 2>&1; then
  exists=1
  # A feed that exists but fails to download must stop the release rather than lose its history.
  if gh release view update-feed --repo "$repo" --json assets --jq '.assets[].name' | grep -qx appcast.xml; then
    gh release download update-feed --repo "$repo" --pattern appcast.xml --dir "$work/previous"
    args+=("$work/previous/appcast.xml")
  fi
fi
python3 "$root/scripts/appcast.py" "${args[@]}"
if [[ "$exists" == "0" ]]; then
  gh release create update-feed --repo "$repo" --prerelease --latest=false \
    --title 'Snowpile update feed' --notes 'Metadata for automatic updates. Download the app from a versioned release.'
fi
gh release upload update-feed "$work/appcast.xml" --repo "$repo" --clobber
