# claude-setup — project rules

This repo IS the Claude Code configuration of every session on this machine
(and the machines it is synced to): `home/claude/*` <-> `~/.claude/*`,
`home/claude-local/*` <-> `~/.claude-local/*` (mapping in `MANIFEST`). A
request like "Claude does X wrong in my sessions" is a request to fix the
shipped config here.

## Syncing live and repo

- Default direction is live -> repo: edit `~/.claude`, run `./capture.sh`,
  commit. `capture.sh` refuses to run while `home/` has uncommitted changes
  (commit or stash first).
- Repo-side edits: `./install.sh --no-models` redeploys every MANIFEST file
  EXCEPT `roles.conf` (install-if-absent, user-owned: edit it live, then
  `sync-local.sh`). It also re-registers the MCP server and re-runs
  `sync-local.sh` when Ollama is up; expect one `settings.json.bak.*` per
  run, since the live file carries machine-local keys the repo never ships.
- `shell/` is outside MANIFEST: `install.sh` appends the wrapper to the rc
  once; wrapper edits need a manual rc update per machine.
- When changes take effect: CLAUDE.md, agent definitions and the hook wiring
  in `settings.json` are read at session start — they apply to the NEXT
  session (say so when reporting). Hook and statusline script bodies are
  re-executed on every call — live immediately.

## Changing things

- Model ASSIGNMENTS live in `home/claude/local-mode/roles.conf`. Agent
  `model:` frontmatter is generated from it by `sync-local.sh` — never
  hand-edit it (lint checks parity). The plan-preset table is defined in
  `sync-local.sh` (`plan_models`) and mirrored in `statusline.py`
  (`PLAN_PRESETS`, test-enforced): change both. Add no other hardcoded
  model names.
- `dispatch-directive.py` carries a condensed copy of the dispatch rules of
  BOTH CLAUDE.md files (`DIRECTIVE` <-> `home/claude/CLAUDE.md`,
  `LOCAL_DIRECTIVE` <-> `home/claude-local/CLAUDE.md`): mirror dispatch
  edits there.
- Hooks: on their OWN failure (bad stdin, missing tool, crash) they exit 0
  and print nothing — a broken hook must never wedge a session. Exit 2 +
  stderr is reserved for a deliberate block (commit-guard, post-edit-lint).
  They run through `run-hook.sh` (Git Bash on Windows): keep them portable,
  no macOS-only call without a fallback.
- Behavior changes get a test under `tests/`, wired BY NAME into
  `tests/lint.sh` (suites are not auto-discovered; CI runs `lint.sh` plus
  `shellcheck -S warning` — run it locally when available).
- A new shipped file goes into `MANIFEST`; an executable one also into the
  `chmod` list of `install.sh` and `tests/test-install-capture.sh`; an
  extension-less shell script into the shellcheck lists of `lint.sh` and
  `.github/workflows/ci.yml`.
- `bash tests/lint.sh` before every commit.
- Shareable repo: no machine model pin (`capture.sh` strips it); hooks
  derive personal identifiers (home path, git email) at runtime, never
  hardcode them.
