#!/bin/bash
# Builds Sotto.app and the Claude Desktop extension (Sotto.mcpb) into ./build.
#
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy Sotto.app to ~/Applications
#
# Signing is ad hoc by default. To sign with a Developer ID, set SIGN_IDENTITY
# to the certificate name, for example "Developer ID Application: Your Name (TEAMID)".
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/SottoCore/Paths.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
IDENTITY="${SIGN_IDENTITY:--}"
OUT=build
APP="$OUT/Sotto.app"

echo "Building Sotto $VERSION ($BUILD)"
swift build -c release --product sotto
swift build -c release --product SottoApp
BIN=$(swift build -c release --show-bin-path)

if [ ! -f packaging/Sotto.icns ]; then
  swift scripts/make-icon.swift packaging
  iconutil -c icns packaging/Sotto.iconset -o packaging/Sotto.icns
fi

rm -rf "$APP" "$OUT/mcpb" "$OUT/Sotto.mcpb"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/mcpb/server"

cp "$BIN/SottoApp" "$APP/Contents/MacOS/Sotto"
cp "$BIN/sotto" "$APP/Contents/Resources/sotto"
cp packaging/Sotto.icns "$APP/Contents/Resources/Sotto.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/Info.plist > "$APP/Contents/Info.plist"

sign() {
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$@"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"
  fi
}

# Claude Desktop extension: the same CLI binary, run as `sotto mcp`.
cp "$BIN/sotto" "$OUT/mcpb/server/sotto"
sign "$OUT/mcpb/server/sotto"
cp packaging/icon.png "$OUT/mcpb/icon.png"
sed "s/__VERSION__/$VERSION/" packaging/manifest.json > "$OUT/mcpb/manifest.json"
(cd "$OUT/mcpb" && zip -qry ../Sotto.mcpb manifest.json icon.png server)
cp "$OUT/Sotto.mcpb" "$APP/Contents/Resources/Sotto.mcpb"

sign "$APP/Contents/Resources/sotto"
if [ "$IDENTITY" = "-" ]; then
  sign "$APP"
else
  sign --entitlements packaging/Sotto.entitlements "$APP"
fi

echo "Built $APP and $OUT/Sotto.mcpb"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Sotto 2>/dev/null || true
  rm -rf "$HOME/Applications/Sotto.app"
  cp -R "$APP" "$HOME/Applications/Sotto.app"
  echo "Installed to ~/Applications/Sotto.app"
fi
