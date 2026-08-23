#!/bin/bash
# Builds Crimson Rail and assembles a launchable macOS .app bundle.
#
#   ./build.sh            release build + bundle
#   ./build.sh --debug    debug build + bundle
#   ./build.sh --run      build, bundle, then launch
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=release
RUN=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --run)   RUN=1 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

APP_NAME="Crimson Rail"
BUNDLE_ID="com.crimsonrail.game"
VERSION="1.0"
OUT="build/${APP_NAME}.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CrimsonRail"
[ -x "$BIN" ] || { echo "binary not found at $BIN"; exit 1; }

echo "==> Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/CrimsonRail"

# Generate the app icon. Every visual asset in this project is procedural, and
# the icon is no exception — `--icon` renders the .icns from code.
echo "==> Generating icon"
"$BIN" --icon "$OUT/Contents/Resources/AppIcon.icns" >/dev/null || echo "   (icon generation skipped)"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key>        <string>CrimsonRail</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.action-games</string>
    <key>NSHumanReadableCopyright</key>  <string>Crimson Rail</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$OUT/Contents/PkgInfo"

# Ad-hoc signature. Enough for the bundle to launch on this machine, but NOT
# enough for Gatekeeper anywhere else: there is no Team Identifier and no
# notarization, so `spctl -a -t exec` rejects it. Distributing to other Macs
# needs a Developer ID signature and a notarization pass — see the README.
echo "==> Signing (ad-hoc, local use only)"
codesign --force --deep --sign - "$OUT" 2>/dev/null || echo "   (codesign unavailable; the app may need a right-click > Open)"

SIZE=$(du -sh "$OUT" | cut -f1)
echo ""
echo "Built $OUT ($SIZE)"
echo "Launch with:  open '$OUT'"
echo "Note: ad-hoc signed — runs here, but other Macs will need Developer ID"
echo "      signing and notarization, or a right-click > Open."

if [ "$RUN" = "1" ]; then
  echo "==> Launching"
  open "$OUT"
fi
