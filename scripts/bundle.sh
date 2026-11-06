#!/bin/bash
# Builds Snowpile into build/Snowpile.app (ad-hoc signed, with Sparkle embedded).
# SNOWPILE_UNIVERSAL=1 builds for both Apple silicon and Intel.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(cat VERSION)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
public_key="$(cat Resources/sparkle-public-key.txt)"
feed="https://github.com/SergeiNikolenko/Snowpile/releases/download/update-feed/appcast.xml"

arch_flags=()
if [[ "${SNOWPILE_UNIVERSAL:-0}" == "1" ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
fi
build=(swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
"${build[@]}"
bin="$("${build[@]}" --show-bin-path)"

app=build/Snowpile.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
ditto "$bin/Snowpile" "$app/Contents/MacOS/Snowpile"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
ditto Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Snowpile</string>
    <key>CFBundleDisplayName</key><string>Snowpile</string>
    <key>CFBundleIdentifier</key><string>com.nikolenko.snowpile</string>
    <key>CFBundleExecutable</key><string>Snowpile</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build_number}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>${feed}</string>
    <key>SUPublicEDKey</key><string>${public_key}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST
xattr -cr "$app"
codesign --force --sign - "$app"
echo "Built $app ${version} (${build_number})"
