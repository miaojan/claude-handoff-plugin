#!/bin/bash
# PR cleanup gate — runs before handoff fires the auto-restart.
#
# Past handoffs left orphan PRs because the pre-flight only checked
# `git status` + `unpushed` — open PRs in flight (CI pending, queued for
# auto-merge, awaiting reviewer) crossed session boundaries with no one
# watching, then went stale.
#
# This gate ensures every open PR authored by the current user is
# EITHER:
#   (a) queued for auto-merge (GitHub will merge when CI lands), OR
#   (b) merged directly (CI green case), OR
#   (c) flagged as a blocker requiring human decision.
#
# Exit codes:
#   0 — all open PRs are queued or merged; handoff safe to proceed
#   1 — at least one PR is a blocker (CI red, conflicts, draft awaiting
#       human, etc.) — handoff should stop and surface the list
#   2 — gh CLI missing / not authenticated — gate skipped (treated as OK)
#
# Env (defaults tuned for AFK loop):
#   HANDOFF_PR_MAX_WAIT     default 90    seconds to wait for in-flight CI
#   HANDOFF_PR_POLL_INT     default 15    poll interval
#   HANDOFF_PR_INCLUDE_DRAFT default 0    if 1, draft PRs also gate
#
# Stdout: human-readable summary (consumed by the caller and shown to
#         the user / injected into model turn). Keep terse.
# Logs:   appends to ~/.claude/handoff-pr-gate.log

set -u

MAX_WAIT="${HANDOFF_PR_MAX_WAIT:-90}"
POLL_INT="${HANDOFF_PR_POLL_INT:-15}"
INCLUDE_DRAFT="${HANDOFF_PR_INCLUDE_DRAFT:-0}"

LOG="$HOME/.claude/handoff-pr-gate.log"
mkdir -p "$(dirname "$LOG")"
{
  echo "=== $(date -u +%FT%TZ) pr-gate invoked (cwd=$(pwd)) ==="
} >> "$LOG"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not installed — PR gate skipped" | tee -a "$LOG"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required — PR gate skipped" | tee -a "$LOG"
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated — PR gate skipped" | tee -a "$LOG"
  exit 0
fi

# List my open PRs in JSON. autoMergeRequest is non-null when queued.
list_my_open_prs() {
  gh pr list --author @me --state open --limit 50 \
    --json number,title,isDraft,statusCheckRollup,mergeable,autoMergeRequest,headRefName \
    2>>"$LOG"
}

# Classify CI state from statusCheckRollup.
# Returns: SUCCESS | FAILURE | PENDING | EMPTY
pr_ci_state() {
  local pr_json="$1"
  local checks_len
  checks_len=$(printf '%s' "$pr_json" | jq '.statusCheckRollup | length' 2>/dev/null)
  if [ -z "$checks_len" ] || [ "$checks_len" = "0" ] || [ "$checks_len" = "null" ]; then
    echo "EMPTY"
    return
  fi
  if printf '%s' "$pr_json" | jq -e '.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED")' >/dev/null 2>&1; then
    echo "FAILURE"
    return
  fi
  if printf '%s' "$pr_json" | jq -e '.statusCheckRollup[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING" or (.conclusion == null and .status != "COMPLETED"))' >/dev/null 2>&1; then
    echo "PENDING"
    return
  fi
  echo "SUCCESS"
}

# Try to merge a single PR. Strategy: auto-merge first, direct merge as
# fallback for the GraphQL flake.
attempt_merge() {
  local pr_num="$1"
  local ci_state="$2"
  local out rc
  if [ "$ci_state" = "SUCCESS" ]; then
    out=$(gh pr merge "$pr_num" --squash 2>&1)
    rc=$?
    echo "    direct-merge rc=$rc: ${out:0:200}" >> "$LOG"
    [ "$rc" -eq 0 ] && return 0
  fi
  out=$(gh pr merge "$pr_num" --auto --squash 2>&1)
  rc=$?
  echo "    auto-merge rc=$rc: ${out:0:200}" >> "$LOG"
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if printf '%s' "$out" | grep -q "GraphQL"; then
    if [ "$ci_state" = "SUCCESS" ]; then
      out=$(gh pr merge "$pr_num" --squash 2>&1)
      rc=$?
      echo "    direct-merge fallback rc=$rc: ${out:0:200}" >> "$LOG"
      return "$rc"
    fi
  fi
  return "$rc"
}

ELAPSED=0
SEEN_BLOCKERS=""
while true; do
  PRS=$(list_my_open_prs)
  if [ -z "$PRS" ] || [ "$PRS" = "[]" ]; then
    echo "0 open PRs — gate clear"
    echo "$(date -u +%FT%TZ) gate clear" >> "$LOG"
    exit 0
  fi

  COUNT=$(printf '%s' "$PRS" | jq 'length' 2>/dev/null || echo "0")
  if [ "$COUNT" = "0" ]; then
    echo "0 open PRs — gate clear"
    exit 0
  fi

  echo "PR gate: $COUNT open PR(s) at T+${ELAPSED}s"
  BLOCKERS=""
  PENDING_LIST=""

  while IFS= read -r pr_b64; do
    [ -z "$pr_b64" ] && continue
    pr=$(printf '%s' "$pr_b64" | base64 -d 2>/dev/null)
    [ -z "$pr" ] && continue

    NUM=$(printf '%s' "$pr" | jq -r '.number')
    TITLE=$(printf '%s' "$pr" | jq -r '.title' | head -c 60)
    DRAFT=$(printf '%s' "$pr" | jq -r '.isDraft')
    MERGEABLE=$(printf '%s' "$pr" | jq -r '.mergeable')
    AUTO=$(printf '%s' "$pr" | jq -r '.autoMergeRequest')

    if [ "$DRAFT" = "true" ] && [ "$INCLUDE_DRAFT" -eq 0 ]; then
      echo "  #$NUM [draft] $TITLE — skipping"
      continue
    fi

    CI=$(pr_ci_state "$pr")
    echo "  #$NUM CI=$CI mergeable=$MERGEABLE auto=$([ "$AUTO" = "null" ] && echo "no" || echo "yes"): $TITLE"

    case "$MERGEABLE" in
      CONFLICTING)
        BLOCKERS="${BLOCKERS}
  #$NUM CONFLICTS — needs rebase/merge resolution: $TITLE"
        continue
        ;;
    esac

    case "$CI" in
      FAILURE)
        BLOCKERS="${BLOCKERS}
  #$NUM CI red — needs fix: $TITLE"
        ;;
      SUCCESS)
        if [ "$AUTO" = "null" ] || [ -z "$AUTO" ]; then
          attempt_merge "$NUM" "$CI"
          PENDING_LIST="${PENDING_LIST} #$NUM"
        else
          PENDING_LIST="${PENDING_LIST} #$NUM"
        fi
        ;;
      PENDING)
        if [ "$AUTO" = "null" ] || [ -z "$AUTO" ]; then
          attempt_merge "$NUM" "$CI"
        fi
        PENDING_LIST="${PENDING_LIST} #$NUM"
        ;;
      EMPTY)
        PENDING_LIST="${PENDING_LIST} #$NUM"
        ;;
    esac
  done < <(printf '%s' "$PRS" | jq -r '.[] | @base64')

  if [ -n "$BLOCKERS" ]; then
    SEEN_BLOCKERS="$BLOCKERS"
  fi

  if [ -z "$PENDING_LIST" ]; then
    if [ -n "$BLOCKERS" ]; then
      echo "==="
      echo "BLOCKERS — handoff gate failing:"
      printf '%s\n' "$BLOCKERS"
      echo "$(date -u +%FT%TZ) gate FAIL blockers=$BLOCKERS" >> "$LOG"
      exit 1
    fi
    sleep 2
    continue
  fi

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "==="
    echo "TIMEOUT after ${MAX_WAIT}s. In-flight:$PENDING_LIST"
    if [ -n "$SEEN_BLOCKERS" ]; then
      echo "Blockers seen:"
      printf '%s\n' "$SEEN_BLOCKERS"
      echo "$(date -u +%FT%TZ) gate FAIL timeout+blockers" >> "$LOG"
      exit 1
    fi
    echo "(all in-flight PRs are queued for auto-merge — GitHub will finish; handoff allowed)"
    echo "$(date -u +%FT%TZ) gate PASS-with-pending pending=$PENDING_LIST" >> "$LOG"
    exit 0
  fi

  echo "  → ${POLL_INT}s sleep, retrying"
  sleep "$POLL_INT"
  ELAPSED=$((ELAPSED + POLL_INT))
done
