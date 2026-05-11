#!/bin/bash
# UserPromptSubmit hook — mirrors claude-hud's context-percent logic and,
# when running in /loop AFK mode, auto-fires handoff at ≥THRESHOLD.
#
# Data flow:
#   The statusline (e.g. claude-hud OR a user's hud-with-context-sidecar.sh)
#   gets the privileged stdin JSON from Claude Code (includes
#   `context_window`) and writes:
#     (a) ~/.claude/context_pct.json  — native used_percentage + rate_limits
#     (b) ~/.claude/plugins/claude-hud/context-cache/<sha256(transcript)>.json
#         — HUD's own session-scoped snapshot (via context-cache.ts)
#
#   This hook's stdin only has {session_id, transcript_path, cwd, prompt}
#   so we mirror HUD by reading the two artifacts HUD writes.
#
# Output policy (stdout is injected into Claude's next turn):
#   - pct < THRESHOLD         → one-line readout (silent self-judge aid)
#   - pct ≥ THRESHOLD AND NOT loop-mode
#                             → full handoff reminder (user-facing)
#   - pct ≥ THRESHOLD AND loop-mode AND pre-flight green
#                             → auto-fire handoff-writer + auto-restart,
#                               inject "stop current work" notice
#   - pct ≥ THRESHOLD AND loop-mode AND pre-flight blocked
#                             → inject blocker directive (dirty/unpushed/
#                               no-loop-prompt) for the model to resolve
#
# Plugin paths resolved via ${CLAUDE_PLUGIN_ROOT}, set by Claude Code when
# invoking plugin hooks. Falls back to user-global ~/.claude/scripts paths
# only if CLAUDE_PLUGIN_ROOT is unset (manual invocation / debugging).
#
# Disable entirely:           CONTEXT_HANDOFF_THRESHOLD=101
# Custom threshold (default 60): CONTEXT_HANDOFF_THRESHOLD=70
# Cooldown after auto-fire:   AUTO_RE_FIRE_COOLDOWN_MS=120000

set -u

SIDECAR="$HOME/.claude/context_pct.json"
HUD_CACHE_DIR="$HOME/.claude/plugins/claude-hud/context-cache"
THRESHOLD="${CONTEXT_HANDOFF_THRESHOLD:-60}"
AUTO_RE_FIRE_COOLDOWN_MS="${AUTO_RE_FIRE_COOLDOWN_MS:-120000}"

# Resolve plugin scripts. CLAUDE_PLUGIN_ROOT is exported by Claude Code
# when running plugin hooks; we double-check then fall back to the
# legacy user-global location for development convenience.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT/scripts" ]; then
  PR_GATE="$PLUGIN_ROOT/scripts/handoff-pr-gate.sh"
  WRITER="$PLUGIN_ROOT/scripts/handoff-writer.sh"
  RESTART="$PLUGIN_ROOT/scripts/handoff-auto-restart.sh"
else
  PR_GATE="$HOME/.claude/scripts/handoff-pr-gate.sh"
  WRITER="$HOME/.claude/scripts/handoff-writer.sh"
  RESTART="$HOME/.claude/scripts/handoff-auto-restart.sh"
fi

# Default resume command for the auto-restart paste sequence. Override
# via env if Claude Code's slash-command resolver folds the prefix.
RESUME_CMD="${HANDOFF_RESUME_CMD:-/handoff:handoff-resume}"

command -v jq >/dev/null 2>&1 || exit 0

STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat)
fi
current_session=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
transcript_path=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null)
cwd=$(printf '%s' "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null)
current_prompt=$(printf '%s' "$STDIN_JSON" | jq -r '.prompt // empty' 2>/dev/null)

# is_waiting_for_user: scan the LAST assistant turn in the transcript for
# markers indicating the model is waiting on user input. Returns 0 if so.
#
# Bug this guards against: in /loop dynamic mode, ScheduleWakeup synthesizes
# a UserPromptSubmit that LOOKS like a fresh /loop invocation. If the model's
# previous turn ended with an open question to the user (because it noticed
# context was high and recommended /handoff manually, or any other AskUser
# scenario), auto-fire would /clear before the user could answer. Defer the
# fire instead — next prompt submit re-evaluates.
#
# Signals (any one is sufficient):
#   A) Last assistant turn contains a tool_use with name=AskUserQuestion
#   B) Last assistant text block ends with `?` or `？` (fullwidth)
is_waiting_for_user() {
  local tpath="${transcript_path:-}"
  [ -z "$tpath" ] && return 1
  case "$tpath" in
    /*) ;;
    *) [ -n "${cwd:-}" ] && tpath="$cwd/$transcript_path" ;;
  esac
  [ ! -f "$tpath" ] && return 1

  # Find the last assistant entry. Tail 300 lines for cheap scan; transcript
  # is JSONL so each line is one event. Handle both .type and .role schemas.
  local last_assistant
  last_assistant=$(tail -300 "$tpath" 2>/dev/null \
                   | jq -c 'select((.type // .role // "") == "assistant")' 2>/dev/null \
                   | tail -1)
  [ -z "$last_assistant" ] && return 1

  # Signal A: AskUserQuestion tool_use in this turn.
  if printf '%s' "$last_assistant" \
     | jq -e '.. | objects | select(.type? == "tool_use" and .name? == "AskUserQuestion")' \
     >/dev/null 2>&1; then
    return 0
  fi

  # Signal B: text content ends with a question mark (ASCII or fullwidth).
  # Strip carriage returns; check the trailing character of the concatenated
  # text blocks. trailing whitespace tolerated.
  local last_text
  last_text=$(printf '%s' "$last_assistant" \
              | jq -r '.. | objects | select(.type? == "text") | .text? // empty' 2>/dev/null \
              | tr -d '\r')
  if [ -n "$last_text" ] \
     && printf '%s' "$last_text" | grep -qE '[?？][[:space:]]*$'; then
    return 0
  fi

  return 1
}

pct=""
rate_5h=""
rate_7d=""

# --- Step 1: prefer sidecar (HUD's getNativePercent equivalent) -----------
if [ -f "$SIDECAR" ]; then
  sidecar_session=$(jq -r '.session_id // empty' "$SIDECAR" 2>/dev/null)
  if [ -z "$current_session" ] || [ "$current_session" = "$sidecar_session" ]; then
    sidecar_pct=$(jq -r '.pct // empty' "$SIDECAR" 2>/dev/null)
    if [ -n "$sidecar_pct" ] && [ "$sidecar_pct" != "null" ]; then
      pct="$sidecar_pct"
    fi
    rate_5h=$(jq -r '.rate_5h // empty' "$SIDECAR" 2>/dev/null)
    rate_7d=$(jq -r '.rate_7d // empty' "$SIDECAR" 2>/dev/null)
  fi
fi

# --- Step 2: HUD's applyContextWindowFallback for suspicious-zero --------
if { [ -z "$pct" ] || [ "$pct" = "0" ]; } && [ -n "$transcript_path" ]; then
  abs_path="$transcript_path"
  case "$abs_path" in
    /*) ;;
    *) [ -n "$cwd" ] && abs_path="$cwd/$transcript_path" ;;
  esac
  hash=$(printf '%s' "$abs_path" | shasum -a 256 2>/dev/null | awk '{print $1}')
  cache_file="$HUD_CACHE_DIR/${hash}.json"
  if [ -n "$hash" ] && [ -f "$cache_file" ]; then
    cache_pct=$(jq -r '.used_percentage // empty' "$cache_file" 2>/dev/null)
    if [ -n "$cache_pct" ] && [ "$cache_pct" != "null" ] && [ "$cache_pct" != "0" ]; then
      pct="$cache_pct"
    fi
  fi
fi

[ -z "$pct" ] && exit 0

pct_int=$(awk -v p="$pct" 'BEGIN{printf "%d", p}')
[ -z "$pct_int" ] && exit 0
pct_fmt=$(awk -v p="$pct" 'BEGIN{printf "%.0f", p}')

rate_suffix=""
if [ -n "$rate_5h" ] && [ "$rate_5h" != "null" ]; then
  rate5_fmt=$(awk -v p="$rate_5h" 'BEGIN{printf "%.0f", p}')
  rate_suffix="${rate_suffix} 5h ${rate5_fmt}%"
fi
if [ -n "$rate_7d" ] && [ "$rate_7d" != "null" ]; then
  rate7_fmt=$(awk -v p="$rate_7d" 'BEGIN{printf "%.0f", p}')
  rate_suffix="${rate_suffix} · 7d ${rate7_fmt}%"
fi

# --- Below threshold: one-line readout, done -----------------------------
if [ "$pct_int" -lt "$THRESHOLD" ]; then
  echo "ctx ${pct_fmt}%${rate_suffix:+ (${rate_suffix# })}"
  exit 0
fi

# --- Above threshold --- detect /loop AFK mode ---------------------------
# Loop markers: leading `/loop` OR autonomous sentinels.
is_loop_mode=0
case "$current_prompt" in
  /loop*|"<<autonomous-loop-dynamic>>"*|"<<autonomous-loop>>"*)
    is_loop_mode=1 ;;
esac

# --- Non-loop (interactive): user-facing reminder, no auto-fire ----------
if [ "$is_loop_mode" -eq 0 ]; then
  extra=""
  [ -n "$rate_suffix" ] && extra=" ·${rate_suffix}"
  cat <<EOF
⚠️  Context at ${pct_fmt}% (threshold ${THRESHOLD}%).${extra}

Interactive session — recommend the user type \`/handoff:handoff\` when the
current commit is pushed + CI-green. Skill's pre-flight guards will block
if git is dirty / unpushed.

(Auto-handoff is AFK-only; it fires when the current prompt is a /loop
 invocation or autonomous-loop sentinel.)
EOF
  exit 0
fi

# --- Loop AFK mode: auto-fire path ---------------------------------------

# Open-question guard. If the model's last turn left a question for the
# user (either via AskUserQuestion or trailing ?/？), DO NOT auto-fire —
# the /clear would erase the question before the user could answer.
# Defer to next prompt submit; user can still manually fire /handoff:handoff.
if is_waiting_for_user; then
  cat <<EOF
⚠️  Context at ${pct_fmt}% (loop AFK mode) — auto-handoff DEFERRED.

The model's last turn left an open question for the user; firing /clear
now would erase it before the user could answer. Will re-evaluate on the
next prompt submission.

Manual override: type \`/handoff:handoff\` to fire anyway. To disable
auto-handoff entirely: \`export CONTEXT_HANDOFF_THRESHOLD=101\`.
EOF
  exit 0
fi

# Idempotency: skip if we already fired within the cooldown window.
# After /clear the fresh session has its own sidecar; the marker is
# naturally session-scoped via session_id match above.
now_ms=$(( $(date +%s) * 1000 ))
if [ -f "$SIDECAR" ]; then
  last_auto=$(jq -r '.auto_handoff_fired_at // 0' "$SIDECAR" 2>/dev/null)
  if [ -n "$last_auto" ] && [ "$last_auto" != "0" ] && [ "$last_auto" != "null" ]; then
    delta=$(( now_ms - last_auto ))
    if [ "$delta" -ge 0 ] && [ "$delta" -lt "$AUTO_RE_FIRE_COOLDOWN_MS" ]; then
      cat <<EOF
⚠️  Auto-handoff already fired ${delta}ms ago. /clear + ${RESUME_CMD}
paste is mid-flight. Do NOT start new tool calls — let the session flip.
EOF
      exit 0
    fi
  fi
fi

# Pre-flight: clean tree + all pushed. Mirrors handoff SKILL.md's guards.
repo_cwd="${cwd:-$(pwd)}"
dirty=""
unpushed=""
if command -v git >/dev/null 2>&1 && git -C "$repo_cwd" rev-parse --git-dir >/dev/null 2>&1; then
  dirty=$(git -C "$repo_cwd" status --porcelain 2>/dev/null)
  upstream=$(git -C "$repo_cwd" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    unpushed=$(git -C "$repo_cwd" log "${upstream}..HEAD" --oneline 2>/dev/null)
  fi
fi

if [ -n "$dirty" ] || [ -n "$unpushed" ]; then
  dirty_flag="no"; [ -n "$dirty" ] && dirty_flag="yes"
  unpushed_flag="no"; [ -n "$unpushed" ] && unpushed_flag="yes"
  cat <<EOF
⚠️  Context at ${pct_fmt}% (loop AFK mode) — auto-handoff BLOCKED:
  git-dirty : ${dirty_flag}
  unpushed  : ${unpushed_flag}

Directive for this turn:
  1. Finish the CURRENT atomic only (no new ticket).
  2. Commit + push. Local gates must be green before push.
  3. Auto-handoff will fire on the NEXT /loop re-entry once tree is
     clean and pushed.
EOF
  exit 0
fi

# PR cleanup gate: ensure no orphan PRs cross the handoff boundary.
if [ -x "$PR_GATE" ]; then
  pr_gate_out=$("$PR_GATE" 2>&1)
  pr_gate_rc=$?
  if [ "$pr_gate_rc" -eq 1 ]; then
    cat <<EOF
⚠️  Context at ${pct_fmt}% (loop AFK mode) — auto-handoff BLOCKED by PR gate:
$pr_gate_out

Directive for this turn:
  1. Resolve the blocker PR(s) above (CI red → push fix; conflicts → rebase).
  2. Once the gate is clear, auto-handoff fires on the NEXT /loop re-entry.
  3. Do NOT advance to a new ticket while old PRs are red — they'll
     orphan on session flip.
EOF
    exit 0
  fi
  # rc=0 (clear) or rc=2 (gh missing — soft skip): proceed.
fi

# Recover the /loop prompt to replay.
loop_prompt=""
case "$current_prompt" in
  /loop\ *)      loop_prompt="${current_prompt#/loop }" ;;
  /loop)         loop_prompt="" ;;
  "<<autonomous-loop-dynamic>>"*|"<<autonomous-loop>>"*)
                 loop_prompt="$current_prompt" ;;
esac
if [ -z "$loop_prompt" ] && [ -f "$HOME/.claude/handoff_last.json" ]; then
  loop_prompt=$(jq -r '.loop_prompt // empty' "$HOME/.claude/handoff_last.json" 2>/dev/null)
fi
if [ -z "$loop_prompt" ] || [ "$loop_prompt" = "null" ]; then
  cat <<EOF
⚠️  Context at ${pct_fmt}% (loop AFK mode) — auto-handoff BLOCKED:
cannot recover /loop prompt (stdin prompt="${current_prompt}",
handoff_last.json.loop_prompt empty).

Directive: invoke \`/handoff:handoff <explicit loop prompt>\` manually this turn.
EOF
  exit 0
fi

if [ ! -x "$WRITER" ] || [ ! -x "$RESTART" ]; then
  cat <<EOF
⚠️  Context at ${pct_fmt}% — auto-handoff scripts missing/non-executable.
  writer  : $WRITER
  restart : $RESTART

The plugin install may be incomplete. Run \`/plugin update handoff\` then
\`/reload-plugins\`. Falling back to manual \`/handoff:handoff\`.
EOF
  exit 0
fi

# Fire writer synchronously (fast; captures git HEAD, cwd, loop_prompt).
writer_out=$("$WRITER" "$loop_prompt" 2>&1)
writer_rc=$?
if [ "$writer_rc" -ne 0 ]; then
  cat <<EOF
⚠️  Context at ${pct_fmt}% — handoff-writer.sh failed (rc=$writer_rc):
$writer_out
Falling back to manual \`/handoff:handoff\`.
EOF
  exit 0
fi

# Fire auto-restart in background. Caller (Claude Code hook runner)
# already invokes us via shell — don't double-detach. Plugin's
# auto-restart contract: one detach by caller, none internally.
nohup "$RESTART" >/dev/null 2>&1 &
disown 2>/dev/null || true

# Mark sidecar so immediate re-fires are suppressed.
if [ -f "$SIDECAR" ]; then
  tmp="${SIDECAR}.tmp.$$"
  if jq --argjson v "$now_ms" '. + {auto_handoff_fired_at: $v}' "$SIDECAR" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$SIDECAR"
  else
    rm -f "$tmp"
  fi
fi

# Inject notice so the model stops and yields cleanly.
short_prompt=$(printf '%s' "$loop_prompt" | head -c 80)
cat <<EOF
⚠️  Context at ${pct_fmt}% — AUTO-HANDOFF FIRED (loop AFK mode).

Pre-flight: tree clean, upstream in sync. Writer captured:
  loop_prompt: ${short_prompt}$([ ${#loop_prompt} -gt 80 ] && echo "…")
  state file : ~/.claude/handoff_last.json

Paste sequence (via handoff-auto-restart.sh dispatcher):
  T+2.0s  → /clear
  T+9.0s  → ${RESUME_CMD}  (fresh session replays loop_prompt verbatim)

Directive for THIS turn:
  • Do NOT start new tool calls — they'll be wiped by /clear.
  • Do NOT emit long output — auto-restart will paste into this input
    field after 2s.
  • Acknowledge in one line and stop.
EOF
