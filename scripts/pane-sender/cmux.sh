#!/bin/bash
# pane-sender: cmux send / send-key (preferred when running inside cmux).
#
# Usage:
#   cmux.sh --available
#   cmux.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# Bypasses AppleScript entirely. cmux delivers input to the EXACT pane
# that fired the handoff, regardless of which pane has app-level focus
# or which other Claude sessions are active in sibling panes.

set -u

CMUX_BIN="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
WID="${CMUX_WORKSPACE_ID:-${HANDOFF_CMUX_WID:-}}"
SID="${CMUX_SURFACE_ID:-${HANDOFF_CMUX_SID:-}}"

if [ "${1:-}" = "--available" ]; then
  [ -x "$CMUX_BIN" ] && [ -n "$WID" ] && [ -n "$SID" ] && exit 0
  exit 1
fi

LINE1="${1:?missing line 1}"
LINE2="${2:?missing line 2}"
SLEEP_BETWEEN="${3:-7}"

sleep 2
echo "$(date -u +%FT%TZ) cmux send $LINE1 (workspace=$WID surface=$SID)"
"$CMUX_BIN" send --workspace "$WID" --surface "$SID" "$LINE1" 2>&1 | head -3
"$CMUX_BIN" send-key --workspace "$WID" --surface "$SID" Enter 2>&1 | head -3

# /clear resets the session asynchronously on the Claude Code side.
# cmux send is transactional but the slash-command handler still
# needs ≥7s to wipe state before the resume command lands.
sleep "$SLEEP_BETWEEN"
echo "$(date -u +%FT%TZ) cmux send $LINE2"
"$CMUX_BIN" send --workspace "$WID" --surface "$SID" "$LINE2" 2>&1 | head -3
"$CMUX_BIN" send-key --workspace "$WID" --surface "$SID" Enter 2>&1 | head -3
