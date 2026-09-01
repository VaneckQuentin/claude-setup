# claude-setup — project rules

This repo IS the Claude Code configuration of every session on this machine
(and on the machines it is synced to). `home/claude/*` deploys to
`~/.claude/*` and `home/claude-local/*` to `~/.claude-local/*` (mapping in
`MANIFEST`, applied by `./install.sh`). Nothing here is an application: every
change is a change to how future Claude sessions behave — rules (CLAUDE.md),
hooks, statusline, subagents, model routing. Treat a request like "Claude
does X wrong in my sessions" as a request to fix the shipped config here.

## Working here

- Live and repo must never diverge. Either direction, synced immediately:
  edit under `home/` then `./install.sh --no-models` (check the live copy
  with `diff` against `~/.claude`), or edit live then `./capture.sh` before
  committing.
- A running session does not reload CLAUDE.md, settings or hooks: changes
  apply to the NEXT session. Say so when reporting a config change.
- Before committing: `bash tests/lint.sh` (syntax, MANIFEST consistency,
  behavioral suites). A new shipped file goes into `MANIFEST`; an executable
  one also into the `chmod` list of `install.sh` and
  `tests/test-install-capture.sh`.
- Hooks and scripts are behavior: test-first under `tests/`, and every hook
  is fail-open and silent on error — a broken hook must never wedge a
  session.
- Commits: Conventional Commits, one concern per commit (the commit guard
  enforces the format).
- The repo stays shareable: no personal data, no absolute home paths, no
  machine model pin (`capture.sh` strips it); hooks derive personal
  identifiers at runtime.
- Model names live only in `home/claude/local-mode/roles.conf` — never
  hardcode them elsewhere (agents, hooks, docs).
- Windows matters: hooks run through `run-hook.sh` under Git Bash; keep
  Python hooks portable (no macOS-only call without a fallback).
