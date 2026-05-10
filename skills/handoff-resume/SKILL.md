---
name: handoff-resume
description: Resume a /loop that was handed off due to context threshold. Reads ~/.claude/handoff_last.json, marks it serviced, reconciles the prompt against current HEAD, and re-invokes /loop verbatim. Use after /clear when the previous session ended with a handoff.
---

# handoff-resume

A user-invocable slash command that reads the handoff state file saved
by the previous session's `handoff-writer.sh` and re-invokes `/loop`
with the same prompt. Paired with `handoff-auto-restart.sh` it achieves
"click once, session restarts clean" flow; on its own it's the manual
fallback — just `/handoff:handoff-resume` after `/clear`.

## Execution

When invoked:

1. **Read the handoff state**:
   ```bash
   cat ~/.claude/handoff_last.json | jq '.'
   ```
   Keys of interest:
   - `loop_prompt` — the verbatim /loop argument (no leading `/loop`)
   - `git_head` / `git_subject` — where the previous session left the repo
   - `cwd` — project directory
   - `serviced` — false means this handoff hasn't been consumed yet

2. **Never stop to ask the user**. The human is AFK by design — that's
   the whole point of handoff/resume. Do not present options, do not
   confirm, do not wait. Auto-pick the optimal path and execute. The
   only exceptions are hard failures enumerated in "Failure modes"
   below (missing file, corrupted JSON, empty prompt) — everything
   else is auto-resolved.

   - If `serviced` is already `true`: auto-resume anyway (the
     auto-restart script may re-fire this skill on retry; a true flag
     is expected). Reconcile the prompt against current repo HEAD
     before re-invoking — see step 3.
   - If `ts` is more than 2 hours old: auto-resume anyway. The prompt
     is a directive, not a time-sensitive snapshot; staleness alone
     doesn't invalidate it.

3. **Reconcile prompt vs current HEAD**. `cd` to `cwd`, run
   `git rev-parse HEAD` and `git log --oneline <handoff.git_head>..HEAD`
   (skip if equal). If the repo moved forward since the handoff was
   saved, auto-rewrite the `loop_prompt` so "Done through DNN
   (HEAD xxxxxxx)" reflects reality and any "this session shipped" list
   includes the post-handoff commits. Keep all directive content (next
   steps, gates, rules) verbatim. This step is non-interactive — do
   not show options.

4. **Mark serviced**. Flip the flag so a duplicate invocation doesn't
   re-fire:
   ```bash
   jq '.serviced = true | .serviced_at = (now | floor)' \
     ~/.claude/handoff_last.json > /tmp/handoff.json.tmp && \
     mv /tmp/handoff.json.tmp ~/.claude/handoff_last.json
   ```

5. **Surface state to the user in one line**. No table, no multi-field
   summary — one sentence: "Resuming from HEAD xxxxxxx, prompt
   reconciled, re-entering /loop." The human is AFK; a table wastes
   context.

6. **Re-invoke `/loop`**. Use the Skill tool to invoke `loop` with the
   reconciled prompt as the args. This re-enters the /loop dynamic-mode
   pipeline cleanly.

## Failure modes

- **File missing.** No previous handoff — tell the user and stop.
  Don't guess.
- **JSON malformed.** Corruption — show the raw file contents and ask
  how to proceed.
- **`loop_prompt` empty.** Previous session wrote state but couldn't
  capture the prompt. User must re-type the /loop manually.
- **Skill tool can't find `loop` skill.** Fall back: tell the user to
  paste `/loop <prompt>` manually; show them the prompt.

## Why a dedicated skill instead of just grep'ing transcript

A shell slash command wouldn't have access to the Skill tool — only a
real skill can chain into `/loop` programmatically. This skill does
the minimal work to bridge "handoff state file on disk" → "live
`/loop` re-entry in the new session", with zero extra context cost
compared to the user typing it manually.
