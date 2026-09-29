---
name: "Boss: Reconcile"
description: "Assemble the read-only context for the post-apply mission reconciliation"
allowed-tools: Bash
category: "Boss"
tags: ["boss", "workflow"]
---

Run `boss reconcile $ARGUMENTS` and summarize the JSON result for the user (charter state, remaining changes, backlog, open inbox items, journal tail). On error, report the error message from stderr.
