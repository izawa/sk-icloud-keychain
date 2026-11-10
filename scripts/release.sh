#!/bin/bash
# Builds the DMG for distribution: Developer ID signature with the Developer ID
# provisioning profile, notarization, stapling and checks. Publishing it on
# GitHub Releases is left to a person (docs/release.md).
#   scripts/release.sh                -> build/<host>/release/sk-icloud-keychain-<version>.dmg, notarized
#   scripts/release.sh --no-notarize  -> stop after the signed DMG (nothing is sent to Apple)
#
# Needs, in the login keychain, the Developer ID Application certificate and
# notarytool credentials, and in Xcode's profile folder the Developer ID
# profile for org.izawa.sk-icloud-keychain. The release always uses the
# author's Team and bundle ID, so the keys live in the access group
# FJYY683YHH.org.izawa.sk-icloud-keychain on every Mac that installs it.
set -euo pipefail

APP_NAME="sk-icloud-keychain"
TEAM_ID="FJYY683YHH"
BUNDLE_ID="org.izawa.sk-icloud-keychain"
PROFILE_NAME="sk-icloud-keychain Developer ID"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Yukimitsu Izawa (FJYY683YHH)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-developer-id-notary}"

NOTARIZE=1
case "${1:-}" in
    "") ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "usage: $0 [--no-notarize]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/build/$(hostname -s)/release"   # per Mac, like BUILD in the Makefile

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit your changes first: the DMG should match a commit." >&2
    exit 1
fi

echo "== archive"
rm -rf "$OUT"
mkdir -p "$OUT"
# The archive is signed for development; the export below re-signs it with
# the Developer ID certificate and embeds the Developer ID profile.
(cd helper && xcodebuild -project SKICloudKeychain.xcodeproj -scheme "$APP_NAME" \
    -configuration Release -destination "generic/platform=macOS" \
    -archivePath "$OUT/$APP_NAME.xcarchive" -allowProvisioningUpdates -quiet \
    DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" archive)

echo "== export with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>manual</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>provisioningProfiles</key>
	<dict><key>$BUNDLE_ID</key><string>$PROFILE_NAME</string></dict>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/$APP_NAME.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -quiet

APP="$OUT/export/$APP_NAME.app"
codesign --verify --strict --deep --verbose=2 "$APP"
# The helper can only reach the synchronized keychain items through this group.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "$TEAM_ID.$BUNDLE_ID" \
    || { echo "The app lacks the keychain access group $TEAM_ID.$BUNDLE_ID" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

echo "== $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"   # drag the app onto this in the opened window
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [[ $NOTARIZE == 0 ]]; then
    echo "Signed DMG (not notarized): $DMG"
    exit 0
fi

echo "== notarize (takes a few minutes)"
# Keep going when notarytool fails, so that the log with the reason is printed.
RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$RESULT"
if ! grep -q "status: Accepted" <<<"$RESULT"; then
    ID="$(awk '/^ *id:/ { print $2; exit }' <<<"$RESULT")"
    echo "Notarization failed. The log says why:" >&2
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
fi

echo "== staple and check"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG"
echo "Ready to distribute: $DMG"
