#!/usr/bin/env bash
# Stops and removes the hub agent and app. DRY_RUN=1 prints only. Logs are left in place.
set -euo pipefail
DIR="${HUB_INSTALL_DIR:-$HOME/Applications}"
LABEL=com.nanako0129.logic-pro-mcp-hub
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
run() { if [ "${DRY_RUN:-0}" = 1 ]; then echo "+ $*"; else "$@"; fi; }
run launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
run rm -f "$AGENT"
run rm -rf "$DIR/LogicProMCPHub.app"
echo "Removed. Also: claude mcp remove logic-pro -s user"
