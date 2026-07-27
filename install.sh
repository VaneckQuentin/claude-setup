#!/usr/bin/env bash
# install.sh — replicate the Claude Code setup on this machine.
#
#   ./install.sh                 install files, register MCP, sync roles;
#                                interactively offers the recommended Ollama
#                                models (or lets you pick your own per purpose)
#   ./install.sh --with-models   pull the roles.conf models without asking
#   ./install.sh --no-models     never prompt, never pull
#
# Idempotent: safe to re-run. Existing CLAUDE.md / settings.json that differ
# are backed up to *.bak.<timestamp> before being overwritten.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
WITH_MODELS=0
NO_MODELS=0
for a in "$@"; do
  case "$a" in
    --with-models) WITH_MODELS=1 ;;
    --no-models)   NO_MODELS=1 ;;
  esac
done

map_dest() {
  case "$1" in
    claude-local/*) echo "$HOME/.claude-local/${1#claude-local/}" ;;
    claude/*)       echo "$HOME/.claude/${1#claude/}" ;;
    *)              return 1 ;;
  esac
}

echo "== Prerequisites"
command -v python3 >/dev/null || { echo "ERROR: python3 is required." >&2; exit 1; }
command -v claude  >/dev/null || echo "WARNING: 'claude' CLI not found — install Claude Code first; MCP registration will be skipped."
command -v ollama  >/dev/null || {
  echo "WARNING: ollama not found — local delegation (ollama_run) and 'claude --local' need it."
  echo "         Install from https://ollama.com/download (macOS: brew install ollama),"
  echo "         then re-run ./install.sh to pick and pull models."
}
command -v uvx     >/dev/null || echo "WARNING: uvx (uv) not found — needed to run the Serena MCP in big projects."
command -v php     >/dev/null || echo "note: php not found — the lint hook will skip PHP files (fail-open)."

echo "== Installing files"
while IFS= read -r rel; do
  rel="${rel%%#*}"; rel="$(echo "$rel" | xargs 2>/dev/null || true)"
  [[ -z "$rel" ]] && continue
  src="$REPO/home/$rel"
  dest="$(map_dest "$rel")"
  [[ -f "$src" ]] || { echo "WARNING: $src missing in repo, skipping." >&2; continue; }
  mkdir -p "$(dirname "$dest")"
  BACKUP=""
  if [[ -f "$dest" ]] && ! cmp -s "$src" "$dest"; then
    case "$rel" in
      */CLAUDE.md|*/settings.json|*settings.json|*CLAUDE.md)
        cp "$dest" "$dest.bak.$STAMP"
        BACKUP="$dest.bak.$STAMP"
        echo "  backed up existing $(basename "$dest") -> $dest.bak.$STAMP" ;;
    esac
  fi
  cp "$src" "$dest"
  echo "  installed $dest"
  # Preserve a machine-local top-level "model" pin across settings.json
  # upgrades (the repo file doesn't ship one). Fail-soft: never abort install.
  if [[ -n "$BACKUP" && "$rel" == *settings.json ]]; then
    python3 - "$BACKUP" "$dest" <<'PY' || true
import json, sys
try:
    bak_path, dest_path = sys.argv[1], sys.argv[2]
    with open(bak_path) as f:
        old = json.load(f)
    # "claude-fable-5" was only ever the repo's OLD shipped default, not a
    # deliberate user choice — don't resurrect it on upgrade.
    if isinstance(old, dict) and "model" in old and old["model"] != "claude-fable-5":
        with open(dest_path) as f:
            new = json.load(f)
        new["model"] = old["model"]
        with open(dest_path, "w") as f:
            json.dump(new, f, indent=2)
            f.write("\n")
except Exception:
    pass
PY
  fi
done < "$REPO/MANIFEST"

chmod +x "$HOME/.claude/local-mode/claude-local" \
         "$HOME/.claude/local-mode/sync-local.sh" \
         "$HOME/.claude/local-mode/bootstrap-reverse.sh" \
         "$HOME/.claude/local-mode/roles-lib.sh" \
         "$HOME/.claude/hooks/dispatch-directive.py" \
         "$HOME/.claude/hooks/post-edit-lint.py" \
         "$HOME/.claude/hooks/commit-guard.py" \
         "$HOME/.claude/hooks/statusline.py" \
         "$HOME/.claude/hooks/run-hook.sh" 2>/dev/null || true

echo "== Registering ollama-delegate MCP (user scope)"
if command -v claude >/dev/null; then
  # Probe for a WORKING interpreter: on Windows, Store app-execution aliases
  # put fake python3/python stubs on PATH that exist but fail when run.
  PYBIN=""
  for c in python3 python py; do "$c" -c "" >/dev/null 2>&1 && { PYBIN="$c"; break; }; done
  [[ -n "$PYBIN" ]] || { echo "WARNING: no working python — register the MCP manually later." >&2; PYBIN="python3"; }
  SRV="$HOME/.claude/mcp-servers/ollama-delegate/server.py"
  command -v cygpath >/dev/null && SRV="$(cygpath -w "$SRV")"
  claude mcp remove -s user ollama-delegate >/dev/null 2>&1 || true
  # Fail-soft: a registration failure here must not abort install.
  claude mcp add -s user ollama-delegate -- "$PYBIN" "$SRV" \
    || echo "  WARNING: MCP registration failed — run manually later: claude mcp add -s user ollama-delegate -- $PYBIN $SRV"
  # Also register in the claude-local config dir so `claude --local` sessions
  # (CLAUDE_CONFIG_DIR=~/.claude-local) get the server too. That dir may never
  # have been initialized, so guard both calls — a failure here must not
  # abort install (mirrors the "remove" pair's `|| true` tolerance above).
  CLAUDE_CONFIG_DIR="$HOME/.claude-local" claude mcp remove -s user ollama-delegate >/dev/null 2>&1 || true
  CLAUDE_CONFIG_DIR="$HOME/.claude-local" claude mcp add -s user ollama-delegate -- "$PYBIN" "$SRV" \
    || echo "  WARNING: local-mode MCP registration failed — run manually later: CLAUDE_CONFIG_DIR=~/.claude-local claude mcp add -s user ollama-delegate -- $PYBIN $SRV"
else
  echo "  skipped ('claude' not found). Later, for both modes: claude mcp add -s user ollama-delegate -- python3 ~/.claude/mcp-servers/ollama-delegate/server.py"
  echo "  and: CLAUDE_CONFIG_DIR=~/.claude-local claude mcp add -s user ollama-delegate -- python3 ~/.claude/mcp-servers/ollama-delegate/server.py"
fi

echo "== shell wrapper (claude --local)"
# The function body is bash/zsh compatible; pick the rc matching the login
# shell (macOS defaults to zsh, so don't just fall back to .bashrc there).
case "$(basename "${SHELL:-}")" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    RC="$HOME/.profile" ;;
esac
[[ -f "$RC" ]] || touch "$RC"
if grep -q "local-mode/claude-local" "$RC"; then
  echo "  already present in $RC"
else
  { echo ""; cat "$REPO/shell/claude-wrapper.zsh"; } >> "$RC"
  echo "  appended to $RC"
fi

ROLES_LIVE="$HOME/.claude/local-mode/roles.conf"

# shellcheck source=home/claude/local-mode/roles-lib.sh
source "$REPO/home/claude/local-mode/roles-lib.sh"

# Print "role model" pairs for the Ollama-backed roles (claude.* excluded).
list_role_models() { roles_conf_list_models "$ROLES_LIVE"; }

# set_role_model <role> <model> — rewrite one assignment, keeping its comment.
set_role_model() { roles_conf_set "$ROLES_LIVE" "$1" "$2"; }

pull_role_models() {
  roles_conf_unique_models "$ROLES_LIVE" | while read -r m; do
    ollama pull "$m" || echo "  WARNING: pull failed for $m — pull manually and re-run sync-local.sh"
  done
}

echo "== Local models (Ollama)"
if ! command -v ollama >/dev/null; then
  echo "  skipped — ollama is not installed (see the warning above)."
elif [[ "$WITH_MODELS" == 1 ]]; then
  echo "  Pulling models from roles.conf (this is tens of GB)..."
  pull_role_models
elif [[ "$NO_MODELS" == 1 || ! -t 0 ]]; then
  echo "  skipped — pull later with ./install.sh --with-models, or per model"
  echo "  with 'ollama pull' + edit roles.conf + sync-local.sh."
else
  echo "  roles.conf maps each purpose to an Ollama model. Recommended defaults"
  echo "  (tuned on an Apple Silicon Mac, 128 GB RAM; they run well from ~36 GB):"
  list_role_models | awk '{printf "    %-14s -> %s\n", $1, $2}'
  printf "  Download these now? [Y]es / [c]ustomize per purpose / [s]kip: "
  read -r ans
  case "${ans:-y}" in
    [Cc]*)
      echo "  Enter an Ollama tag per purpose (empty keeps the current value)."
      echo "  Any tag from https://ollama.com/library works; tool-capable models"
      echo "  are required for orchestrator/code/reverse."
      groups=()
      while IFS= read -r line; do groups+=("$line"); done < <(
        list_role_models |
        awk '{g[$2] = g[$2] (g[$2] ? "," : "") $1} END {for (m in g) print m, g[m]}'
      )
      for line in "${groups[@]}"; do
        model="${line%% *}"; roles="${line#* }"
        printf "    %s (currently %s): " "$roles" "$model"
        read -r new
        if [[ -n "$new" && "$new" != "$model" ]]; then
          for r in ${roles//,/ }; do set_role_model "$r" "$new"; done
        fi
      done
      printf "  Pull the selected models now? [Y/n]: "
      read -r p
      [[ "${p:-y}" =~ ^[Nn] ]] || pull_role_models
      ;;
    [Ss]*|[Nn]*)
      echo "  skipped — pull later with ./install.sh --with-models." ;;
    *)
      pull_role_models ;;
  esac
fi

echo "== Claude plan profile (hybrid subagent models)"
SYNCED=0
apply_plan() {
  if "$HOME/.claude/local-mode/sync-local.sh" --plan "$1"; then SYNCED=1
  else echo "  preset failed — run sync-local.sh --plan $1 manually." >&2; fi
}
if [[ "$NO_MODELS" != 1 && -t 0 ]]; then
  echo "  Bigger Claude plans can afford stronger subagent models. Presets:"
  echo "    [1] eco       — recommended for Claude Pro: haiku recon, sonnet for everything else"
  echo "    [2] balanced  — recommended for Max 5x/\$100: opus for review/reverse (repo default)"
  echo "    [3] best      — recommended for Max 20x/\$200: sonnet recon, opus implementation, fable review"
  printf "  Apply a preset? [1/2/3/k(eep current), default k]: "
  read -r plan
  case "${plan:-k}" in
    1) apply_plan eco ;;
    2) apply_plan balanced ;;
    3) apply_plan best ;;
    *) echo "  keeping current claude.* assignments." ;;
  esac
else
  echo "  keeping current claude.* assignments (later: sync-local.sh --plan eco|balanced|best; old names pro|max100|max200 still work)."
fi

echo "== Pre-warming Playwright MCP (browser agents)"
if command -v npx >/dev/null; then
  (npx -y "@playwright/mcp@latest" --version >/dev/null 2>&1 || true) &
  echo "  fetching @playwright/mcp in the background (speeds up the first browser-agent spawn)."
  echo "  Chromium itself, if missing:  npx playwright install chromium"
else
  echo "  skipped — node/npx not found (only the browser agents need them)."
fi

echo "== Syncing roles (agents frontmatter, models.env, tiers.json)"
if [[ "$SYNCED" == 1 ]]; then
  echo "  already synced by the plan preset above."
elif curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  "$HOME/.claude/local-mode/sync-local.sh"
else
  echo "  Ollama not running — run ~/.claude/local-mode/sync-local.sh once it is."
  echo "  (tiers.json is still needed by the MCP server; sync generates it.)"
fi

cat <<'EOF'
== Done. Remaining manual steps:
  1. Log in:  claude   (credentials are never part of this repo)
  2. Per-project Serena, from inside each big codebase:
       claude mcp add -s local serena -- uvx --from "git+https://github.com/oraios/serena" serena start-mcp-server
  3. Models not pulled? Re-run with --with-models, or `ollama pull` per roles.conf.
  4. Open a new shell (or `source ~/.zshrc`) for the `claude --local` wrapper.
  5. Windows + PowerShell? Also run once, FROM THE POWERSHELL YOU ACTUALLY USE
     (pwsh 7 and powershell 5.1 have separate profiles):
       pwsh -ExecutionPolicy Bypass -File shell\install-wrapper.ps1
EOF
