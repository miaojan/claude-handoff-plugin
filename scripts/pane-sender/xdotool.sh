#!/bin/bash
# pane-sender: xdotool (Linux X11). UNTESTED.
#
# Usage:
#   xdotool.sh --available
#   xdotool.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# Targets the focused window. If you have multiple Claude Code windows,
# focus the right one before /handoff fires. Sequence per command:
#   Esc Esc ctrl+u <text> Return
# C-u clears the current readline-style buffer.

set -u

if [ "${1:-}" = "--available" ]; then
  [ "$(uname -s)" = "Linux" ] \
    && command -v xdotool >/dev/null 2>&1 \
    && [ -n "${DISPLAY:-}" ] \
    && exit 0
  exit 1
fi

LINE1="${1:?missing line 1}"
LINE2="${2:?missing line 2}"
SLEEP_BETWEEN="${3:-7}"

send_cmd() {
  local cmd="$1"
  xdotool key --clearmodifiers Escape Escape ctrl+u
  xdotool type --clearmodifiers --delay 30 -- "$cmd"
  xdotool key --clearmodifiers Return
}

sleep 2
echo "$(date -u +%FT%TZ) xdotool send $LINE1"
send_cmd "$LINE1"
sleep "$SLEEP_BETWEEN"
echo "$(date -u +%FT%TZ) xdotool send $LINE2"
send_cmd "$LINE2"
