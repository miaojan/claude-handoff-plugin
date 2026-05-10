#!/bin/bash
# pane-sender: tmux send-keys.
#
# Usage:
#   tmux.sh --available
#   tmux.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# UNTESTED in CI. Targets the active pane unless HANDOFF_TMUX_TARGET is
# set (e.g. "session:window.pane"). send-keys bypasses tmux's prefix
# interpretation, so C-u (kill-line) goes to the inner app, not tmux.

set -u

if [ "${1:-}" = "--available" ]; then
  command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ] && exit 0
  exit 1
fi

LINE1="${1:?missing line 1}"
LINE2="${2:?missing line 2}"
SLEEP_BETWEEN="${3:-7}"

TARGET="${HANDOFF_TMUX_TARGET:-}"
TMUX_ARGS=()
[ -n "$TARGET" ] && TMUX_ARGS=(-t "$TARGET")

send_cmd() {
  local cmd="$1"
  # Escape Escape: dismiss slash-picker and any open menu.
  # C-u: clear current line (readline kill-line-backward).
  # then the literal command + Enter.
  tmux send-keys "${TMUX_ARGS[@]}" Escape Escape "C-u" "$cmd" Enter
}

sleep 2
echo "$(date -u +%FT%TZ) tmux send-keys $LINE1 (target=${TARGET:-active})"
send_cmd "$LINE1"
sleep "$SLEEP_BETWEEN"
echo "$(date -u +%FT%TZ) tmux send-keys $LINE2"
send_cmd "$LINE2"
