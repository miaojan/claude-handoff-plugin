# claude-handoff-plugin

> Save `/loop` iteration state and fire `/clear` + the resume command in a fresh Claude Code session — without manual keystrokes. One slash command replaces "summarize → `/clear` → `/resume`."

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

## Tunables (env vars)

| var                       | default                       | what                                    |
|---------------------------|-------------------------------|-----------------------------------------|
| `HANDOFF_RESUME_CMD`      | `/handoff:handoff-resume`     | Resume command to fire after `/clear`   |
| `HANDOFF_CLEAR_CMD`       | `/clear`                      | Reset command (rarely changed)          |
| `HANDOFF_SLEEP_BETWEEN`   | `7`                           | Seconds between `/clear` and resume     |
| `HANDOFF_PR_MAX_WAIT`     | `90`                          | Seconds to wait for in-flight CI        |
| `HANDOFF_PR_POLL_INT`     | `15`                          | PR-gate poll interval                   |
| `HANDOFF_PR_INCLUDE_DRAFT`| `0`                           | If `1`, draft PRs also gate the handoff |
| `HANDOFF_TMUX_TARGET`     | _(active pane)_               | tmux `target-pane` (e.g. `0:1.2`)       |

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
