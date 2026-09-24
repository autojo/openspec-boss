---
name: "Boss: Mission"
description: "Plan a large task as an ordered list of changes (start/status/next)"
allowed-tools: Bash
category: "Boss"
tags: ["boss", "workflow"]
---

Run `boss mission $ARGUMENTS` and summarize the JSON result for the user (goal, each change with its derived state, progress; on `next` the started change or `mission_complete`/`executer_busy`/`change_not_ready`). On error, report the error message from stderr.
