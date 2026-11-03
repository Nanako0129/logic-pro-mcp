#!/usr/bin/env bash
# Builds LogicProMCPHub.app (ad-hoc signed; re-sign with sign-app.sh for distribution).
#   Scripts/hub/build-app.sh [debug|release]      output: .build/hub-app/LogicProMCPHub.app
#
# Layout: Contents/MacOS/{LogicProMCPHub,LogicProMCP}, Contents/Resources/manifest.json (the hub points the
# child at it via LOGIC_PRO_MCP_MANIFEST_PATH), plus any SwiftPM resource bundles into Contents/Resources
# (none exist today: nothing in the package uses Bundle.module).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONF="${1:-release}"
cd "$ROOT"
# One product per call: SwiftPM honors only the last --product (2026-11-03: the hub was silently left unbuilt).
for p in LogicProMCPHub LogicProMCP; do swift build -c "$CONF" --product "$p"; done
BIN="$(swift build -c "$CONF" --show-bin-path)"

APP="$ROOT/.build/hub-app/LogicProMCPHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LogicProMCPHub" "$BIN/LogicProMCP" "$APP/Contents/MacOS/"
cp "$ROOT/manifest.json" "$APP/Contents/Resources/"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" && echo "bundled $(basename "$b")"; done || true
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0)"
sed "s/@VERSION@/$VERSION/" "$ROOT/Scripts/hub/Info.plist" >"$APP/Contents/Info.plist"

HUB_SIGN_IDENTITY="${HUB_SIGN_IDENTITY:--}" "$ROOT/Scripts/hub/sign-app.sh" "$APP"
echo "$APP"
