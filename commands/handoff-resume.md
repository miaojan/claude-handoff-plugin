---
description: Resume a /loop that was handed off due to context threshold. Reads ~/.claude/handoff_last.json, marks it serviced, reconciles the saved prompt against current HEAD, and re-invokes /loop verbatim.
argument-hint: ''
allowed-tools: Bash, Skill
---

Invoke the `handoff:handoff-resume` skill via the Skill tool. The skill reads the handoff state from `~/.claude/handoff_last.json`, reconciles the saved `/loop` prompt against the current git HEAD (rewriting any "Done through DNN (HEAD xxxxxxx)" markers if the repo moved forward), marks the state as `serviced: true`, and re-invokes the `/loop` skill with the reconciled prompt.

Run non-interactively — the human is AFK by design. Do NOT pause to ask the user; the only exits are hard failures (state file missing, JSON malformed, prompt empty).

$ARGUMENTS
