# claude-handoff-plugin

**Run `/loop` AFK for 8 hours without dying at 60% context.**

A Claude Code plugin that watches your context window and, when an autonomous `/loop` session crosses threshold, automatically saves state and dispatches `/clear` + the resume command into the same terminal — so the fresh session picks up the loop where the previous one left off. No human at the keyboard required.

![demo placeholder — record a 60s screen capture and drop it at docs/handoff-demo.gif](./docs/handoff-demo.gif)

> _Demo TODO_: record cmux / Claude Code window mid-`/loop`, hook detects ctx ≥60%, watch the pane swap to a fresh session that resumes `/loop` verbatim. Drop the GIF at `docs/handoff-demo.gif`.

## Why this exists

If you run `/loop` AFK — atomic-ticket queues, overnight CI grinding, autonomous-loop sentinels — the session eventually fills Claude Code's context window. The fix is well-known: summarize, `/clear`, re-invoke `/loop` with the same prompt. But that fix needs a human at the keyboard at exactly the right moment, which defeats AFK.

This plugin makes the fix automatic. A `UserPromptSubmit` hook reads context% from a sidecar (claude-hud writes one for free; any statusline can write `~/.claude/context_pct.json`). At threshold, in `/loop` mode, with a clean tree + pushed commits + PR gate green, it writes `~/.claude/handoff_last.json` and fires keystrokes via `cmux` / `tmux` / `screen` / OS-native automation. The fresh session reconciles the saved prompt against the new git HEAD and re-invokes `/loop` verbatim.

**Not for you if** you only use Claude Code interactively. Auto-fire is gated to `/loop` AFK mode; interactive sessions get a reminder, not a takeover. Manual `/handoff:handoff` works in either, but `/clear` is destructive — only use when you're done with the current conversation.

## Install

```text
/plugin marketplace add miaojan/claude-handoff-plugin
/plugin install handoff
```

## Use

When context is high (≥60%) and your current commit is **pushed + CI-green**:

```text
/handoff:handoff
```

The skill:
1. checks `git status` and unpushed commits in the current cwd,
2. runs the PR cleanup gate (queues open PRs for auto-merge / blocks on red CI / conflicts),
3. writes `~/.claude/handoff_last.json` (git HEAD, cwd, the verbatim `/loop` prompt, cmux pane IDs if any),
4. detaches an auto-restart helper that fires `/clear` then `/handoff:handoff-resume` into the same Claude Code window.

In the fresh session, `handoff-resume` reads the state, reconciles the prompt against the current HEAD, marks the file as serviced, and re-invokes `/loop` verbatim.

## How auto-restart picks a backend

The helper probes backends in order and uses the first one that's available. Each backend ships as a small script in `scripts/pane-sender/` with a uniform `--available` self-test.

| order | backend       | requires                                    | platform        | tested |
|-------|---------------|---------------------------------------------|-----------------|--------|
| 1     | cmux          | `cmux` CLI + `CMUX_WORKSPACE_ID/SURFACE_ID` | macOS           | yes    |
| 2     | tmux          | `tmux` CLI + `$TMUX`                        | macOS, Linux    | blind  |
| 3     | screen        | `screen` CLI + `$STY`                       | macOS, Linux    | blind  |
| 4a    | AppleScript   | `osascript`                                 | macOS           | yes    |
| 4b    | xdotool       | `xdotool` + `$DISPLAY` (X11)                | Linux X11       | UNTESTED |
| 4c    | wtype         | `wtype` + `$WAYLAND_DISPLAY`                | Linux Wayland   | UNTESTED |
| 4d    | SendKeys      | PowerShell + `System.Windows.Forms`         | Windows         | UNTESTED |

If all backends fail, the helper logs "manual /clear + /handoff:handoff-resume needed" and exits — the state file is intact, you can resume by hand. **The Linux/Windows pathways are best-effort and have not been validated end-to-end. PRs / issues welcome.**

## Auto-handoff at threshold (UserPromptSubmit hook)

The plugin ships a `UserPromptSubmit` hook (`hooks/context-pct-guard.sh`) that runs on every prompt submission. Below threshold it prints a `ctx X%` readout to stdout (visible in Claude's system reminders, useful for self-judging context budget). At or above threshold it diverges by mode:

- **Interactive session** (current prompt is NOT a `/loop`): emit a user-facing reminder to type `/handoff:handoff` once the current commit is pushed + CI-green. Does NOT auto-fire — interactive users should keep control.
- **`/loop` AFK mode** (current prompt starts with `/loop` or is one of the autonomous-loop sentinels): pre-flight (clean tree + pushed + PR gate green) → auto-fire writer + auto-restart in background. The next prompt of this session is wiped by `/clear` and the fresh session resumes from `/handoff:handoff-resume`. If pre-flight fails, inject a directive to finish the current atomic and try again on next /loop re-entry.

Cooldown of 120s (configurable) suppresses re-fires while the paste sequence is mid-flight.

The hook reads context% from `~/.claude/context_pct.json` (written by your statusline) OR from claude-hud's transcript-keyed cache. **You need at least one of those two to be writing the sidecar — otherwise the hook silently no-ops.** claude-hud users get the cache for free; users with custom statusline setups should write `~/.claude/context_pct.json` with at least `{session_id, pct}`.

## Tunables (env vars)

| var                       | default                       | what                                                 |
|---------------------------|-------------------------------|------------------------------------------------------|
| `CONTEXT_HANDOFF_THRESHOLD`| `60`                         | Threshold % above which the hook acts. Set to `101` to disable auto-fire entirely (hook still emits the `ctx X%` line below threshold). |
| `AUTO_RE_FIRE_COOLDOWN_MS`| `120000`                      | Cooldown after auto-fire before another can trigger. |
| `HANDOFF_RESUME_CMD`      | `/handoff:handoff-resume`     | Resume command to fire after `/clear`                |
| `HANDOFF_CLEAR_CMD`       | `/clear`                      | Reset command (rarely changed)                       |
| `HANDOFF_SLEEP_BETWEEN`   | `7`                           | Seconds between `/clear` and resume                  |
| `HANDOFF_PR_MAX_WAIT`     | `90`                          | Seconds to wait for in-flight CI                     |
| `HANDOFF_PR_POLL_INT`     | `15`                          | PR-gate poll interval                                |
| `HANDOFF_PR_INCLUDE_DRAFT`| `0`                           | If `1`, draft PRs also gate the handoff              |
| `HANDOFF_TMUX_TARGET`     | _(active pane)_               | tmux `target-pane` (e.g. `0:1.2`)                    |

## Failure modes

- **`jq` missing** — the writer + PR gate require it. Install via Homebrew (`brew install jq`), apt (`apt install jq`), or scoop (`scoop install jq`).
- **AppleScript Accessibility prompt** (macOS, first run) — grant in System Settings → Privacy & Security → Accessibility, then re-run.
- **`/clear` and the resume command concatenate** — bump `HANDOFF_SLEEP_BETWEEN`. Default `7` was bumped from `4` after the shorter window raced on a busy box.
- **PR gate blocks handoff** — at least one open PR is CI-red or merge-conflicted. The gate's stdout names the offending PRs; fix or close before retrying.
- **Doubly-detached subshell breaks `cmux send`** — the auto-restart script does NOT self-detach. Caller (the skill) is responsible for `nohup … & disown`. Never wrap the script in a second `&; disown`.

## Why a skill not a shell alias

A shell alias would force the user to remember the current `/loop` prompt and chain the writer + auto-restart manually. The skill lets the Claude Code agent pull the prompt from conversation state, write it, and chain everything — one command, zero recall.

## License

MIT — see [LICENSE](./LICENSE).
