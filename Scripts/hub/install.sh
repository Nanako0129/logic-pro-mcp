#!/usr/bin/env bash
# Installs the hub as a per-user launchd agent. DRY_RUN=1 prints what would happen and changes nothing.
#   Scripts/hub/install.sh [path/to/built/LogicProMCPHub.app]    (default: .build/hub-app/LogicProMCPHub.app)
# Env: HUB_INSTALL_DIR (default ~/Applications), LOGIC_PRO_MCP_HUB_PORT (default 47731),
#      LOGIC_PRO_MCP_HUB_LOG (default ~/Library/Logs/LogicProMCPHub/hub.log)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:-$ROOT/.build/hub-app/LogicProMCPHub.app}"
DIR="${HUB_INSTALL_DIR:-$HOME/Applications}"
APP="$DIR/LogicProMCPHub.app"
LABEL=com.nanako0129.logic-pro-mcp-hub
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${LOGIC_PRO_MCP_HUB_PORT:-47731}"
LOG="${LOGIC_PRO_MCP_HUB_LOG:-$HOME/Library/Logs/LogicProMCPHub/hub.log}"
run() { if [ "${DRY_RUN:-0}" = 1 ]; then echo "+ $*"; else "$@"; fi; }

[ -d "$SRC" ] || { echo "no app at $SRC (run Scripts/hub/build-app.sh, then sign-app.sh)" >&2; exit 1; }
PLIST="$(sed -e "s|@APP@|$APP|g" -e "s|@PORT@|$PORT|g" -e "s|@LOG@|$LOG|g" -e "s|@LOGDIR@|$(dirname "$LOG")|g" \
  "$ROOT/Scripts/hub/$LABEL.plist.template")"
# Optional: which Logic variant the child drives (e.g. com.apple.mobilelogic for Logic Pro Creator Studio); the hub passes its
# environment to the child, so this lands in the server as it did in the old per-session stdio config.
if [ -n "${LOGIC_PRO_BUNDLE_ID:-}" ]; then
  case $LOGIC_PRO_BUNDLE_ID in *[!A-Za-z0-9.-]*) echo "LOGIC_PRO_BUNDLE_ID must be a bundle ID" >&2; exit 2 ;; esac
  PLIST="$(printf '%s\n' "$PLIST" | sed "s|<key>LOGIC_PRO_MCP_HUB_PORT</key>|<key>LOGIC_PRO_BUNDLE_ID</key><string>$LOGIC_PRO_BUNDLE_ID</string><key>LOGIC_PRO_MCP_HUB_PORT</key>|")"
fi

run launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true       # replace a running agent
run mkdir -p "$DIR" "$(dirname "$AGENT")" "$(dirname "$LOG")"
run rm -rf "$APP"
run ditto "$SRC" "$APP"
if [ "${DRY_RUN:-0}" = 1 ]; then echo "+ write $AGENT:"; echo "$PLIST"; else printf '%s\n' "$PLIST" >"$AGENT"; fi
run launchctl bootstrap "gui/$UID" "$AGENT"
run launchctl kickstart -k "gui/$UID/$LABEL"
echo "Installed. Next: claude mcp add --transport http logic-pro http://127.0.0.1:$PORT/mcp -s user"
