# openspec-boss

A control session ("boss") for OpenSpec changes: The boss plans changes,
starts the apply in its own Herdr tab with a configurable agent, is woken by
prompt when the apply finishes, reviews the result, fixes problems and
retriggers as needed – across any number of projects. The boss session runs
in either Claude Code or OpenCode; the whole configuration is a git repo and
can be transferred to other servers.

## How it fits together

```
  human <-----> boss session (claude | opencode), Herdr agent "boss"
                    |
                    |  /opsx:explore, /opsx:propose  (in the target project via cd)
                    |
                    |  boss dispatch <change> --project <p> [--runner <r>]
                    v
               +-----------------------------------------------------+
               | bin/boss                                            |
               |  1 read boss.toml -> runner, project path           |
               |  2 openspec status --change (in project) -> ready?  |
               |  3 herdr pane list -> already running? (tokens/agent)|
               |  4 find or create a workspace for the path          |
               |  5 herdr tab create --workspace --cwd --no-focus    |
               |  6 herdr agent start apply-<change> --kind <kind>   |
               |  7 herdr agent prompt apply-<change> "<apply cmd>"  |
               |  8 herdr pane report-metadata (os_change/os_phase)  |
               |  9 write state file                                 |
               | 10 setsid bin/boss-waiter <change> <project> &      |
               |  -> JSON on stdout                                  |
               +-----------------------------------------------------+
                                      |
          +----------------------------+-----------------------------+
          |                                                          |
          v                                                          v
    Herdr tab "<change>"                                  bin/boss-waiter (detached)
    agent apply-<change> (opencode)                         herdr agent wait apply-<change>
    runs /opsx-apply <change>                                (no timeout)
          |                                                          |
          | working ... done | blocked                                |
          +--------------------------------------------------------->+
                                                                     |
                                       herdr agent prompt boss "Apply add-auth in ~/work/shop: done.
                                                                Next step: boss status add-auth"
                                                                     |
    boss session  <--------------------------------------------------+
       |
       |  boss status add-auth  -> agent state, tasks, git diff
       |  review (read the diff, check tasks, run tests if any, /code-review)
       |
       +-- problems:  /opsx:update add-auth  -> boss retrigger add-auth --+
       |                                                                 | (loop)
       +-- OK:        /opsx:sync | /opsx:archive add-auth  -> boss finish add-auth
                                                              (tab closed, waiter gone)
```

The boss never waits actively: every dispatch starts a detached waiter process
that waits for the apply agent's state (`done`, `idle` or `blocked`) and
writes the result into the boss session as a prompt. That makes waking work
the same way in Claude Code and OpenCode.

## Commands

```bash
boss dispatch <change> [--project <name|path>] [--runner <name>] [--note <text>]
boss status [<change>] [--project <name|path>] [--json]
boss review <change> [--project <name|path>] [--json]
boss wait <change> [--project <name|path>]
boss retrigger <change> [--project <name|path>] [--note <text>]
boss finish <change> [--project <name|path>] [--force]
boss answer <change> <key>... [--project <name|path>]
boss config-json
```

- `dispatch` starts the apply in its own tab and returns a JSON object with
  agent, pane, tab and workspace. A second dispatch of the same change in the
  same project does not start a second apply (`already_running`). `--note`
  appends free text to the apply command so the boss can hand the apply agent
  context (what to test against, which tool to use for a check, who reviews)
  without touching the runner template; the note is stored and reused by
  `retrigger`. Every apply prompt ends with a **yield instruction** that tells
  the apply agent to stop at the end of its turn instead of waiting or polling
  for a review – the waiter wakes the boss instead (see `yield` below).
- `status` shows the agent state, open/done tasks from `tasks.md`,
  `git status`/`git diff --stat` of the target project and the apply tab; when
  `blocked`, it also shows the visible dialog. Without a change name, all
  known applies are listed. `--json` carries everything Herdr knows about the
  agent: `agent_status` (alias of `agent_state`), `pane` (`pane_id`, `tab_id`,
  `workspace_id`, `cwd`, `focused`) and `herdr_agent` (the raw agent object,
  `null` when the agent is gone), plus the stored `note`.
- `review` gathers the deterministic review facts for an apply: task counts,
  `openspec validate --strict`, a recognizable standard test command
  (`just test`, `npm test`, `pytest`, `make test`), the git status, and the
  friction recorded in the event log (retriggers, blocked events, lost
  waiters, duration, note). It is read-only, does not touch the apply agent and
  also works after `finish`, when only the event log is left.
- `wait` makes sure a waiter is armed for the apply (starts one if none is
  alive, otherwise reports the running one). Use it after prompting the apply
  agent directly through Herdr.
- `retrigger` sends the apply command (with the stored or a new `--note`) to
  the same agent again; the session context is kept and the waiter stays armed.
- `finish` closes the apply tab, stops the waiter and drops the state. It
  reports whether the change is archived (`archived`) but does not require it –
  archiving stays a separate step. It refuses only while the apply agent is
  still `working` (override with `--force`).
- `answer` sends keys (e.g. `enter`, `esc`, `y`) to a blocked apply agent, so
  the boss can answer follow-up questions itself.

All commands print JSON; errors appear as JSON on stderr with exit status 1
(like Herdr). The tools provide thin slash commands:
`/boss:dispatch`, `/boss:status`, `/boss:wait`, `/boss:retrigger`,
`/boss:finish` (Claude Code) or `/boss-dispatch`, `/boss-status`,
`/boss-wait`, `/boss-retrigger`, `/boss-finish` (OpenCode), which simply call the `boss` command of the same
name.

## Configuration (`~/.config/openspec-boss/boss.toml`)

On first use the file is generated from the installed agents (never
overwritten). Example (`config/boss.toml.example`):

```toml
default = "opencode"

[runners.opencode]
kind  = "opencode"
args  = []
apply = "/opsx-apply {change}"

[runners.claude]
kind  = "claude"
args  = ["--permission-mode", "bypassPermissions"]
apply = "/opsx:apply {change}"

[projects]
shop = "~/work/shop"
```

`{change}` is replaced by the change name on dispatch. The `bypassPermissions`
arguments of the claude runner are a deliberate choice: an apply without a
human at the tab would otherwise stall on every permission prompt. If you
don't want that, delete the `args` line in `boss.toml`.

A runner may carry an optional `yield` string: the instruction appended to
every apply prompt (and reused by `retrigger`). Without the field the built-in
default is used ("end your turn, do not wait or poll for a review"); `yield = ""`
sends no instruction. This keeps the apply from blocking the wake: an agent that
sits in its own wait loop stays `working`, so the waiter never fires.

`BOSS_WAITER_STALL_MS` (default 2700000 = 45 min, `0` disables) bounds each wait
in the waiter. If the apply stays `working` for that long without settling, the
waiter sends the boss an informational "still working" notice and keeps waiting;
it never treats the timeout as a lost agent. Set it above your longest normal
apply to avoid noise.

## Dependencies

- **Herdr ≥ 0.9** with installed integrations for every runner kind in use
  (`herdr integration install claude opencode`); `install.sh` checks this.
- **OpenSpec ≥ 1.13**, initialized for both tools in every target project
  (`openspec init --tools claude,opencode`), otherwise the apply agent does
  not know its command.
- **jq**, **bash ≥ 4**, **python3 ≥ 3.11** (only for `tomllib`), **setsid**
  (util-linux, for the detached waiter).
- **OpenCode** configured globally with `"permission": "allow"` – this repo
  does not change that, it is assumed to be in place.
- Target projects need `.claude/commands/opsx/` and
  `.opencode/commands/opsx-*.md` (created by `openspec init`).

## Installation

On a fresh server:

```bash
herdr integration install claude opencode   # if missing
git clone <this-repo> && cd openspec-boss
./install.sh
```

`install.sh` links the skill and commands into `~/.claude/` and
`~/.config/opencode/`, creates `~/.local/bin/boss`, generates
`~/.config/openspec-boss/` and checks the prerequisites. It is idempotent:
`git pull && ./install.sh` is enough for updates. Existing foreign files at
the target locations are reported, never overwritten. Remove again with
`./install.sh --uninstall` (config and state are kept).

## Starting the boss session

1. Create a Herdr workspace for the boss, e.g. `boss`, and start Claude Code
   or OpenCode there. For Claude Code, `claude --add-dir <project>…` is
   recommended so that file access to the target projects does not trigger
   permission prompts (or keep the projects in a common parent directory).
2. The first `boss` call registers the session as the Herdr agent `boss`
   (only one boss session at a time) and generates `boss.toml`.
3. Plan, dispatch, review changes – as described in the `boss` skill.

## Troubleshooting

- **Waiter logs**: `~/.local/state/openspec-boss/logs/<change>-<time>.log`
  records the start, the detected state, every delivery attempt and the end
  of the waiter.
- **State files**: `~/.local/state/openspec-boss/applies/` – one file per
  apply with agent, tab, pane and waiter PID; `boss status` without a change
  lists them.
- **Event logs**: `~/.local/state/openspec-boss/cycles/` – one append-only
  `*.events.jsonl` per change and project, recording `dispatch`, `retrigger`,
  `settled`, `blocked`, `lost`, `finish` and an aggregated `cycle` record.
  `boss review` reads them; they survive `finish`, so friction stays visible
  across runs.
- **Agent stuck?** Read the agent name from `boss status <change> --json`
  (field `agent`; long change names are shortened to `apply-<prefix>-<hash>`
  because Herdr limits names to 32 characters), then `herdr agent get <name>`
  shows the state and `herdr agent read <name> --source visible` the dialog.
- **Dispatch failed?** The tab is closed again and the error JSON carries the
  pane's last visible lines as `pane_tail`; set `BOSS_KEEP_FAILED_TAB=1` to
  keep the tab for inspection.
- **No waking?** Check whether an agent `boss` exists (`herdr agent list`)
  and whether the Herdr integration of the runner is installed
  (`herdr integration status`). An apply that sits in its own wait loop stays
  `working` and is never a settled state, so the waiter stays silent; the
  yield instruction prevents that, and `BOSS_WAITER_STALL_MS` surfaces it.
- **`boss dispatch` reports `already_running`?** A pane with the tokens
  `os_change`/`os_phase=apply` or the change's apply agent already exists in
  the target project for this change – `boss status` shows it.
- **Waiter after a Herdr restart?** The waiter reports `lost` via prompt or
  notification and exits; `boss finish --force` cleans up the state.
