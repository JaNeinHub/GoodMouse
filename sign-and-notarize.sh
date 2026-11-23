#!/bin/zsh
# Signs GoodMouse.app with a Developer ID, has Apple notarize it and staples the ticket, so it opens
# on any Mac without a Gatekeeper warning. Run by whoever holds the Developer ID certificate.
# Needs only the Xcode Command Line Tools (codesign, notarytool, stapler).
#
#   ./sign-and-notarize.sh <path/to/GoodMouse.app> "Developer ID Application: Name (TEAMID)" <notary profile>
#
# One-time setup of the notary profile (asks for an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials goodmouse-notary --apple-id <apple id> --team-id <TEAMID>
#
# Result: GoodMouse-<version>.zip next to the app, ready to upload to the GitHub release.
set -euo pipefail
APP="${1:?usage: $0 <GoodMouse.app> <signing identity> <notary profile>}"
IDENTITY="${2:?signing identity missing, e.g. \"Developer ID Application: Jane Doe (AB12CD34EF)\"}"
PROFILE="${3:?notary profile missing, see the top of this script}"
APP="${APP:A}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="${APP:h}/GoodMouse-$VERSION.zip"

echo "Signing GoodMouse $VERSION"
# Hardened runtime is required for notarization. GoodMouse needs no extra entitlements.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Uploading to Apple for notarization (usually 1-5 minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)" || true
echo "$OUT"
if ! grep -q "status: Accepted" <<< "$OUT"; then
    echo "Notarization failed. Details: xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
    exit 1
fi
xcrun stapler staple "$APP"

# Zip again so the download carries the stapled ticket (opens without a warning, even offline).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Done: $ZIP"
