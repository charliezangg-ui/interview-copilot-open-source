#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-toolchain.sh
APP="${1:?Usage: package-release.sh path/to/InterviewCopilot.app notary-keychain-profile}"
PROFILE="${2:?Provide a notarytool keychain profile name}"
if [ ! -d "$APP" ] || [ -L "$APP" ]; then echo "App path must be a real directory." >&2; exit 1; fi
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if ! printf '%s\n' "$SIGNATURE" | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
  echo "Developer ID Application signing is required." >&2; exit 1
fi
if ! printf '%s\n' "$SIGNATURE" | /usr/bin/grep -q 'runtime'; then
  echo "Hardened Runtime is required." >&2; exit 1
fi
if [ ! -f "$APP/Contents/Resources/Licenses/InterviewCopilot.txt" ]; then echo "App license missing." >&2; exit 1; fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/InterviewCopilot" | tr ' ' '-')"
mkdir -p dist/release
WORK="$(mktemp -d "$PWD/dist/release/.notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/submit.zip"
xcrun notarytool submit "$WORK/submit.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
OUTPUT="dist/release/InterviewCopilot-${VERSION}-${ARCH}.zip"
if [ -e "$OUTPUT" ]; then echo "Release file already exists; refusing to overwrite." >&2; exit 1; fi
ditto -c -k --keepParent "$APP" "$OUTPUT"
(cd dist/release && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "Notarized archive ready: $OUTPUT"
