---
name: handoff
description: Save /loop iteration state and auto-restart Claude Code with /clear + the resume slash command. Writes ~/.claude/handoff_last.json, then fires the auto-restart helper which dispatches keystrokes via cmux/tmux/screen/AppleScript/xdotool/wtype/PowerShell - whichever the host supports. Use when context is ≥60% and the current commit is pushed + CI-green; replaces the manual "summarize → /clear → /resume" sequence. **In /loop AFK mode the UserPromptSubmit hook auto-invokes this skill — never pause to ask the user.**
---

# handoff

A user-invocable slash command that hands off the current /loop iteration
to a fresh Claude Code session without manual keystrokes.

## When to invoke

- User types `/handoff:handoff` (or the auto-handoff hook fires it)
  when context is high — typically when the UserPromptSubmit hook
  outputs "Context at X%" at the 60/65/70 threshold.
- The current commit is **pushed to origin and CI-green**. The next
  session resumes from the upstream — handing off mid-commit would
  replay a stale prompt against a half-landed change.
- The /loop prompt is known from conversation context OR can be
  reconstructed from the most recent `<command-args>` block in the
  transcript.

## When NOT to invoke

- Uncommitted work in the tree. Surface the blocker and stop. Do NOT
  pause to ask "want me to commit?" — finish the current atomic
  yourself, push, then handoff fires on the next /loop re-entry.
- Unpushed commits. Same — push first.
- Red CI on the branch. Land the red-fix first.
- No `/loop` prompt in scope. Handoff is /loop-specific; a plain
  `/clear + /<resume>` is the generic path and doesn't need this.

## Auto-fire policy (CRITICAL)

When invoked — whether by the user typing `/handoff:handoff` or by the
UserPromptSubmit hook firing it automatically at threshold — the
decision to hand off has already been made. **Do not stop to ask the
user for confirmation.** The user is AFK by design — that's the whole
reason this skill exists.

The ONLY valid stop conditions are hard pre-flight failures:
- Dirty tree
- Unpushed commits
- PR-gate blocker (red CI / merge conflict on an open PR)
- Missing /loop prompt (no `<command-args>` in transcript, no
  `loop_prompt` in previous handoff state)

For each of these, surface the specific blocker and stop. Do NOT offer
options. Do NOT ask "shall I fix it?" The model running on the other
side of /clear will see the blocker on its first turn and resolve it
in-loop.

## Execution

1. **Determine the /loop prompt to replay**. Priority:
   - `args` passed to the skill (`/handoff:handoff <override>`)
   - the most recent `<command-args>` from a `/loop` invocation in
     this conversation (verbatim shape, no leading `/loop`)
   - previous `~/.claude/handoff_last.json`'s `loop_prompt` (repeat
     handoff in one long arc)
   - if none found, surface the blocker and stop.

2. **Pre-flight tree guard** (Bash, in current cwd):
   ```sh
   DIRTY=$(git status --porcelain)
   UNPUSHED=$(git log @{upstream}..HEAD --oneline 2>/dev/null \
              || git log origin/HEAD..HEAD --oneline 2>/dev/null)
   if [ -n "$DIRTY" ] || [ -n "$UNPUSHED" ]; then
     echo "⚠ uncommitted/unpushed changes — resolve before handoff"
     printf 'dirty:\n%s\nunpushed:\n%s\n' "$DIRTY" "$UNPUSHED"
     exit 1
   fi
   ```
   If non-empty, surface the output and stop.

2.5. **PR cleanup gate** (Bash):
   ```sh
   "${CLAUDE_PLUGIN_ROOT}/scripts/handoff-pr-gate.sh"
   GATE_RC=$?
   ```
   The gate lists open PRs authored by the gh user, queues
   `gh pr merge --auto --squash` on green/pending ones (with
   direct-merge fallback for the GraphQL flake), and blocks on CI red /
   merge conflicts. It polls up to 90s waiting on in-flight CI.

   - `0` → all PRs merged or queued; proceed.
   - `1` → blockers exist (CI red, conflicts). Surface stdout and stop.
   - `2` → gh CLI missing / not authed. Soft-skip.

   Tunables (env): `HANDOFF_PR_MAX_WAIT` (90s), `HANDOFF_PR_POLL_INT`
   (15s), `HANDOFF_PR_INCLUDE_DRAFT` (0).

3. **Write handoff state**:
   ```sh
   "${CLAUDE_PLUGIN_ROOT}/scripts/handoff-writer.sh" "<verbatim loop prompt>"
   ```
   This builds `~/.claude/handoff_last.json` with `serviced=false`,
   git HEAD, cwd, timestamp, and cmux pane IDs (if running inside
   cmux). The writer doesn't add a `note` — append via `jq` after if
   you want one:
   ```sh
   jq --arg note "<summary>" '. + {note: $note}' \
     ~/.claude/handoff_last.json > /tmp/h.json && \
     mv /tmp/h.json ~/.claude/handoff_last.json
   ```

4. **Emit a 3-line summary** (git HEAD short SHA + subject, next
   ticket if identifiable, any in-flight state). Terse — the state
   file has the full context.

5. **Fire the auto-restart** (caller MUST detach — script is synchronous):
   ```sh
   nohup "${CLAUDE_PLUGIN_ROOT}/scripts/handoff-auto-restart.sh" \
     >/dev/null 2>&1 &
   disown
   ```
   The script no longer self-detaches: nested `&; disown` (the Bash
   tool's own detach + the script's internal `(...) & disown`) breaks
   `cmux send` socket auth — reproduced 2026-04-26: ALL cmux CLI calls
   including `ping` return broken-pipe under doubly-detached subshell.

   Dispatch order: **cmux → tmux → screen → native**. `native` then
   forks to `applescript.sh` (Darwin) / `xdotool.sh` (Linux X11) /
   `wtype.sh` (Linux Wayland) / `windows-sendkeys.ps1` (Cygwin/MSYS).
   First `<backend>.sh --available` that exits 0 wins. If all fail,
   the state file is still valid — user can manually
   `/clear + /handoff:handoff-resume`.

   Inter-line sleep is 7s so `/clear`'s session reset completes before
   the resume command lands. Override via `HANDOFF_SLEEP_BETWEEN` if
   needed. Override resume command via `HANDOFF_RESUME_CMD` (e.g.
   `/handoff-resume` if Claude Code folds plugin prefixes).

6. **Stop**. Do NOT call ScheduleWakeup or register further crons —
   the fresh session owns pacing after the resume command replays.

## Failure modes

- **`handoff-writer.sh` missing or non-executable**: should be `+x`
  from the plugin install. If not, `chmod +x` the script under
  `${CLAUDE_PLUGIN_ROOT}/scripts/`.
- **`jq` not installed**: writer + PR gate require it. Install via
  Homebrew / apt / scoop.
- **No backend available**: log says "all backends unavailable —
  manual /clear + … needed". State file is intact; user can resume
  manually.
- **AppleScript Accessibility prompt** (macOS, first run): grant in
  System Settings → Privacy & Security → Accessibility. Future runs
  silent.
- **`/clear` and resume concatenate**: inter-line sleep too short.
  Bump `HANDOFF_SLEEP_BETWEEN` (default 7s).
- **PR gate blocks handoff**: at least one open PR is CI-red or
  merge-conflicted. Per gate stdout, fix the blocker PR first.
- **Handoff state already serviced**: `handoff-resume` re-fires anyway
  — auto-restart may double-fire on retry; the resume skill reconciles.

## Why a skill not a shell alias

A shell alias would require the user to remember the current /loop
prompt. This skill lets the agent pull the prompt from conversation
state, write it, and chain the auto-restart — one command, zero recall.
