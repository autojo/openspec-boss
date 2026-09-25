# openspec-boss

A control session ("boss") for OpenSpec changes: The boss plans changes,
starts the apply in its own Herdr tab with a configurable agent, is woken by
prompt when the apply finishes, reviews the result, fixes problems and
retriggers as needed – across any number of projects. The boss session runs
in either Claude Code or OpenCode; the whole configuration is a git repo and
can be transferred to other servers.

## How it fits together

```
  human <-----> boss session (claude | opencode), Herdr agent "boss-<workspace>"
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
                                        herdr agent prompt <responsible boss> "Apply add-auth in
                                                     ~/work/shop: done. Next step: boss status add-auth"
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

The boss is scoped to its Herdr workspace: `boss claim` makes a pane the boss
of its workspace, and `dispatch`/`retrigger`/`finish`/`answer` claim a free
workspace automatically (or abort when another living pane owns it). Several
workspaces can run their own boss in parallel. When an apply settles, the waiter
resolves the responsible boss in this order: (1) the boss registered for the
workspace the apply runs in, (2) the boss that dispatched the apply (stored in
the state), (3) the global `BOSS_AGENT_NAME` (default `boss`). Dead agents are
skipped; when none is reachable, the waiter shows a Herdr notification instead.

## Explorer and Executer

The system has two named roles. The boss session is the **Explorer**: it owns
the big task, plans, creates changes, dispatches work, reviews the result,
maintains the skills and escalates to the human. An **Executer** is an apply
agent (`apply-<change>`) and implements exactly one OpenSpec change in its own
Herdr tab; the Explorer never works in that tab.

One workspace runs at most one active Executer at a time: two changes would
share the same working tree and index. `boss dispatch` checks the target
workspace before it opens a tab and refuses a second apply with `executer_busy`,
naming the running change – finish it first. Different projects in different
workspaces (one workspace per project, path like `~/work/<projekt>`) run their
own Explorer and Executer in parallel. The command `boss` and the agent name
`apply-<change>` stay unchanged; the roles are vocabulary, not a new process.

## Missions

A large task that breaks into several changes is planned as a **mission**: a
Markdown file in the target project with the goal in prose and the changes in
execution order, one `- <change>` per line:

```markdown
# Mission: crawl-expansion

## Goal

Ship the crawler: first the worker, then the rate limit, at last the cleanup.

## Changes

- add-worker
- fix-ratelimit
- archive-cleanup
```

`boss mission start <slug> --project <p>` writes this skeleton (never
overwriting an existing file), `boss mission status <slug> --project <p>` shows
the goal and each change with a derived state, and `boss mission next <slug>
--project <p>` starts the first change that is not yet `done` through the normal
dispatch path. The file stores no status of its own: a change is `done` when it
is `finished` (a `finish` event), has no open task and is `openspec validate`
green; `change_not_ready` means no proposal exists yet, the signal for the
Explorer to create it before the next tick. `next` returns `mission_complete`
when every change is done, and `executer_busy` when the workspace already runs
an Executer. The mission doc lives under the project, so it is visible and
versioned with the plan – default `openspec/missions/<slug>.md`, override with
`[missions] dir` (a leading `~` is expanded).

After each `boss finish` of a mission change the Explorer calls `boss mission
next` for the next step; the order in the doc is the order of execution.

## Commands

```bash
boss dispatch <change> [--project <name|path>] [--runner <name>] [--note <text>]
boss status [<change>] [--project <name|path>] [--json]
boss review <change> [--project <name|path>] [--json]
boss wait <change> [--project <name|path>]
boss retrigger <change> [--project <name|path>] [--note <text>]
boss finish <change> [--project <name|path>] [--force] [--lesson <text>] [--lesson-scope project|global]
boss answer <change> <key>... [--project <name|path>]
boss claim [--name <name>] [--release]
boss session [--project <name|path>] [--runner <name>]
boss skills dir [--project <name|path>] [--json]
boss mission start <slug> --project <name|path>
boss mission status <slug> [--project <name|path>]
boss mission next <slug> [--project <name|path>]
boss config-json
```

- `dispatch` starts the apply in its own tab and returns a JSON object with
  agent, pane, tab and workspace. A second dispatch of the same change in the
  same project does not start a second apply (`already_running`); a second
  change in the same workspace is refused with `executer_busy`
  (see [Explorer and Executer](#explorer-and-executer)). `--note`
  appends free text to the apply command so the boss can hand the apply agent
  context (what to test against, which tool to use for a check, who reviews)
  without touching the runner template; the note is stored and reused by
  `retrigger`. Every apply prompt ends with a **yield instruction** that tells
  the apply agent to stop at the end of its turn instead of waiting or polling
  for a review – the waiter wakes the boss instead (see `yield` below).
- `status` shows the agent state, open/done tasks from `tasks.md`,
  `git status`/`git diff --stat` of the target project, the commit range since
  the apply started and the apply tab; when `blocked`, it also shows the
  visible dialog. Without a change name, all known applies are listed. `--json`
  carries everything Herdr knows about the agent: `agent_status` (alias of
  `agent_state`), `pane` (`pane_id`, `tab_id`, `workspace_id`, `cwd`,
  `focused`) and `herdr_agent` (the raw agent object, `null` when the agent is
  gone), plus the stored `note` and the last agent output as `summary`.
- `review` gathers the deterministic review facts for an apply: task counts,
  `openspec validate --strict`, a test command, the commits of the apply and
  the git working tree, the last agent output as `summary`, and the friction
  recorded in the event log (retriggers, blocked events, lost waiters,
  duration, note). The test command comes from the optional `[tests]` config
  or is detected (`just test`, `pnpm test`/`yarn test`/`npm test`, `uv run
  pytest`/`poetry run pytest`/`pytest`, `make test`); if none is found or its
  program is not installed, the result is `not_run` instead of a false `fail`.
  It is read-only, does not touch the apply agent and also works after
  `finish`, when only the event log is left.
- `wait` makes sure a waiter is armed for the apply (starts one if none is
  alive, otherwise reports the running one). Use it after prompting the apply
  agent directly through Herdr.
- `retrigger` sends the apply command (with the stored or a new `--note`) to
  the same agent again; the session context is kept and the waiter stays armed.
- `finish` closes the apply tab, stops the waiter and drops the state. It
  reports whether the change is archived (`archived`) but does not require it –
  archiving stays a separate step. It refuses only while the apply agent is
  still `working` (override with `--force`). Pass `--lesson "<text>"` (and
  optionally `--lesson-scope project|global`, default `project`) to record the
  verified lesson of the run; the result names it under `lesson` (`null` when
  none was given), see [Lessons from earlier applies](#lessons-from-earlier-applies).
- `answer` sends keys (e.g. `enter`, `esc`, `y`) to a blocked apply agent, so
  the boss can answer follow-up questions itself.
- `claim` makes the current pane the boss of its Herdr workspace and returns
  `{workspace_id, pane_id, agent, status}` (`claimed`, `already_claimed` or
  `released`). `--name` overrides the derived agent name `boss-<workspace>`;
  `--release` removes the entry again. There is at most one living boss per
  workspace, but different workspaces can each have one.
- `session` starts a new boss tab in the target project's workspace with the
  runner's scoped `env` and registers the new pane as that workspace's boss
  (same claim rules as `claim`). The calling pane is left untouched. It returns
  `{project, workspace_id, agent, pane_id, tab_id, status}`; a workspace that
  already has a living boss is refused with `boss_exists` before any tab is
  created. Use it to stand up a boss for another project.
- `mission` groups a large task into an ordered list of changes (see
  [Missions](#missions)). `start` writes the mission doc if missing and never
  overwrites an existing one; `status` shows the goal and each change with a
  live-derived state; `next` dispatches the first change not yet `done` through
  the normal `dispatch` path and reports `mission_complete`, `executer_busy` or
  `change_not_ready`.
- `skills dir` prints where skills live: the project-scoped directories of both
  tools (`.opencode/skills`, `.claude/skills`) and the machine-global ones. Use
  it when the Explorer writes a verified procedure as a skill (see
  [Skills from experience](#skills-from-experience)).

All commands print JSON; errors appear as JSON on stderr with exit status 1
(like Herdr). The tools provide thin slash commands:
`/boss:dispatch`, `/boss:session`, `/boss:status`, `/boss:wait`,
`/boss:retrigger`, `/boss:finish`, `/boss:claim`, `/boss:mission`,
`/boss:skills` (Claude Code) or `/boss-dispatch`, `/boss-session`,
`/boss-status`, `/boss-wait`, `/boss-retrigger`, `/boss-finish`, `/boss-claim`,
`/boss-mission`, `/boss-skills` (OpenCode), which simply call the `boss`
command of the same name.

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

[lessons]
global = "~/.config/openspec-boss/lessons.md"
project = "openspec/lessons.md"

[missions]
dir = "openspec/missions"

[tests]
shop = "uv run pytest -q"
```

`{change}` is replaced by the change name on dispatch. The optional `[tests]`
table overrides the test command `boss review` runs for a project, keyed by the
registry name. Without an entry, boss detects a standard command from the
project (`Justfile`, `package.json` with its lockfile, pytest with `uv.lock`/
`poetry.lock`, `Makefile`); if it finds none – or the program is not installed
– the review reports `not_run`, not a red test.

The optional `[lessons]` table points boss at the two lesson stores: `global`
(default `~/.config/openspec-boss/lessons.md`, overridden by the environment
variable `BOSS_LESSONS_GLOBAL`) and `project` (default `openspec/lessons.md`,
relative to the project root, override with an absolute or `~` path if you want
it elsewhere). A leading `~` is expanded to `$HOME`. A configuration without
the table keeps working with exactly these defaults; see
[Lessons from earlier applies](#lessons-from-earlier-applies).

The optional `[missions]` table sets the directory of the mission docs
(`dir`, default `openspec/missions`), relative to the project root; an absolute
or `~` path is used as is and a leading `~` is expanded to `$HOME`. A
configuration without the table keeps working with the default; see
[Missions](#missions).

The `apply` template may carry more than the OpenSpec command: any free text is
sent to the agent along with it, before the note and the yield instruction. That
is the place for a runner-wide expectation such as **whether the apply should
commit its work** – whether an apply commits depends on the runner (claude tends
to commit, opencode to leave the working tree). State it once here instead of
repeating it in every `--note`; the review shows the difference as
`git.commits` versus `git.changed_files`. The `bypassPermissions`
arguments of the claude runner are a deliberate choice: an apply without a
human at the tab would otherwise stall on every permission prompt. If you
don't want that, delete the `args` line in `boss.toml`.

A runner may carry an optional `env` array of `KEY=VALUE` strings: boss sets
exactly these variables on the tab it starts (`herdr tab create --env`). For
`kind = "opencode"` a missing field yields the built-in default
`OPENCODE_CONFIG_CONTENT={"permission":"allow"}` – the highest-precedence
OpenCode config, so allow-all applies only inside the tabs boss starts, not to
every OpenCode session on the machine. A custom `env` replaces the default,
`env = []` disables it. Other kinds get nothing without an explicit `env`
(claude keeps `--permission-mode bypassPermissions`). Existing configurations
without the field stay valid.

A runner may carry readiness and first-run dialog fields. `ready` (with
optional `ready_regex = true` and `ready_timeout_ms`, default 90000) makes boss
wait with `herdr pane wait-output` for that marker in the pane before sending
the first prompt – this is what keeps a cold start on a slow host from
producing `agent_prompt_stalled`. Without `ready`, boss waits for the agent's
`idle` state and retries the prompt with growing backoff for up to
`BOSS_AGENT_PROMPT_TIMEOUT_MS` (default 90000). `dialog_match` + `dialog_keys`
answers a first-run dialog automatically: with `--permission-mode
bypassPermissions` claude shows a consent prompt on its first start, which you
otherwise accept once by hand. Example: `dialog_match = "Yes, I accept"`,
`dialog_keys = ["enter"]`.

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

## Lessons from earlier applies

An apply run ends its turn and is gone; what it learned should not be paid for
again by the next run. boss keeps **verified** lessons in two plain-Markdown
stores and feeds them back into the next apply prompt:

- **project store** (`openspec/lessons.md` in the target project, override with
  `[lessons] project`): properties of *this* project – how its tests run, where
  the real data lives, what a change must not break. It travels with the
  project repo.
- **global store** (`~/.config/openspec-boss/lessons.md`, override with
  `[lessons] global` or `BOSS_LESSONS_GLOBAL`): properties of the *machine and
  environment* that hold across every project and boss session – a firewall that
  throttles too many SSH calls, a runner that starts cold. It stays local and is
  never written into a project repo.
- **tool/process rules** (how the apply should commit, which tool to use for a
  check) belong in neither store – put them in the runner's `apply` template in
  `boss.toml`, once.

Each store is Markdown with an `## Active` section (the short, curated list that
is injected) and an `## Log` section (dated history). Only `## Active` lines
starting with `- ` reach a prompt; boss appends and never shortens or reorders,
so trimming the active list is a deliberate human decision.

`boss dispatch` reads both stores, global before project, and adds a capped
block ("verified lessons from earlier runs") to the apply prompt, before the
yield instruction; `boss retrigger` reuses the block frozen at dispatch. Missing
stores change nothing; an unreadable store is logged and the dispatch continues.
The block carries at most `BOSS_LESSONS_MAX` rules (default 20) and
`BOSS_LESSONS_MAX_CHARS` characters (default 2000).

The apply agent never writes a store: it reports observations in its `summary`,
the boss verifies them during the review and records only what survived, with
`boss finish <change> --lesson "<text>" [--lesson-scope project|global]`.
`boss review` shows the active lessons of both stores under `lessons.global` and
`lessons.project`; `boss status <change>` names them too.

## Skills from experience

Some lessons are not a single fact but a procedure: a multi-step check with a
trap that recurs. Those do not belong in the lesson stores (they would bloat
every prompt) and not in a `--note` (they outlive one change). The Explorer
writes them as **skills** instead, once the review has verified them:

- **skill vs. fact**: a short, always-relevant fact stays in a store
  (`boss finish --lesson`); a reusable procedure or pitfall becomes a skill; a
  pure runner/process rule (how the apply commits) goes into the runner's
  `apply` template, in neither.
- **location**: project skills live in the project repo, in both tools'
  directories (`<project>/.opencode/skills/<name>/SKILL.md` and
  `<project>/.claude/skills/<name>/SKILL.md`); properties of the machine or
  environment (a firewall, a cold runner) live in the global directories
  (`~/.config/opencode/skills/`, `~/.claude/skills/`). `boss skills dir
  [--project <name|path>] [--json]` prints the paths for a project.
- **format**: YAML frontmatter with `name` and `description`, then *When to
  Use*, *Procedure*, *Pitfalls* and *Verification*. A pitfall is a general rule
  plus one sentence of reason – no narration, ticket numbers or dates.
- **author**: only the Explorer writes a skill, after the review verified the
  lesson; the Executer never writes one. If approval is agreed for the project,
  the Explorer presents a new or changed skill first; without approval it stays
  a proposal.

The Executer loads skills through its own tool as needed – boss never injects a
skill body into the apply prompt. Without skills everything works as before.

## Limiting permissions to the workspace

By default OpenCode already allows everything, and a global
`"permission": "allow"` in `~/.config/opencode/opencode.jsonc` extends that to
**every** OpenCode session on the machine. boss does not touch that file. To
actually scope the grant:

1. Make the global rule restrictive again, e.g. `"permission": "ask"` (or
   remove the line). Sessions you start by hand then ask for confirmation.
2. Let boss start its sessions: apply tabs (`boss dispatch`) and boss tabs
   (`boss session`) get `OPENCODE_CONFIG_CONTENT={"permission":"allow"}` as an
   env variable, which overrides the global and the project config. Only those
   tabs run unattended.

The scope is per process, not per path: a session started with `allow` can
still read and write outside the workspace. That is intended for the boss
session, which drives its workspace; disable the default with `env = []` on a
runner if you do not want it. For `kind = "claude"` nothing changes – the
scoping there remains `--permission-mode bypassPermissions` on the runner.

## Dependencies

- **Herdr ≥ 0.9** with installed integrations for every runner kind in use
  (`herdr integration install claude`, `herdr integration install opencode`);
  `install.sh` checks this.
- **OpenSpec ≥ 1.13**, initialized for both tools in every target project
  (`openspec init --tools claude,opencode`), otherwise the apply agent does
  not know its command.
- **jq**, **bash ≥ 4**, **python3 ≥ 3.11** (only for `tomllib`), **setsid**
  (util-linux, for the detached waiter).
- **OpenCode** – the global `"permission"` setting is left untouched. The
  scoped grant lives in `OPENCODE_CONFIG_CONTENT` on the boss tabs; see
  [Limiting permissions to the workspace](#limiting-permissions-to-the-workspace).
- Target projects need `.claude/commands/opsx/` and
  `.opencode/commands/opsx-*.md` (created by `openspec init`).

## Installation

On a fresh server:

```bash
cd "$HOME"
mkdir -p "$HOME/.local/share"
herdr integration install claude            # if missing
herdr integration install opencode          # if missing
git clone https://github.com/autojo/openspec-boss.git "$HOME/.local/share/openspec-boss"
cd "$HOME/.local/share/openspec-boss"
./install.sh
```

`$HOME/.local/share/openspec-boss` is the suggested clone location: it is
user-local, survives shell changes, and needs no `~/work/<project>` directory.
The commands start in `$HOME` and create `~/.local/share` first, so they also
work when that directory is missing or the shell sits in a deleted working
directory. The location is only a recommendation – `install.sh` works from any
clone directory, because it derives the repository path from its own location
and links everything by absolute path.

`install.sh` links the skill and commands into `~/.claude/` and
`~/.config/opencode/`, creates `~/.local/bin/boss`, generates
`~/.config/openspec-boss/` and checks the prerequisites. It prints the
resolved repository path and warns when `~/.local/bin` is not in `PATH`,
naming the line to add to your shell configuration. It is idempotent:
`git pull && ./install.sh` is enough for updates. Existing foreign files at
the target locations are reported, never overwritten. Remove again with
`./install.sh --uninstall` (config and state are kept).

## Starting the boss session

1. Create a Herdr workspace for the boss, e.g. `boss`, and start Claude Code
   or OpenCode there. For Claude Code, `claude --add-dir <project>…` is
   recommended so that file access to the target projects does not trigger
   permission prompts (or keep the projects in a common parent directory).
2. `boss claim` (or the first `boss dispatch`/`retrigger`/`finish`/`answer`)
   registers the session as the boss of its Herdr workspace and generates
   `boss.toml`. Use a workspace per project for independent bosses.
3. Plan, dispatch, review changes – as described in the `boss` skill.

## Troubleshooting

- **Waiter logs**: `~/.local/state/openspec-boss/logs/<change>-<time>.log`
  records the start, the detected state, every delivery attempt and the end
  of the waiter.
- **State files**: `~/.local/state/openspec-boss/applies/` – one file per
  apply with agent, tab, pane, waiter PID and the dispatching boss; `boss
  status` without a change lists them.
- **Boss registry**: `~/.local/state/openspec-boss/bosses/` – one JSON file per
  workspace with `workspace_id`, `pane_id`, `agent` and `claimed_at`, written by
  `boss claim`. The waiter reads it to find the responsible boss; agents that no
  longer exist are skipped.
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
- **No waking?** The waiter resolves the responsible boss via the workspace
  registry, the recorded dispatcher boss and finally the global `BOSS_AGENT_NAME`
  (default `boss`). Check `herdr agent list` for that name and that the Herdr
  integration of the runner is installed (`herdr integration status`). An apply
  that sits in its own wait loop stays `working` and is never a settled state,
  so the waiter stays silent; the yield instruction prevents that, and
  `BOSS_WAITER_STALL_MS` surfaces it.
- **No boss reachable?** If none of the three candidates is alive, the waiter
  cannot prompt anyone: it shows a Herdr notification naming the apply instead.
  Claim a boss for the apply's workspace (`boss claim`) or start a global
  `boss`, then use the notification and `boss status` to continue.
- **`boss dispatch` reports `already_running`?** A pane with the tokens
  `os_change`/`os_phase=apply` or the change's apply agent already exists in
  the target project for this change – `boss status` shows it.
- **Waiter after a Herdr restart?** The waiter reports `lost` via prompt or
  notification and exits; `boss finish --force` cleans up the state.
