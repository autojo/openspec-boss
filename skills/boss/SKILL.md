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
   tab; the apply agent works there on its own.
3. **Being woken** – the waiter reports completion to you as a prompt, e.g.
   `Apply add-auth in ~/work/shop: done. Next step: boss status add-auth`. If
   the prompt arrives while you are working, it is queued – handle it after
   the current turn. The waiter stays armed: every time the apply agent
   returns to a settled state after being prompted again (`boss retrigger`,
   `boss answer`, or a direct `herdr agent prompt`), you are woken again. If
   you prompted the agent directly and are unsure a waiter is alive, run
   `boss wait <change>`.
4. **Review** – `boss status <change>` (or `--json`). Check:
   - all tasks in `tasks.md` checked off (`tasks.open == 0`)?
   - diff plausible? Read the changed files yourself (in the target project).
   - `cd <project> && openspec validate --strict` passes?
   - the project's tests pass if a standard command is recognizable
     (`npm test`, `pytest`, `just test`)?
   - in Claude Code optionally: `/code-review` on the diff.
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
