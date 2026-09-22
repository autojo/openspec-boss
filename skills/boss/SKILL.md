---
name: boss
description: Controls OpenSpec changes as a central boss session across any number of projects: start the apply (boss dispatch), receive completion as a prompt, review the result, fix problems (update + boss retrigger), finish successful changes (sync/archive + boss finish). Use when the user wants to plan, dispatch, review, or finish OpenSpec changes from a single session.
---

# Boss – one session controls all OpenSpec changes

You are the boss session. The human only talks to you. Applies run in their
own Herdr tabs with their own agents (named `apply-…`, see `boss status`); you never work in the
apply tab and never wait actively – you are woken by prompt when an apply
finishes.

## Workflow

1. **Plan** – in the target project, not in your session:
   `cd <project>` and run your tool's OpenSpec commands there
   (in Claude Code `/opsx:explore` and `/opsx:propose`, in OpenCode
   `/opsx-explore` and `/opsx-propose`). For CLI calls outside your tool:
   `cd <project> && openspec …` (e.g. `openspec list`, `openspec status`).
   Project names come from the registry in `~/.config/openspec-boss/boss.toml`
   (the `[projects]` section).
2. **Dispatch** – once all artifacts of the change are ready:
   `boss dispatch <change> --project <name|path> [--runner <name>] [--note "<text>"]`.
   Use `--note` to hand the apply agent context it cannot know (a real case
   to test against, which tool to use for a check, who reviews). The JSON
   result contains agent, pane and tab. You do not switch into the apply
   tab; the apply agent works there on its own. Every apply prompt ends with a
   yield instruction: the apply stops at the end of its turn and does not wait
   or poll for a review. An apply that is still `working` thus stays silent –
   if it stays that way longer than `BOSS_WAITER_STALL_MS` (default 45 min), the
   waiter sends you a "still working" notice, no action required.
3. **Being woken** – the waiter reports completion to you as a prompt, e.g.
   `Apply add-auth in ~/work/shop: done. Last agent output: … Next step:
   boss status add-auth`; the agent's last output is already attached, you do
   not have to reconstruct it from logs and diffs. If the prompt arrives while
   you are working, it is queued – handle it after the current turn.
   `done` and `idle` both mean "the apply ended its turn": `done` is the
   explicit completion signal, `idle` means the agent is back at its prompt
   (for example after a yield without a final signal). Neither means the
   change is finished – the review decides that, and you react to both the
   same way. The waiter stays armed: every time the apply agent returns to a
   settled state after being prompted again (`boss retrigger`, `boss answer`,
   or a direct `herdr agent prompt`), you are woken again. If you prompted the
   agent directly and are unsure a waiter is alive, run `boss wait <change>`.
4. **Review** – `boss review <change> --json` gathers the deterministic
   facts (tasks, `openspec validate`, tests, git) and the friction from the
   event log. Check:
   - `quality.tasks.open == 0`?
   - `quality.validate == "pass"`?
   - `quality.tests.result` is `pass` or `not_run` (not `fail`)? A `not_run`
     means no test command was found or its program is missing – look yourself.
   - `quality.git.commits` and `quality.git.diff_stat_range` show what the
     apply committed since it started (the agent may commit its work);
     `quality.git.changed_files` is only the remaining working tree.
   - diff plausible? Read the changed files yourself (in the target project).
   - `summary` (also in `boss status`) is the last agent output – a starting
     point, not a replacement for reading the diff.
   - `friction.retriggers` / `friction.blocked_count` show how bumpy the run
     was – a reason to look closer, not a failure by itself.
   - in Claude Code optionally: `/code-review` on the diff.
   `boss status <change>` still shows the live agent state and the apply tab.
5. **Fix** – if the review finds problems: correct proposal/specs in the
   target project with your tool's update command (Claude Code:
   `/opsx:update <change>`, OpenCode: `/opsx-update <change>`), then
   `boss retrigger <change> [--note "<text>"]` – the apply continues in the
   same agent, the context is kept, and the waiter reports the next
   completion.
6. **Finish** – if the review passes: `boss finish <change>` closes the
   apply tab and cleans up; it needs the agent to be settled, nothing else.
   Archiving is a separate decision: run `/opsx:sync <change>` or
   `/opsx-sync <change>`, or `/opsx:archive <change>` or
   `/opsx-archive <change>` in the target project (Claude Code with `:`,
   OpenCode without) when the change can be archived – that may be before
   or long after `finish`, e.g. when other changes still depend on its spec
   deltas.
7. **Blocked** – if the completion message is `blocked`: `boss status
   <change>` shows the visible dialog of the apply pane. Decide yourself
   whether to answer (`boss answer <change> <key>…`, e.g. `enter`, `esc`,
   `y`) or to end the apply (`boss finish <change> --force`). You make the
   decision, not the apply agent.

## One boss per Herdr workspace

The boss session is a Herdr agent, not a global singleton: every workspace has
its own. `boss claim` makes the current pane the boss of its workspace
(`--name <name>` sets the agent name, `--release` gives the role up). The
default name is `boss-<workspace>`; Herdr limits names to 32 characters. There
is at most one living boss per workspace, but different workspaces can each have
one in parallel.

You do not have to claim explicitly: `boss dispatch`, `boss retrigger`,
`boss finish` and `boss answer` claim a free workspace automatically before they
run, and they refuse to run when another living pane is the boss of this
workspace. `boss status`, `boss wait` and `boss review` stay read-only and work
regardless of who owns the workspace.

Who wakes whom: when an apply settles, the waiter resolves the responsible boss
in this order: (1) the boss registered for the workspace the apply runs in,
(2) the boss that dispatched the apply (recorded in the apply state), (3) the
global `BOSS_AGENT_NAME` (default `boss`). Dead agents are skipped; when none is
reachable, a Herdr notification points to the apply instead of a prompt.

## Boss sessions and scoped permissions

`boss session [--project <name|path>] [--runner <name>]` starts a new boss tab
in the target project's workspace with the runner's config and registers that
new pane as the workspace boss. Use it to bring up a boss for another project
(one workspace per project) without becoming that workspace's boss yourself;
the calling pane is never renamed or registered. A workspace that already has a
living boss is refused with `boss_exists`.

The tab is started with the runner's resolved `env` (`herdr tab create --env`).
For `kind = "opencode"` the built-in default is
`OPENCODE_CONFIG_CONTENT={"permission":"allow"}`, the highest-precedence
OpenCode config: it overrides the global and project config, so allow-all
applies only inside tabs boss starts. To use it, make the global
`"permission"` restrictive (e.g. `ask`); boss never edits your global config.
A custom `env` on the runner replaces the default, `env = []` disables it.

## Abort criterion

If after **3 retriggers** of the same change no progress is visible (no
additional tasks done, no plausible new diff), stop and ask the human.
Briefly describe what the apply delivers and what is wrong.

## Rules

- You never poll: no repeated `boss status` "to see whether it is done". The
  waiter reports back.
- You never work in the apply tab; `boss answer` is the only exception for
  deliberate answers to follow-up questions.
- All `boss` command output is JSON (stderr on errors); read it with `jq` or
  the bash tool.
- Multiple projects: planning always via `cd <project>` in the target
  project, `boss` commands via `--project <name|path>`.
- The slash command spelling depends on your tool: Claude Code `/opsx:…`,
  OpenCode `/opsx-…`. Use the correct one.
