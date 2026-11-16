#!/bin/zsh
# Build and package locally. This script never commits, tags or publishes.
set -eu
cd "$(dirname "$0")/.."
./scripts/build.sh
INKFLOW_VERSION=$(<VERSION)
APP="dist/Inkflow.app"
ARCHIVE="Inkflow-${INKFLOW_VERSION}-macos-arm64.zip"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$INKFLOW_VERSION" ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/Inkflow")" == "arm64" ]]
codesign --verify --deep --strict "$APP"
# Stage in an owned temporary folder and verify the archived copy before publishing it locally.
STAGE=$(mktemp -d "$PWD/dist/.release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/$ARCHIVE"
/usr/bin/ditto -x -k "$STAGE/$ARCHIVE" "$STAGE/verify"
codesign --verify --deep --strict "$STAGE/verify/Inkflow.app"
[[ -x "$STAGE/verify/Inkflow.app/Contents/MacOS/Inkflow" ]]
for resource in heal-image.py clean-text.py AppIcon.icns; do
    [[ -f "$STAGE/verify/Inkflow.app/Contents/Resources/$resource" ]]
done
mv "$STAGE/$ARCHIVE" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
print "Готово: dist/$ARCHIVE"
print "SHA-256: dist/$ARCHIVE.sha256"
