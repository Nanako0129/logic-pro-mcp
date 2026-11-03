#!/usr/bin/env bash
# Signs LogicProMCPHub.app: hardened runtime + the apple-events entitlement on both executables.
#   HUB_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/hub/sign-app.sh path/to/LogicProMCPHub.app
# HUB_SIGN_IDENTITY=- signs ad-hoc (what build-app.sh does for local checks). Notarization is a separate step:
#   ditto -c -k --keepParent LogicProMCPHub.app hub.zip && xcrun notarytool submit hub.zip --keychain-profile <profile> --wait && xcrun stapler staple LogicProMCPHub.app
set -euo pipefail
APP="${1:?usage: sign-app.sh LogicProMCPHub.app}"
ID="${HUB_SIGN_IDENTITY:?set HUB_SIGN_IDENTITY (a Developer ID Application identity, or - for ad-hoc)}"
ENT="$(cd "$(dirname "$0")" && pwd)/hub.entitlements"
TS="--timestamp"; [ "$ID" = "-" ] && TS="--timestamp=none"

for exe in "$APP/Contents/MacOS/LogicProMCP" "$APP/Contents/MacOS/LogicProMCPHub"; do   # nested code first
  codesign --force --options runtime $TS --entitlements "$ENT" --sign "$ID" "$exe"
done
codesign --force --options runtime $TS --entitlements "$ENT" --sign "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -q apple-events && echo "apple-events entitlement present"
