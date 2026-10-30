#!/usr/bin/env bash
#
# Builds a notarized Blabberflow DMG ready to upload.
#
#   scripts/release.sh
#
# Steps: archive (Release) → export signed with Developer ID → notarize and staple
# the app → build a drag-to-Applications DMG → sign, notarize and staple the DMG.
# The result lands in build/release/Blabberflow-<version>.dmg.
#
# One-time setup
#   1. Developer ID certificate: Xcode › Settings › Accounts › your team ›
#      Manage Certificates › + › Developer ID Application.
#   2. Notarization login, saved in your keychain:
#        xcrun notarytool store-credentials blabberflow-notary \
#          --apple-id <your Apple ID email> --team-id H6978Q2SN2
#      It asks for an app-specific password; make one at account.apple.com ›
#      Sign-In and Security › App-Specific Passwords.
#
# Before each release, bump MARKETING_VERSION (e.g. 1.1) and CURRENT_PROJECT_VERSION
# (always increasing; Sparkle compares it) in the target's build settings.
#
# Environment
#   NOTARY_PROFILE  keychain profile name (default: blabberflow-notary)
#   ALLOW_DIRTY=1   release even with uncommitted changes

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Blabberflow.xcodeproj"
SCHEME="Blabberflow"
APP_NAME="Blabberflow"
TEAM_ID="H6978Q2SN2"
NOTARY_PROFILE="${NOTARY_PROFILE:-blabberflow-notary}"
OUT="$ROOT/build/release"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

notarize() {
    # Uploads a file to Apple's notary service and waits for the verdict.
    local file="$1" log="$OUT/notary-$(basename "$1").json"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$log" \
        || fail "Upload to the notary service failed. See $log"
    if ! grep -q '"status" *: *"Accepted"' "$log"; then
        local id
        id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$log" | head -1)"
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        fail "Apple rejected $(basename "$file"). The notary log above says why."
    fi
}

# ---------------------------------------------------------------------------
step "Checking setup"

IDENTITY="$(security find-identity -v -p codesigning \
    | awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) { print $2; exit }')"
[[ -n "$IDENTITY" ]] || fail "No Developer ID Application certificate for team $TEAM_ID in your keychain.
Create one in Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
    || fail "No notarization login saved as \"$NOTARY_PROFILE\". Run:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID email> --team-id $TEAM_ID"

if [[ "${ALLOW_DIRTY:-}" != 1 ]] && [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    fail "You have uncommitted changes. Commit them first, or rerun with ALLOW_DIRTY=1."
fi

settings="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2> /dev/null)"
VERSION="$(awk '$1 == "MARKETING_VERSION" { print $3; exit }' <<< "$settings")"
BUILD="$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }' <<< "$settings")"
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "Couldn't read the version from the project."
echo "Releasing $APP_NAME $VERSION ($BUILD)"

ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/$APP_NAME.app"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

rm -rf "${OUT:?}"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
step "Archiving"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates -quiet archive

step "Exporting with Developer ID signing"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" -allowProvisioningUpdates -quiet
codesign --verify --deep --strict "$APP"

# ---------------------------------------------------------------------------
step "Notarizing the app (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
notarize "$OUT/$APP_NAME.zip"
xcrun stapler staple "$APP"

# ---------------------------------------------------------------------------
step "Building the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------------------
step "Checking Gatekeeper accepts it"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

step "Done"
echo "$DMG"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
