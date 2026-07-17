# claude-setup

Portable replica of my Claude Code setup: orchestrator dispatch rules, tiered
subagents, local-model delegation (Ollama), full-local mode, and hooks.
**Keep this repo private** — it holds personal workflow config (no credentials,
but no reason to publish either).

## What it covers

| Piece | Files |
|---|---|
| Global rules (dispatch, language, pipelines) | `home/claude/CLAUDE.md` |
| Settings: model, effort, hooks, LSP plugins | `home/claude/settings.json` |
| Dispatch hook (bulk-intent gate, FR+EN) | `home/claude/hooks/dispatch-directive.py` |
| Post-edit lint hook (token-free syntax checks) | `home/claude/hooks/post-edit-lint.py` |
| Hybrid subagents (haiku/sonnet/opus tiers) | `home/claude/agents/*.md` |
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
   file types; it fail-opens without them). For the `ui-tester` agent
   (browser testing): node + `npx playwright install chromium`.
2. Clone this repo, then:

   ```sh
   ./install.sh --with-models    # or without the flag to skip the ~30GB pull
   ```

3. `claude` once to log in.
4. In each big codebase (symbol navigation worth ~30 tool schemas/session):

   ```sh
   claude mcp add -s local serena -- uvx --from "git+https://github.com/oraios/serena" serena start-mcp-server
   ```

## Keeping machines in sync

Edits happen in `~/.claude` (live), not in the repo. To publish them:

```sh
./capture.sh    # live files -> repo
git add -A && git commit && git push
```

On other machines: `git pull && ./install.sh` (it backs up any diverging
CLAUDE.md/settings.json to `*.bak.<timestamp>` first).

## Windows

Claude Code itself runs fine in cmd/PowerShell — but hooks are NEVER executed
by cmd: Claude Code runs shell-form hooks through **Git Bash** when installed
(PowerShell only as fallback). So:

- **Native Windows (cmd/PowerShell + Git for Windows)** — hybrid mode works:
  install Git for Windows and Python, clone this repo, run `./install.sh`
  **from Git Bash**. Hook commands and MCP registration auto-detect
  `python3` vs `python` and convert paths (`cygpath`). Ollama runs natively
  on Windows, so `localhost:11434` needs no adaptation. Full-local mode
  (`claude --local`, `sync-local.sh`) stays bash-only — run those from
  Git Bash too, or ask for a .cmd port if you really live in cmd.
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
