#!/bin/bash
# Builds "Nintanium Builder.app" from this package: swift build in release, then the bundle (Info.plist, an ad-hoc signature).
# Usage: builder/make_app.sh [<output folder>]   (default: builder/build). Needs Xcode (its Swift 6 toolchain and the macOS SDK).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/build}
cd "$here"
swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)/NintaniumBuilder
app="$out/Nintanium Builder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Nintanium Builder"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Nintanium Builder</string>
    <key>CFBundleDisplayName</key><string>Nintanium Builder</string>
    <key>CFBundleExecutable</key><string>Nintanium Builder</string>
    <key>CFBundleIdentifier</key><string>org.nintanium.builder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built: $app"
