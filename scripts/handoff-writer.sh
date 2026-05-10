#!/bin/bash
# Handoff state writer — invoked by Claude when context ≥60% and the
# current /loop iteration's atomic commit has landed CI-green.
#
# Captures: git HEAD sha + subject, cwd, the /loop prompt to replay,
# timestamp, "serviced" flag (false on write; handoff-resume flips it).
#
# Usage: handoff-writer.sh "<verbatim /loop input, without the leading slash-loop>"

set -u

PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then
  echo "usage: $0 '<loop-prompt-verbatim>'" >&2
  exit 2
fi

STATE="$HOME/.claude/handoff_last.json"
mkdir -p "$(dirname "$STATE")"
CWD="$(pwd)"

if command -v git >/dev/null 2>&1 && git -C "$CWD" rev-parse HEAD >/dev/null 2>&1; then
  GIT_HEAD=$(git -C "$CWD" rev-parse HEAD)
  GIT_SUBJECT=$(git -C "$CWD" log -1 --format=%s)
else
  GIT_HEAD=""
  GIT_SUBJECT=""
fi

# Stamp cmux pane identity into state so handoff-auto-restart.sh can
# target the source pane explicitly via `cmux send` even if env vars
# don't propagate to the detached subshell. Bug 2026-04-26: with N
# concurrent Claude sessions inside cmux, the AppleScript paste was
# landing in whichever cmux pane had keyboard focus at fire time, not
# the source pane.
CMUX_WID="${CMUX_WORKSPACE_ID:-}"
CMUX_SID="${CMUX_SURFACE_ID:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "handoff-writer: jq required (brew/apt/scoop install jq)" >&2
  exit 3
fi

jq -n \
  --arg ts "$(date -u +%s)" \
  --arg git_head "$GIT_HEAD" \
  --arg git_subject "$GIT_SUBJECT" \
  --arg cwd "$CWD" \
  --arg prompt "$PROMPT" \
  --arg cmux_wid "$CMUX_WID" \
  --arg cmux_sid "$CMUX_SID" \
  '{
    ts: ($ts | tonumber),
    git_head: $git_head,
    git_subject: $git_subject,
    cwd: $cwd,
    loop_prompt: $prompt,
    cmux_workspace_id: $cmux_wid,
    cmux_surface_id: $cmux_sid,
    serviced: false
  }' > "$STATE"

chmod 600 "$STATE"
echo "handoff state written to $STATE"
