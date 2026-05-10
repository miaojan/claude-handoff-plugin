---
description: Save /loop iteration state and auto-restart Claude Code with /clear + /handoff:handoff-resume. Pre-flight checks git state and open PRs, then writes ~/.claude/handoff_last.json and detaches the auto-restart helper. Use when context is ≥60% and the current commit is pushed + CI-green.
argument-hint: '[<override /loop prompt verbatim>]'
allowed-tools: Bash, Skill, AskUserQuestion
---

Invoke the `handoff:handoff` skill via the Skill tool. The skill captures the /loop prompt from conversation context, runs pre-flight gates (clean tree + pushed commits + PR cleanup), writes `~/.claude/handoff_last.json`, and fires the auto-restart helper in background. The helper dispatches `/clear` and `/handoff:handoff-resume` to whichever pane-sender backend is available (cmux → tmux → screen → AppleScript / xdotool / wtype / PowerShell SendKeys).

If `$ARGUMENTS` is non-empty, treat it as an explicit override of the /loop prompt to replay (skip the auto-detect-from-transcript step).

$ARGUMENTS
