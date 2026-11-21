#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained native macOS app bundle: "Evolving Societies.app"
# Usage:
#   ./tools/package_macos_app.sh            # builds dist/Evolving Societies.app
#   ./tools/package_macos_app.sh --install  # also installs to /Applications (or ~/Applications)
#   ./tools/package_macos_app.sh --dmg      # also creates dist/Evolving-Societies-macOS.dmg

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Evolving Societies"
BUNDLE_ID="com.evolving-societies.app"
VERSION="1.0.0"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
INSTALL=0
MAKE_DMG=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --dmg) MAKE_DMG=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

ZIG="${ZIG:-$(command -v zig || echo /Users/mac/zig/zig)}"
if [ ! -x "$ZIG" ]; then
  echo "Error: zig compiler not found. Set ZIG=/path/to/zig." >&2
  exit 1
fi

echo "==> Building ReleaseFast native binary..."
(cd "$ROOT/sim" && "$ZIG" build -Doptimize=ReleaseFast)

echo "==> Generating Retina macOS AppIcon.icns..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
BASE_PNG="$(dirname "$ICONSET")/base_1024.png"
python3 "$ROOT/tools/make_icon.py" "$BASE_PNG" 1024

for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$BASE_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz * 2))
  sips -z "$dbl" "$dbl" "$BASE_PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> Assembling $APP_DIR..."
cp "$ROOT/sim/zig-out/bin/evolving-societies" "$APP_DIR/Contents/MacOS/evolving-societies"
chmod +x "$APP_DIR/Contents/MacOS/evolving-societies"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>evolving-societies</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.simulation-games</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Built: $APP_DIR"

if [ "$INSTALL" -eq 1 ]; then
  if [ -w "/Applications" ]; then
    TARGET="/Applications/$APP_NAME.app"
  else
    mkdir -p "$HOME/Applications"
    TARGET="$HOME/Applications/$APP_NAME.app"
  fi
  echo "==> Installing to $TARGET..."
  rm -rf "$TARGET"
  cp -R "$APP_DIR" "$TARGET"
  codesign --force --deep --sign - "$TARGET"
  echo "==> Installed natively: $TARGET"
  echo "    Open via Spotlight ('Evolving Societies'), Launchpad, or: open -a \"$APP_NAME\""
fi

if [ "$MAKE_DMG" -eq 1 ]; then
  DMG_PATH="$DIST_DIR/Evolving-Societies-macOS.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP_DIR" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  echo "==> Creating DMG installer: $DMG_PATH..."
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  echo "==> DMG ready: $DMG_PATH"
fi
