#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
APP="dist/Inkflow.app"
INKFLOW_VERSION=$(<VERSION)
if [[ ! "$INKFLOW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    print -u2 "VERSION должен содержать номер вида 1.0.0"
    exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
./scripts/build-icon.sh
cp scripts/clean-text.py "$APP/Contents/Resources/clean-text.py"
cp scripts/heal-image.py "$APP/Contents/Resources/heal-image.py"
cp bin/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift App/Inkflow.swift -o "$APP/Contents/MacOS/Inkflow"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Inkflow</string>
<key>CFBundleIdentifier</key><string>local.inkflow.app</string>
<key>CFBundleName</key><string>Inkflow</string>
<key>CFBundleDisplayName</key><string>Inkflow</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${INKFLOW_VERSION}</string>
<key>CFBundleVersion</key><string>${INKFLOW_VERSION}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
