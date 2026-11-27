#!/bin/sh
# NX 18 Beam's release: build, sign with the Developer ID, notarize, staple, and pack a DMG (beam-design §4.5, decision D10).
# Run it on the Mac that holds the Developer ID certificate. It never prints the team ID.
#
# One-time setup on that Mac:
#   1. cp Config/Local.xcconfig.example Config/Local.xcconfig, and put the team ID in it (git ignores the file).
#   2. xcrun notarytool store-credentials beam-notary --apple-id <Apple ID> --team-id <team ID>
#      (it asks for an app-specific password from account.apple.com and keeps it in the login keychain)
#
#   scripts/release.sh --check   checks the setup and builds nothing
#   scripts/release.sh           makes build/release/NX18-Beam-<version>.dmg, notarized and stapled
set -eu
cd "$(dirname "$0")/.."
PROFILE="${BEAM_NOTARY_PROFILE:-beam-notary}"
OUT=build/release
LOCAL=Config/Local.xcconfig

team() { sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' "$LOCAL" 2>/dev/null | head -n 1; }
fail() { printf 'release: %s\n' "$1" >&2; exit 1; }

check() {
    command -v xcodegen >/dev/null || fail "xcodegen is missing (brew install xcodegen)"
    [ -f "$LOCAL" ] || fail "no $LOCAL: copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM"
    [ -n "$(team)" ] || fail "$LOCAL has no 10-character DEVELOPMENT_TEAM"
    security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" || fail "no Developer ID Application certificate in the keychain"
    xcrun notarytool --help >/dev/null 2>&1 || fail "notarytool is missing (Xcode 27.2 or 27.3)"
    printf 'release: setup found (team ID set, Developer ID certificate present). Notarization uses the keychain profile "%s".\n' "$PROFILE"
}

check
[ "${1:-}" = "--check" ] && exit 0

VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Beam.xcconfig)"
APP="$OUT/export/NX 18 Beam.app"
DMG="$OUT/NX18-Beam-$VERSION.dmg"
rm -rf "$OUT"; mkdir -p "$OUT"

xcodegen generate -q
xcodebuild -quiet -project Beam.xcodeproj -scheme Beam -configuration Release -archivePath "$OUT/Beam.xcarchive" archive

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$(team)</string>
</dict></plist>
EOF
xcodebuild -quiet -exportArchive -archivePath "$OUT/Beam.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"
rm -f "$OUT/ExportOptions.plist"   # it names the team

codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$OUT/Beam.zip"
xcrun notarytool submit "$OUT/Beam.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

hdiutil create -quiet -volname "NX 18 Beam" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
printf 'release: %s, notarized and stapled\n' "$DMG"
