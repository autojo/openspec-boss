---
name: "Boss: Status"
description: "Show the state of an apply: agent, tasks, diff, tab/pane"
allowed-tools: Bash
category: "Boss"
tags: ["boss", "workflow"]
---

Run `boss status $ARGUMENTS` and summarize the JSON result for the user (agent state, open/done tasks, changed files, visible dialog if `blocked`). On error, report the error message from stderr.
