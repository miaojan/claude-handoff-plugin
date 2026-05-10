---
description: Save /loop iteration state and auto-restart Claude Code with /clear + /handoff:handoff-resume. Pre-flight checks git state and open PRs, then writes ~/.claude/handoff_last.json and detaches the auto-restart helper. Use when context is ≥60% and the current commit is pushed + CI-green. **In /loop AFK mode, the UserPromptSubmit hook auto-invokes this skill — manual /handoff:handoff invocation is for interactive sessions.**
argument-hint: '[<override /loop prompt verbatim>]'
allowed-tools: Bash, Skill, AskUserQuestion
---

Invoke the `handoff:handoff` skill via the Skill tool. The skill captures the /loop prompt from conversation context, runs pre-flight gates (clean tree + pushed commits + PR cleanup), writes `~/.claude/handoff_last.json`, and fires the auto-restart helper in background. The helper dispatches `/clear` and `/handoff:handoff-resume` to whichever pane-sender backend is available (cmux → tmux → screen → AppleScript / xdotool / wtype / PowerShell SendKeys).

If `$ARGUMENTS` is non-empty, treat it as an explicit override of the /loop prompt to replay (skip the auto-detect-from-transcript step).

**Auto-fire policy** — when this command is invoked, the user has already decided to hand off; do NOT pause to ask whether to proceed. Run pre-flight gates; if they pass, write state and fire the auto-restart helper. The only valid stop condition is a hard pre-flight failure (dirty tree, unpushed commits, PR-gate blocker, missing /loop prompt). Surface the blocker and stop — don't ask the user "want me to fix it?" The user is AFK by design.

$ARGUMENTS
