#!/bin/bash
# pane-sender: GNU screen -X stuff.
#
# Usage:
#   screen.sh --available
#   screen.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# UNTESTED in CI. `screen -X stuff` injects literal keystrokes into the
# attached session. \033 = Esc, \025 = C-u, \r = Enter.

set -u

if [ "${1:-}" = "--available" ]; then
  command -v screen >/dev/null 2>&1 && [ -n "${STY:-}" ] && exit 0
  exit 1
fi

LINE1="${1:?missing line 1}"
LINE2="${2:?missing line 2}"
SLEEP_BETWEEN="${3:-7}"

send_cmd() {
  local cmd="$1"
  screen -X stuff $'\033\033\025'"$cmd"$'\r'
}

sleep 2
echo "$(date -u +%FT%TZ) screen -X stuff $LINE1 (sty=${STY})"
send_cmd "$LINE1"
sleep "$SLEEP_BETWEEN"
echo "$(date -u +%FT%TZ) screen -X stuff $LINE2"
send_cmd "$LINE2"
