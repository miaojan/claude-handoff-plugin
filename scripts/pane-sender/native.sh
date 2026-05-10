#!/bin/bash
# pane-sender: native OS GUI automation dispatcher.
#
# Usage:
#   native.sh --available
#   native.sh "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
#
# Forks to the OS-appropriate backend:
#   Darwin              → applescript.sh
#   Linux + Wayland     → wtype.sh
#   Linux + X11         → xdotool.sh
#   Cygwin/MSYS/MinGW   → windows-sendkeys.ps1 via pwsh/powershell.exe
#
# Treat as the FALLBACK after multiplexer-based backends (cmux/tmux/screen)
# have already declined.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

pick_backend() {
  case "$(uname -s)" in
    Darwin)
      echo "$SCRIPT_DIR/applescript.sh"
      ;;
    Linux)
      if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "$SCRIPT_DIR/wtype.sh"
      else
        echo "$SCRIPT_DIR/xdotool.sh"
      fi
      ;;
    CYGWIN*|MINGW*|MSYS*)
      # Not a shell script; handled inline below.
      echo "windows"
      ;;
    *)
      echo ""
      ;;
  esac
}

BACKEND="$(pick_backend)"

if [ "${1:-}" = "--available" ]; then
  case "$BACKEND" in
    "windows")
      command -v pwsh >/dev/null 2>&1 || command -v powershell.exe >/dev/null 2>&1
      ;;
    "")
      exit 1
      ;;
    *)
      [ -x "$BACKEND" ] && "$BACKEND" --available
      ;;
  esac
  exit $?
fi

LINE1="${1:?missing line 1}"
LINE2="${2:?missing line 2}"
SLEEP_BETWEEN="${3:-7}"

case "$BACKEND" in
  "windows")
    PWSH="$(command -v pwsh || command -v powershell.exe)"
    [ -n "$PWSH" ] || { echo "no pwsh on PATH"; exit 1; }
    "$PWSH" -File "$SCRIPT_DIR/windows-sendkeys.ps1" "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
    ;;
  "")
    echo "native: unsupported uname=$(uname -s)"
    exit 1
    ;;
  *)
    [ -x "$BACKEND" ] || { echo "native: $BACKEND not executable"; exit 1; }
    "$BACKEND" "$LINE1" "$LINE2" "$SLEEP_BETWEEN"
    ;;
esac
