#!/bin/sh
# NX 18 Beam's release (beam-design §4.5, decision D10): build Release, sign with the Developer ID (hardened runtime), notarize and staple the app, pack it in a
# DMG (the app and an Applications link), sign, notarize and staple the DMG, and write its SHA-256. Beam's updater (Sources/Model/Updates.swift) reads the
# NX 18 repository's GitHub releases: a "beam-<version>" release carrying NX18-Beam-<version>.dmg and NX18-Beam-<version>.dmg.sha256.
# It never prints the team ID and never handles a password: notarytool reads the keychain profile the owner made. beam/README.md has the one-time setup.
#
#   scripts/release.sh --check       checks the setup and builds nothing
#   scripts/release.sh               makes build/release/NX18-Beam-<version>.dmg (+ .sha256), notarized and stapled, from a clean beam/ at a committed HEAD
#   scripts/release.sh --publish     puts that DMG on a new DRAFT GitHub release "beam-<version>" (kencalx/NX18) at the commit it was built from;
#                                    players see it once the owner presses Publish on GitHub
#   scripts/release.sh --unsigned [--version V] [--out DIR] [--feed-base URL]
#                                    a dry run with no Developer ID: Release build, ad hoc signed, the DMG, its .sha256, and releases.json, a local feed in
#                                    GitHub's shape pointing at the DMG (file:// unless --feed-base); no notarization, nothing uploaded
set -eu
cd "$(dirname "$0")/.."
PROFILE="${BEAM_NOTARY_PROFILE:-beam-notary}"
REPO="${BEAM_RELEASE_REPO:-kencalx/NX18}"
LOCAL=Config/Local.xcconfig
OUT=build/release
MODE=release VERSION_OVERRIDE= FEED_BASE=
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --publish) MODE=publish ;;
        --unsigned|--dry-run) MODE=unsigned ;;
        --version) VERSION_OVERRIDE="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --feed-base) FEED_BASE="$2"; shift ;;
        *) printf 'release: unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

team() { sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' "$LOCAL" 2>/dev/null | head -n 1; }
# the SHA-1 of the team's Developer ID Application identity (a keychain can hold more than one; a bare name would be ambiguous)
identity() { security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application: .*($(team))\"" | head -n 1 | awk '{print $2}'; }
fail() { printf 'release: %s\n' "$1" >&2; exit 1; }
say() { printf 'release: %s\n' "$1"; }

VERSION="${VERSION_OVERRIDE:-$(sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*\([0-9.]*\).*/\1/p' Config/Beam.xcconfig)}"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || fail "the version \"$VERSION\" is not numbers and dots (Config/Beam.xcconfig MARKETING_VERSION)"
APP_NAME="NX 18 Beam.app"
DMG="$OUT/NX18-Beam-$VERSION.dmg"

check() {
    command -v xcodegen >/dev/null || fail "xcodegen is missing (brew install xcodegen)"
    [ -f "$LOCAL" ] || fail "no $LOCAL: copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM"
    [ -n "$(team)" ] || fail "$LOCAL has no 10-character DEVELOPMENT_TEAM"
    [ -n "$(identity)" ] || fail "no Developer ID Application certificate for that team in the keychain"
    xcrun notarytool --help >/dev/null 2>&1 || fail "notarytool is missing (Xcode 27.2 or 27.3)"
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || fail "the notarytool keychain profile \"$PROFILE\" does not work: run xcrun notarytool store-credentials $PROFILE (beam/README.md)"
    say "setup found (team ID set, Developer ID certificate present, notary profile \"$PROFILE\" works)"
}

# xcodegen, then a Release archive in its own DerivedData (never the one a Debug Beam runs from). Extra build settings come as arguments.
archive() {
    xcodegen generate -q
    xcodebuild -quiet -project Beam.xcodeproj -scheme Beam -configuration Release -destination generic/platform=macOS -derivedDataPath "$OUT/dd" \
        -archivePath "$OUT/Beam.xcarchive" archive MARKETING_VERSION="$VERSION" "$@"
}

# the DMG: the app beside an Applications link, so the player drags one onto the other
make_dmg() {
    stage="$OUT/dmg"; rm -rf "$stage"; mkdir -p "$stage"
    ditto "$1" "$stage/$APP_NAME"
    ln -s /Applications "$stage/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "NX 18 Beam" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
    rm -rf "$stage"
}

# a fresh output folder: one this script made before (or an empty one), never anything else
fresh_out() {
    if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ] && [ ! -e "$OUT/Beam.xcarchive" ] && [ ! -e "$OUT/releases.json" ] && [ ! -e "$OUT/commit" ]; then
        fail "$OUT has other files in it: give an empty or new folder"
    fi
    rm -rf "$OUT"; mkdir -p "$OUT"
}

checksum() { (cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"); }

# notarytool exits 0 for a rejected submission too, so read its status; on a rejection show Apple's log
notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format plist > "$OUT/notary.plist" || fail "notarytool could not submit $1"
    status="$(plutil -extract status raw "$OUT/notary.plist" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        id="$(plutil -extract id raw "$OUT/notary.plist" 2>/dev/null || true)"
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        fail "notarization of $1: ${status:-no status}"
    fi
    rm -f "$OUT/notary.plist"
}

case "$MODE" in
check) check; exit 0 ;;

unsigned)
    command -v xcodegen >/dev/null || fail "xcodegen is missing (brew install xcodegen)"
    fresh_out; OUT="$(cd "$OUT" && pwd)"; DMG="$OUT/NX18-Beam-$VERSION.dmg"
    archive CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=
    APP="$OUT/Beam.xcarchive/Products/Applications/$APP_NAME"
    codesign --verify --deep --strict "$APP"
    codesign -d --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime' || fail "the app is not built with the hardened runtime"
    make_dmg "$APP"
    checksum
    base="${FEED_BASE:-file://$OUT}"
    sha="$(cut -d' ' -f1 "$DMG.sha256")"
    cat > "$OUT/releases.json" <<EOF
[{"tag_name": "beam-$VERSION", "name": "NX 18 Beam $VERSION", "html_url": "https://github.com/$REPO/releases/tag/beam-$VERSION", "draft": false, "prerelease": false,
  "assets": [{"name": "NX18-Beam-$VERSION.dmg", "browser_download_url": "$base/NX18-Beam-$VERSION.dmg", "digest": "sha256:$sha"},
             {"name": "NX18-Beam-$VERSION.dmg.sha256", "browser_download_url": "$base/NX18-Beam-$VERSION.dmg.sha256"}]}]
EOF
    rm -rf "$OUT/dd"
    say "$DMG (ad hoc signed, not notarized), its .sha256 and releases.json"
    exit 0 ;;

publish)
    command -v gh >/dev/null || fail "gh is missing (brew install gh)"
    gh auth status >/dev/null 2>&1 || fail "gh is not signed in: run gh auth login"
    [ -f "$DMG" ] && [ -f "$DMG.sha256" ] && [ -f "$OUT/commit" ] || fail "no $DMG from scripts/release.sh: make the release first"
    xcrun stapler validate -q "$DMG" || fail "$DMG is not stapled"
    commit="$(cat "$OUT/commit")"
    [ -n "$(git branch -r --contains "$commit" 2>/dev/null)" ] || fail "the release's commit is not on GitHub yet: push it first"
    ! gh release view "beam-$VERSION" --repo "$REPO" >/dev/null 2>&1 || fail "beam-$VERSION is already a release: raise MARKETING_VERSION"
    gh release create "beam-$VERSION" "$DMG" "$DMG.sha256" --repo "$REPO" --target "$commit" --draft \
        --title "NX 18 Beam $VERSION" --notes "NX 18 Beam $VERSION. Open the disk image and drag NX 18 Beam to Applications. Beam builds your legally owned and acquired games; it includes no games, keys or firmware."
    say "draft release beam-$VERSION made on $REPO: check it on GitHub, then press Publish"
    exit 0 ;;
esac

check
[ -z "$(git status --porcelain -- . 2>/dev/null)" ] || fail "beam/ has changes that are not committed: a release is built from a commit"
fresh_out
git rev-parse HEAD > "$OUT/commit"
archive

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
APP="$OUT/export/$APP_NAME"

codesign --verify --deep --strict "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime' || fail "the app is not signed with the hardened runtime"
ditto -c -k --keepParent "$APP" "$OUT/Beam.zip"
notarize "$OUT/Beam.zip"
rm -f "$OUT/Beam.zip"
xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP" || fail "Gatekeeper does not accept the app"

make_dmg "$APP"
codesign --sign "$(identity)" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper does not accept the DMG"
checksum
rm -rf "$OUT/dd"
say "$DMG, notarized and stapled, with its .sha256. Next: scripts/release.sh --publish"
