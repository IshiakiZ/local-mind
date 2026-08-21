#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="LocalMind.app"
BIN="$APP/Contents/MacOS/LocalMind"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Local Mind</string>
  <key>CFBundleDisplayName</key><string>Local Mind</string>
  <key>CFBundleExecutable</key><string>LocalMind</string>
  <key>CFBundleIdentifier</key><string>com.pearce.localmind</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

echo "==> compiling"
swiftc -O -parse-as-library -swift-version 6 \
  -target arm64-apple-macosx26.0 \
  Sources/*.swift \
  -o "$BIN"

if [ -f Icon/AppIcon.icns ]; then
  cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "==> app icon installed"
fi

IDENTITY="LocalMind Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> signing with $IDENTITY (stable identity — TCC grants survive rebuilds)"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "==> signing (ad-hoc — WARNING: screen permissions reset on every rebuild)"
  codesign --force --sign - "$APP"
fi

echo "==> built $APP"
