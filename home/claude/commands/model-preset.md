---
description: Show or switch the Claude subagent model preset (eco / balanced / best)
argument-hint: [eco|balanced|best]
allowed-tools: Bash, Read
---

Manage the hybrid-mode Claude subagent model preset — the `claude.*` role
assignments in `~/.claude/local-mode/roles.conf` (explorer, implementer,
reviewer, reverse-engineer, browser-headless, browser-headed). This preset
changes SUBAGENT models only; the main/orchestrator model is switched
separately with the built-in `/model` command.

Argument given: `$ARGUMENTS`

If `$ARGUMENTS` is empty:
1. Read `~/.claude/local-mode/roles.conf` and print the current `claude.*`
   lines (the live subagent model assignments).
2. Run `bash "$HOME/.claude/local-mode/sync-local.sh" --plans` and print its
   output — the authoritative per-preset, per-role model table (presets:
   `eco`, recommended for Claude Pro; `balanced`, recommended for Max
   5x/$100; `best`, recommended for Max 20x/$200).
3. Stop there — do not run sync-local.sh --plan.

If `$ARGUMENTS` is not empty:
1. Validate it is one of `eco`, `balanced`, `best` (or the legacy aliases
   `pro`, `max100`, `max200`). If it isn't, report the valid values above and
   stop without running anything.
2. Run: `bash "$HOME/.claude/local-mode/sync-local.sh" --plan $ARGUMENTS`
3. Read `~/.claude/local-mode/roles.conf` again and print the resulting
   `claude.*` lines as confirmation of what changed.
4. Remind the user this only changed subagent models — use `/model` to
   change the main orchestrator model.
