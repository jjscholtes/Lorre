#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Lorre"
APP_VERSION="0.1.2"
BUILD_NUMBER="3"
CONFIGURATION="debug" # debug | release
SKIP_BUILD="0"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_PATH="$ROOT_DIR/Assets/Lorre.icns"

while [[ $# -gt 0 ]]; do
  case "$1" in
    debug|release)
      CONFIGURATION="$1"
      ;;
    --skip-build)
      SKIP_BUILD="1"
      ;;
    *)
      echo "Usage: $0 [debug|release] [--skip-build]" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f "$ICON_PATH" ]]; then
  echo "Missing icon file: $ICON_PATH" >&2
  exit 1
fi

cd "$ROOT_DIR"
if [[ "$SKIP_BUILD" == "0" ]]; then
  echo "Building $APP_NAME ($CONFIGURATION)..."
  swift build -c "$CONFIGURATION"
else
  echo "Skipping build; using existing binary for $CONFIGURATION if present..."
fi

BIN_PATH="$ROOT_DIR/.build/${CONFIGURATION}/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  ALT_BIN_PATH="$ROOT_DIR/.build/arm64-apple-macosx/${CONFIGURATION}/$APP_NAME"
  if [[ -x "$ALT_BIN_PATH" ]]; then
    BIN_PATH="$ALT_BIN_PATH"
  fi
fi
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Could not find built binary at $BIN_PATH" >&2
  exit 1
fi

echo "Packaging app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ICON_PATH" "$RESOURCES_DIR/$APP_NAME.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.jessescholtes.lorre</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key>
  <string>$APP_NAME</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Lorre needs microphone access to record audio locally.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$APP_NAME"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Created: $APP_BUNDLE"
echo "Binary:  $MACOS_DIR/$APP_NAME"
echo "Icon:    $RESOURCES_DIR/$APP_NAME.icns"
