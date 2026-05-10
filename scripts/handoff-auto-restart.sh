#!/bin/bash
# Auto-restart dispatcher for /clear + /handoff:handoff-resume after handoff.
#
# IMPORTANT: this script runs SYNCHRONOUSLY and does NOT self-detach.
# The caller is responsible for backgrounding (`nohup script >/dev/null 2>&1 &`
# + `disown`). Nested `&; disown` (caller detaches AND this script does
# its own internal `(...) & disown`) breaks `cmux send` socket auth —
# reproduced 2026-04-26: ALL cmux CLI calls including `ping` return
# "Error: Failed to write to socket (Broken pipe)" when run from a
# doubly-detached subshell.
#
# Dispatch order: cmux → tmux → screen → native (AppleScript on Darwin,
# xdotool/wtype on Linux, PowerShell SendKeys on Windows). Each backend
# is a separate script in pane-sender/ with the contract:
#   <backend>.sh --available           # exit 0 iff backend can fire
#   <backend>.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# State file: ~/.claude/handoff_last.json. Cmux pane IDs from the
# writer get rehydrated into env so detached subshells losing CMUX_*
# still target the right pane.

set -u

STATE="$HOME/.claude/handoff_last.json"
LOG="$HOME/.claude/handoff-auto-restart.log"
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
echo "=== $(date -u +%FT%TZ) auto-restart pid=$$ ==="

if [ ! -f "$STATE" ]; then
  echo "no handoff state at $STATE — aborting"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SENDER_DIR="$SCRIPT_DIR/pane-sender"

# Hydrate cmux IDs from state if env's empty. The writer captured them
# at handoff time precisely because env doesn't propagate cleanly to
# the detached subshell. Backend reads HANDOFF_CMUX_WID/SID as fallback.
if command -v jq >/dev/null 2>&1; then
  if [ -z "${CMUX_WORKSPACE_ID:-}" ]; then
    val="$(jq -r '.cmux_workspace_id // empty' "$STATE" 2>/dev/null)"
    [ -n "$val" ] && export HANDOFF_CMUX_WID="$val"
  fi
  if [ -z "${CMUX_SURFACE_ID:-}" ]; then
    val="$(jq -r '.cmux_surface_id // empty' "$STATE" 2>/dev/null)"
    [ -n "$val" ] && export HANDOFF_CMUX_SID="$val"
  fi
fi

LINE1="${HANDOFF_CLEAR_CMD:-/clear}"
LINE2="${HANDOFF_RESUME_CMD:-/handoff:handoff-resume}"
SLEEP_BETWEEN="${HANDOFF_SLEEP_BETWEEN:-7}"

for backend in cmux tmux screen native; do
  bin="$SENDER_DIR/${backend}.sh"
  if [ ! -x "$bin" ]; then
    echo "$(date -u +%FT%TZ) skip $backend (script not executable: $bin)"
    continue
  fi
  if "$bin" --available 2>/dev/null; then
    echo "$(date -u +%FT%TZ) pathway: $backend"
    "$bin" "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$(date -u +%FT%TZ) done ($backend pathway, rc=0)"
      exit 0
    fi
    echo "$(date -u +%FT%TZ) $backend exited rc=$rc, trying next backend"
  else
    echo "$(date -u +%FT%TZ) $backend not available"
  fi
done

echo "$(date -u +%FT%TZ) all backends unavailable — manual /clear + $LINE2 needed"
exit 0
