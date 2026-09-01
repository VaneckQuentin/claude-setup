# claude-setup

Portable Claude Code setup: orchestrator dispatch rules, tiered subagents,
local-model delegation (Ollama), full-local mode, and hooks. No credentials or
personal data live here — install it, log in, and it works.

## What it covers

| Piece | Files |
|---|---|
| Global rules (dispatch, language, pipelines) | `home/claude/CLAUDE.md` |
| Settings: effort, hooks, statusline, LSP plugins (machine-local model pin preserved, not shipped) | `home/claude/settings.json` |
| Statusline (model + effort, branch, agent preset, plan usage %, context %) | `home/claude/hooks/statusline.py` |
| Dispatch hook (bulk-intent gate, FR+EN) | `home/claude/hooks/dispatch-directive.py` |
| Commit guard (blocks commits leaking secrets/personal data) | `home/claude/hooks/commit-guard.py` |
| Post-edit lint hook (token-free syntax checks) | `home/claude/hooks/post-edit-lint.py` |
| Keep-awake hook (blocks idle SYSTEM sleep for the length of a turn; macOS `caffeinate`, native Windows `SetThreadExecutionState`; silent no-op under WSL2/Linux; `CLAUDE_KEEP_AWAKE_MAX_HOURS` caps the hold, default 8h) | `home/claude/hooks/keep-awake.py` |
| Hybrid subagents (haiku/sonnet/opus tiers) | `home/claude/agents/*.md` |
| `/model-preset` command (show/switch the subagent model preset) | `home/claude/commands/model-preset.md` |
| ollama-delegate MCP server | `home/claude/mcp-servers/ollama-delegate/server.py` |
| Full-local mode + model mapping (single source: `roles.conf`) | `home/claude/local-mode/*` |
| Full-local config dir (own CLAUDE.md, agents) | `home/claude-local/*` |
| `claude --local` shell wrapper | `shell/claude-wrapper.zsh` |

Not covered (by design): credentials/login, session state (`~/.claude.json`),
per-project Serena registrations (see below), the Ollama model weights.

## New machine

1. Install prerequisites: [Claude Code](https://claude.com/claude-code),
   `python3`, [Ollama](https://ollama.com) ≥ 0.30 (native Anthropic endpoint),
   `uv` (for `uvx`/Serena). Optional: `php`, `node` (lint hook checks more
   file types; it fail-opens without them). For the browser agents
   (`browser-headless` by default; `browser-headed` opens a visible window —
   the orchestrator asks which you want): node +
   `npx playwright install chromium`.
2. Clone this repo, then:

   ```sh
   ./install.sh
   ```

   If Ollama is installed, the script shows the recommended model per purpose
   (defaults tuned on an Apple Silicon Mac with 128 GB RAM — they run well
   from ~36 GB) and asks whether to download them, customize each purpose
   with your own Ollama tags, or skip. Non-interactive: `--with-models`
   pulls the roles.conf set (tens of GB), `--no-models` skips.

   It also asks which **Claude plan preset** to apply — bigger plans can
   afford stronger subagent models. Presets are `eco`, `balanced`, and
   `best`, recommended for Claude Pro, Max 5x/$100, and Max 20x/$200
   respectively; `~/.claude/local-mode/sync-local.sh --plans` is the
   authoritative listing of what each preset assigns per role. Change it
   any time with `~/.claude/local-mode/sync-local.sh --plan eco|balanced|best`
   (old names `pro`/`max100`/`max200` still work).

3. `claude` once to log in.
4. In each big codebase (symbol navigation worth ~30 tool schemas/session):

   ```sh
   claude mcp add -s local serena -- uvx --from "git+https://github.com/oraios/serena" serena start-mcp-server
   ```

5. Optional, only for the `reverse-engineer` subagent (binary analysis via a
   radare2 MCP bridge): once per machine (macOS/Homebrew),

   ```sh
   ~/.claude/local-mode/bootstrap-reverse.sh
   ```

   Core installs radare2 + r2ghidra + r2mcp + r2pipe; add `--decompiler` for
   the LLM4Decompile model (~13 GB) or `--full` for frida/yara/binwalk/angr/
   unicorn too. Idempotent, safe to re-run.

## Keeping machines in sync

Edits happen in `~/.claude` (live), not in the repo. To publish them:

```sh
./capture.sh    # live files -> repo
git add -A && git commit && git push
```

On other machines: `git pull && ./install.sh` (it backs up any diverging
CLAUDE.md/settings.json to `*.bak.<timestamp>` first). The repo's
`settings.json` never carries a model pin — `capture.sh` strips any local
`model` key before it lands in the repo, and `install.sh` restores any
machine-local top-level key the repo doesn't ship (your `model` pin, and
anything Claude Code itself adds like `feedbackDrafts`/`modelSettings`) from
the backup on upgrade — the repo always wins on keys it does ship.
`home/claude/local-mode/roles.conf` is user-owned state (you edit it
directly, `sync-local.sh --plan` rewrites it): install-if-absent only — once
it exists on a machine, a re-run of `./install.sh` never overwrites it.

Before committing, run `bash tests/lint.sh` — it checks shell/Python/JSON
syntax, MANIFEST consistency, roles.conf-vs-agent-frontmatter drift, and the
behavioral suites under `tests/` (commit-guard, ollama-delegate path
confinement, statusline, dispatch-directive, keep-alive,
`install.sh`/`capture.sh` sandboxed install/capture behavior, and the
PowerShell launcher). CI runs the same script plus `shellcheck` on every
push/PR.

## Windows

Claude Code itself runs fine in cmd/PowerShell — but hooks are NEVER executed
by cmd: Claude Code runs shell-form hooks through **Git Bash** when installed
(PowerShell only as fallback). So:

- **Native Windows (cmd/PowerShell + Git for Windows)** — hybrid mode works:
  install Git for Windows and Python, clone this repo, run `./install.sh`
  **from Git Bash**. Hook commands and MCP registration auto-detect
  `python3` vs `python` and convert paths (`cygpath`). Ollama runs natively
  on Windows, so `localhost:11434` needs no adaptation. For `claude --local`
  in **PowerShell**, run once — from the PowerShell you actually use daily
  (`pwsh` 7 and `powershell` 5.1 have SEPARATE profiles):
  `pwsh -ExecutionPolicy Bypass -File shell\install-wrapper.ps1` (or
  `powershell -ExecutionPolicy ...` if that's your shell) —
  it adds a wrapper to your $PROFILE that launches the native PowerShell
  launcher (`claude-local.ps1`), which even reads OLLAMA_* tuning from the
  real Windows env scopes (the bash launcher can't). `sync-local.sh` stays
  bash — run it from Git Bash when you change roles.conf.
- **WSL2** — everything works exactly as on macOS/Linux; Ollama can run on
  the Windows side (GPU) with `localhost:11434` reachable via WSL2 mirrored
  networking (Windows 11), else point `OLLAMA_HOST`/`OLLAMA_URL` at the
  host IP.
- **Without Git Bash at all** — hooks fall back to PowerShell; the current
  hook commands are sh-syntax and would need PowerShell variants. Just
  install Git for Windows instead.

## Changing models

Everything is driven by `home/claude/local-mode/roles.conf` (full-local roles,
`ollama_run` tiers, hybrid subagent Claude models). Edit it, run
`~/.claude/local-mode/sync-local.sh`, then `./capture.sh` + commit.
Claude-plan presets: `sync-local.sh --plan eco|balanced|best` (old names
`pro`/`max100`/`max200` still work; `sync-local.sh --plans` prints the
per-role table), or interactively from inside a session with
`/model-preset [eco|balanced|best]`.

Full-local note: the Ollama *server* context length must be ≥64K for
`claude --local` (Ollama app → Settings → Context length, or
`OLLAMA_CONTEXT_LENGTH=131072 ollama serve`) — the launcher warns if it looks
too small. `ollama_run` delegations size their own context per request.
