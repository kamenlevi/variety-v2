#!/bin/bash
# Builds VarietyV2.app.
#
# This machine has Command Line Tools only — no full Xcode — so
# `swift build --arch arm64 --arch x86_64` is unavailable (it needs xcbuild).
# Each slice is built separately with an explicit target triple into its own
# scratch path and the results are lipo'd together.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/VarietyV2.app"
CONFIG=release
UNIVERSAL=${UNIVERSAL:-0}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

build_slice() {
    local triple="$1" scratch="$2"
    swift build -c "$CONFIG" \
        --scratch-path "$scratch" \
        -Xswiftc -target -Xswiftc "$triple" >/dev/null
    echo "$scratch/$CONFIG/VarietyV2"
}

if [[ "$UNIVERSAL" == "1" ]]; then
    echo "building universal…"
    ARM=$(build_slice arm64-apple-macosx14.0  "$ROOT/.build-arm64")
    X86=$(build_slice x86_64-apple-macosx14.0 "$ROOT/.build-x86_64")
    lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/VarietyV2"
else
    echo "building native…"
    swift build -c "$CONFIG" >/dev/null
    cp "$ROOT/.build/$CONFIG/VarietyV2" "$APP/Contents/MacOS/VarietyV2"
fi

VERSION=$(git describe --tags --always 2>/dev/null || echo "0.1.0")

# App icon. Variety's own icon, rasterised from its SVG — this is Variety for
# macOS, so it should look like it. Regenerate with Scripts/make-icon.sh.
if [[ -f "$ROOT/Resources/Variety.icns" ]]; then
    cp "$ROOT/Resources/Variety.icns" "$APP/Contents/Resources/Variety.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>VarietyV2</string>
    <key>CFBundleDisplayName</key>       <string>Variety</string>
    <key>CFBundleIdentifier</key>        <string>com.kamenlevi.varietyv2</string>
    <key>CFBundleExecutable</key>        <string>VarietyV2</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleIconFile</key>          <string>Variety</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu bar app: no Dock icon, no main window on launch. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Local ad-hoc-ish signing. "Sleight Local Signing" is the self-signed identity
# already trusted on this machine; fall back to ad-hoc elsewhere.
IDENTITY="Sleight Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1
    echo "signed with: $IDENTITY"
else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
    echo "signed ad-hoc"
fi

echo "built: $APP"
