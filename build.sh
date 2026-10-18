#!/bin/zsh
# Builds DevDisk.app in ./dist (Apple Silicon).
#
#   ./build.sh            For your own Mac. Signs with an Apple Development identity (always the same one), so macOS remembers
#                         folder permissions across rebuilds (approve the keychain dialog once with "Always Allow").
#   ./build.sh --adhoc    Same, signed ad-hoc. macOS may re-ask for folder permissions after each rebuild.
#   ./build.sh --release  For anyone. Signs with your Developer ID, packs dist/DevDisk-<version>.dmg,
#                         notarizes it with Apple and staples the ticket. One-time setup is in README.md.
#
# VERSION=1.2 ./build.sh --release sets the version (default 1.0). Build number = commit count, or 1.
set -euo pipefail
cd "${0:A:h}"

MODE=${1:-dev}
VERSION=${VERSION:-1.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
NOTARY_PROFILE=${NOTARY_PROFILE:-devdisk-notary}

if [[ $MODE == --release ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  if [[ -z $IDENTITY ]]; then
    echo "No 'Developer ID Application' certificate in your keychain. See README.md › Sharing DevDisk." >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarization profile '$NOTARY_PROFILE'. See README.md › Sharing DevDisk." >&2
    exit 1
  fi
fi

swift build -c release --arch arm64
APP=dist/DevDisk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/DevDisk" "$APP/Contents/MacOS/DevDisk"
cp -R Web "$APP/Contents/Resources/web"

# App icon, drawn by scripts/make-icon.swift.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET:h}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DevDisk</string>
  <key>CFBundleDisplayName</key><string>DevDisk</string>
  <key>CFBundleIdentifier</key><string>io.cel.devdisk</string>
  <key>CFBundleExecutable</key><string>DevDisk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Reads sizes only. Never opens file contents.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>DevDisk reads folder sizes in Desktop to find leftover build output and dependencies. It never opens or changes files.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DevDisk reads folder sizes in Documents to find leftover build output and dependencies. It never opens or changes files.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DevDisk reads folder sizes in Downloads to find leftover build output and dependencies. It never opens or changes files.</string>
</dict></plist>
PLIST

if [[ $MODE == dev ]]; then
  # The keychain lists identities in no fixed order; pick by certificate hash so every build signs the same way
  # (a different signature makes macOS re-ask for folder access). SIGN_ID=<hash or name> overrides.
  IDENTITY=${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2}' | sort | head -1)}
elif [[ $MODE == --adhoc ]]; then
  IDENTITY=""
fi
# Hardened runtime + secure timestamp are what notarization requires; harmless for local builds.
TIMESTAMP=--timestamp=none
[[ $MODE == --release ]] && TIMESTAMP=--timestamp
codesign --force --options runtime $TIMESTAMP --sign "${IDENTITY:--}" "$APP"
echo "Built $APP $VERSION ($BUILD), signed: ${IDENTITY:-ad-hoc}"

[[ $MODE == --release ]] || exit 0

# Disk image with the usual drag-to-Applications layout.
DMG=dist/DevDisk-$VERSION.dmg
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname DevDisk -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "Notarizing (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "Ready to share: $DMG"
