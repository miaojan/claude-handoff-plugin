# Manual end-to-end tests

There are no automated tests in this plugin: the auto-restart helper
fires GUI keystrokes into a live Claude Code terminal, which can't
reasonably run in CI without a virtual display + a running Claude Code
process. The mac path (cmux + AppleScript) is exercised whenever the
maintainer runs `/handoff:handoff` in their day-to-day; Linux/Windows
paths are blind-written and depend on user reports.

## Smoke test (macOS, ~30s)

1. Open a fresh Claude Code session in a project with a clean tree
   and a real `/loop` history (or any `/loop` you can paste).
2. Type `/handoff:handoff` (or `/handoff` if the prefix folds).
3. Expected:
   - `~/.claude/handoff_last.json` written with `serviced: false`,
     correct `git_head`, `cwd`, `loop_prompt`.
   - `~/.claude/handoff-auto-restart.log` shows `pathway: cmux`
     (if you're inside cmux) or `pathway: native` → applescript.
   - Terminal receives `/clear`, ~7s pause, then
     `/handoff:handoff-resume`.
   - The fresh session's first turn reads the state, marks it
     `serviced: true`, and re-invokes `/loop` with the captured prompt.

## Backend probe

To verify each backend's `--available` self-test on your machine:

```sh
PLUGIN_ROOT=~/.claude/plugins/cache/claude-handoff-plugin/handoff/0.1.0
for b in cmux tmux screen native; do
  if "$PLUGIN_ROOT/scripts/pane-sender/$b.sh" --available 2>/dev/null; then
    echo "$b: AVAILABLE"
  else
    echo "$b: not available"
  fi
done
```

The dispatcher (`handoff-auto-restart.sh`) walks them in this same
order and uses the first AVAILABLE.

## Linux / Windows reports welcome

If you tried this on Linux (X11 or Wayland) or Windows and either
backend worked or broke, please open an issue with:
- `uname -a` output (or `$PSVersionTable` on Windows)
- terminal emulator name + version
- whether you were inside tmux/screen/cmux at the time
- a relevant excerpt from `~/.claude/handoff-auto-restart.log`
