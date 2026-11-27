#!/bin/zsh
# Builds build/Macaroon.app (Release, Apple silicon), signed with the "Developer ID Application" identity
# and hardened runtime. --release also notarizes, staples and zips it to build/Macaroon-<version>.zip
# with build/SHA256SUMS.txt.
#   ./scripts/make-release.sh             # build + sign
#   ./scripts/make-release.sh --release   # also notarize, staple and zip
# Overrides: SIGN_ID=..., NOTARY_PROFILE=... (default "App Store Connect Profile").
set -euo pipefail
cd "$(dirname "$0")/.."

sign_id="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$sign_id" ]] || { echo "Needs a Developer ID Application identity in the keychain." >&2; exit 1; }

derived=build/DerivedData
app=build/Macaroon.app
rm -rf "$app"
xcodebuild -project Macaroon.xcodeproj -scheme Macaroon -configuration Release -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO -quiet build
mkdir -p build
ditto "$derived/Build/Products/Release/Macaroon.app" "$app"

# Nested executables first (virgl_test_server for Linux GPU OpenGL), then the app with its entitlements.
find "$app/Contents/Resources" -type f -perm +111 | while read -r f; do
    if file -b "$f" | grep -q '^Mach-O'; then
        codesign --force --options runtime --timestamp --sign "$sign_id" "$f"
    fi
done
codesign --force --options runtime --timestamp --entitlements Macaroon/Macaroon.entitlements --sign "$sign_id" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")"
echo "Built $app $version ($build), signed: $sign_id"

if [[ "${1:-}" == "--release" ]]; then
    zip="build/Macaroon-${version}.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "${NOTARY_PROFILE:-App Store Connect Profile}" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --verbose=2 --type execute "$app"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    (cd build && shasum -a 256 "${zip:t}" > SHA256SUMS.txt)
    echo "Notarized and stapled: $zip"
fi
