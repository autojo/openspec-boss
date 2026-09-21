---
name: "Boss: Review"
description: "Gather deterministic review facts for an apply: tasks, validate, tests, git, friction"
allowed-tools: Bash
category: "Boss"
tags: ["boss", "workflow"]
---

Run `boss review $ARGUMENTS --json` and summarize the JSON result for the user (tasks, validate, tests, git, friction). Read the changed files yourself to judge whether the diff is plausible. On error, report the error message from stderr.
