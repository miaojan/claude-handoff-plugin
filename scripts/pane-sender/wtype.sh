#!/bin/bash
# pane-sender: wtype (Linux Wayland). UNTESTED.
#
# Usage:
#   wtype.sh --available
#   wtype.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# Wayland is more locked down than X11; many compositors require
# explicit grants for synthetic input. wtype works on wlroots-based
# compositors (Sway, river, hyprland). For GNOME/KDE you may need
# ydotool + the ydotoold daemon instead.

set -u

if [ "${1:-}" = "--available" ]; then
  [ "$(uname -s)" = "Linux" ] \
    && command -v wtype >/dev/null 2>&1 \
    && [ -n "${WAYLAND_DISPLAY:-}" ] \
    && exit 0
  exit 1
fi

LINE1="${1:?missing line 1}"
LINE2="${2:?missing line 2}"
SLEEP_BETWEEN="${3:-7}"

send_cmd() {
  local cmd="$1"
  wtype -k Escape -k Escape -M ctrl -k u -m ctrl
  wtype -- "$cmd"
  wtype -k Return
}

sleep 2
echo "$(date -u +%FT%TZ) wtype send $LINE1"
send_cmd "$LINE1"
sleep "$SLEEP_BETWEEN"
echo "$(date -u +%FT%TZ) wtype send $LINE2"
send_cmd "$LINE2"
