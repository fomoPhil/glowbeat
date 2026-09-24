#!/usr/bin/env bash
# Builds a signed, notarized, stapled Glowbeat .dmg and its Sparkle appcast.
#
#   scripts/release.sh <version> <build>            e.g. scripts/release.sh 1.0.1 2
#   scripts/release.sh <version> <build> --publish  also runs `gh release create`
#
# Out: dist/Glowbeat-<version>.dmg and dist/appcast.xml. Steps and background are in
# docs/releasing.md. Nothing here touches the running Glowbeat, the bulbs or
# build/DerivedData (the Debug build Phil runs).
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> <build> [--publish]}"
BUILD="${2:?usage: scripts/release.sh <version> <build> [--publish]}"
PUBLISH="${3:-}"

REPO="fomoPhil/glowbeat"
TEAM_ID="AXW4GKUTKZ"
IDENTITY="Developer ID Application: PHILIP JAMES WOOLLEY (${TEAM_ID})"
ASC_PROFILE="Samplomatic"          # the asc credential for the Personal Team
SPARKLE_ACCOUNT="glowbeat"         # keychain account holding the EdDSA private key
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/v${VERSION}/"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
WORK="$DIST/work-$VERSION"
DERIVED="$ROOT/build/DerivedData-release"
ARCHIVE="$WORK/Glowbeat.xcarchive"
EXPORT="$WORK/export"
APP="$EXPORT/Glowbeat.app"
DMG="$DIST/Glowbeat-$VERSION.dmg"
APPCAST_DIR="$WORK/appcast"

step() { printf '\n==> %s\n' "$*"; }

# Notarize one file through the Apple Notary API with the asc CLI. Other sessions can
# switch the global asc profile at any moment, so the switch, the check and the submit
# share one command.
notarize() {
    local file="$1" log="$2"
    asc auth switch --name "$ASC_PROFILE" >/dev/null \
        && asc auth status | grep -q "\"name\":\"$ASC_PROFILE\",\"keyId\":\"[^\"]*\",\"isDefault\":true" \
        && asc notarization submit --file "$file" --wait --poll-interval 20s --timeout 1h \
            --output json > "$log"
    cat "$log"; echo
    grep -qi '"status": *"Accepted"' "$log" \
        || { echo "error: notarization of $file was not accepted; run: asc notarization log --id <id>" >&2; exit 1; }
}

# stapler talks to Apple's ticket service, which times out now and then.
retry() {
    local n
    for n in 1 2 3 4; do
        "$@" && return 0
        echo "(attempt $n failed; retrying in 20 s)" >&2; sleep 20
    done
    "$@"
}

rm -rf "$WORK" "$DMG"
mkdir -p "$WORK" "$APPCAST_DIR"

step "Version $VERSION ($BUILD) into project.yml"
sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$BUILD\"/" project.yml
xcodegen generate

# netrc instead of the keychain: resolving Sparkle's binary through the keychain
# provider can sit forever on a keychain prompt nobody sees.
XCB=(xcodebuild -project Glowbeat.xcodeproj -scheme Glowbeat -derivedDataPath "$DERIVED"
     -packageAuthorizationProvider netrc)

step "Archive (Release, hardened runtime)"
"${XCB[@]}" -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" archive | tail -3

step "Export with Developer ID"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>${TEAM_ID}</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" | tail -2

step "Verify the app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|Timestamp|Runtime Version|flags)" || true
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
if grep -q "get-task-allow" <<<"$ENTITLEMENTS"; then
    echo "error: the app carries get-task-allow; this is a debug signature" >&2; exit 1
fi
grep -q "com.apple.security.device.audio-input" <<<"$ENTITLEMENTS" \
    || { echo "error: the audio-input entitlement is missing" >&2; exit 1; }
for key in NSAudioCaptureUsageDescription NSLocalNetworkUsageDescription SUFeedURL SUPublicEDKey; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null \
        || { echo "error: Info.plist lost $key" >&2; exit 1; }
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]]

step "Notarize and staple the app itself (so it opens offline once dragged out)"
ditto -c -k --keepParent "$APP" "$WORK/Glowbeat.zip"
notarize "$WORK/Glowbeat.zip" "$WORK/notarize-app.json"
retry xcrun stapler staple "$APP"
retry xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"

step "Build the dmg"
tiffutil -cathidpicheck scripts/dmg/background.png scripts/dmg/background@2x.png \
    -out "$WORK/background.tiff" >/dev/null
mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/Glowbeat.app"
# create-dmg lays out the window through Finder (a window flashes open and closes).
create-dmg \
    --volname "Glowbeat" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$WORK/background.tiff" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 112 \
    --icon "Glowbeat.app" 180 180 \
    --hide-extension "Glowbeat.app" \
    --app-drop-link 480 180 \
    --no-internet-enable \
    "$DMG" "$WORK/stage"

step "Sign the dmg"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

step "Notarize the dmg (profile $ASC_PROFILE)"
notarize "$DMG" "$WORK/notarize-dmg.json"

step "Staple and check"
retry xcrun stapler staple "$DMG"
retry xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

step "Check the app inside the dmg the way Gatekeeper will"
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
spctl --assess --type execute -vv "$MOUNT/Glowbeat.app"
retry xcrun stapler validate "$MOUNT/Glowbeat.app"
hdiutil detach "$MOUNT" >/dev/null

step "Appcast"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
# Keep earlier releases in the feed: generate_appcast merges into an appcast.xml it
# finds next to the archives, so start from the one on the latest published release.
rm -f "$DIST/appcast.xml"
gh release download --repo "$REPO" --pattern appcast.xml --dir "$APPCAST_DIR" 2>/dev/null \
    || echo "(no earlier appcast on $REPO; starting a new one)"
cp "$DMG" "$APPCAST_DIR/"
# generate_appcast reading the keychain itself raises a keychain prompt for a binary the
# key's access list does not name. generate_keys created the item, so it reads it without
# one; it hands the key over in a private temp file that is removed on any exit.
KEYDIR="$(mktemp -d)"; chmod 700 "$KEYDIR"
trap 'rm -rf "$KEYDIR"' EXIT
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$KEYDIR/key" >/dev/null
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$KEYDIR/key" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --maximum-deltas 0 \
    "$APPCAST_DIR"
rm -rf "$KEYDIR"
cp "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"

step "Done"
ls -lh "$DMG" "$DIST/appcast.xml"

# The website's Download button points at releases/latest/download/Glowbeat.dmg, so every
# release also carries a copy under that fixed name.
STABLE_DMG="$DIST/Glowbeat.dmg"
cp "$DMG" "$STABLE_DMG"

if [[ "$PUBLISH" == "--publish" ]]; then
    step "Publish v$VERSION on $REPO"
    NOTES=(--generate-notes)
    [[ -f "docs/release-notes/$VERSION.md" ]] && NOTES=(--notes-file "docs/release-notes/$VERSION.md")
    gh release create "v$VERSION" "$DMG" "$STABLE_DMG" "$DIST/appcast.xml" \
        --latest --repo "$REPO" --title "Glowbeat $VERSION" "${NOTES[@]}"
else
    echo
    echo "Not published. When ready:"
    echo "  gh release create v$VERSION \"$DMG\" \"$STABLE_DMG\" \"$DIST/appcast.xml\" --latest --repo $REPO --title \"Glowbeat $VERSION\" --notes \"...\""
fi
