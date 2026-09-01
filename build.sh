#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BarcodeScanner"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
rm -rf "$DIST/Barcode Scanner.app"
mkdir -p "$MACOS" "$RESOURCES"

swiftc -parse-as-library -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  -o "$MACOS/BarcodeScanner" \
  -framework AppKit \
  -framework WebKit \
  -framework Vision \
  -framework ImageIO \
  -framework CoreImage \
  -framework UniformTypeIdentifiers \
  "$ROOT/ReviewerMain.swift" \
  "$ROOT/ScannerController.swift" \
  "$ROOT/VisionScanner.swift"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/app.html" "$RESOURCES/app.html"
echo "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
