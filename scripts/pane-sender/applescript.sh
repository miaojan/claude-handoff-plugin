#!/bin/bash
# pane-sender: AppleScript paste (macOS, tested).
#
# Usage:
#   applescript.sh --available
#   applescript.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# Captures the frontmost app NOW. Every send_cmd reactivates this app
# first so keystrokes always target the Claude Code terminal — even if
# focus drifts to another window between commands.
#
# Sequence per command: Esc Esc Cmd-A Backspace Cmd-V Enter
# Timing margins (don't shorten without testing): 0.7s paste→Enter,
# 0.4s post-Enter, $SLEEP_BETWEEN between commands. First run triggers
# a macOS Accessibility prompt; grant it.

set -u

if [ "${1:-}" = "--available" ]; then
  [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1 \
    && command -v pbcopy >/dev/null 2>&1 \
    && command -v pbpaste >/dev/null 2>&1 \
    && exit 0
  exit 1
fi

LINE1="${1:?missing line 1}"
LINE2="${2:?missing line 2}"
SLEEP_BETWEEN="${3:-7}"

FRONT_APP=$(/usr/bin/osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null || echo "")
echo "$(date -u +%FT%TZ) applescript captured frontmost app: '$FRONT_APP'"

send_cmd() {
  local cmd="$1"
  printf '%s' "$cmd" | pbcopy
  /usr/bin/osascript <<EOF
tell application "System Events"
  try
    if "$FRONT_APP" is not "" then
      tell application process "$FRONT_APP" to set frontmost to true
      delay 0.3
    end if
  end try
  key code 53              -- Escape #1: dismiss slash-picker
  delay 0.2
  key code 53              -- Escape #2: defensive
  delay 0.2
  keystroke "a" using command down
  delay 0.15
  key code 51              -- Backspace
  delay 0.2
  keystroke "v" using command down
  delay 0.7
  key code 36              -- Return
  delay 0.4
end tell
EOF
}

# Save clipboard
ORIG_CLIP=$(pbpaste 2>/dev/null || true)

sleep 2
echo "$(date -u +%FT%TZ) applescript paste $LINE1"
send_cmd "$LINE1"

sleep "$SLEEP_BETWEEN"
echo "$(date -u +%FT%TZ) applescript paste $LINE2"
send_cmd "$LINE2"

# Restore clipboard
sleep 0.5
if [ -n "${ORIG_CLIP:-}" ]; then
  printf '%s' "$ORIG_CLIP" | pbcopy
fi
echo "$(date -u +%FT%TZ) applescript done"
