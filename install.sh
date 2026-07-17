#!/usr/bin/env bash
# install.sh — replicate the Claude Code setup on this machine.
#
#   ./install.sh                 install files, register MCP, sync roles
#   ./install.sh --with-models   also `ollama pull` the models from roles.conf
#
# Idempotent: safe to re-run. Existing CLAUDE.md / settings.json that differ
# are backed up to *.bak.<timestamp> before being overwritten.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
WITH_MODELS=0
[[ "${1:-}" == "--with-models" ]] && WITH_MODELS=1

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
command -v ollama  >/dev/null || echo "WARNING: ollama not found — local delegation and full-local mode need it."
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
  if [[ -f "$dest" ]] && ! cmp -s "$src" "$dest"; then
    case "$rel" in
      */CLAUDE.md|*/settings.json|*settings.json|*CLAUDE.md)
        cp "$dest" "$dest.bak.$STAMP"
        echo "  backed up existing $(basename "$dest") -> $dest.bak.$STAMP" ;;
    esac
  fi
  cp "$src" "$dest"
  echo "  installed $dest"
done < "$REPO/MANIFEST"

chmod +x "$HOME/.claude/local-mode/claude-local" \
         "$HOME/.claude/local-mode/sync-local.sh" \
         "$HOME/.claude/local-mode/bootstrap-reverse.sh" \
         "$HOME/.claude/hooks/dispatch-directive.py" \
         "$HOME/.claude/hooks/post-edit-lint.py" \
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
  claude mcp add -s user ollama-delegate -- "$PYBIN" "$SRV"
else
  echo "  skipped ('claude' not found). Later: claude mcp add -s user ollama-delegate -- python3 ~/.claude/mcp-servers/ollama-delegate/server.py"
fi

echo "== shell wrapper (claude --local)"
# The function body is bash/zsh compatible; pick whichever rc the machine uses.
RC="$HOME/.zshrc"
[[ -f "$RC" ]] || RC="$HOME/.bashrc"
if [[ -f "$RC" ]] && grep -q "local-mode/claude-local" "$RC"; then
  echo "  already present in $RC"
else
  { echo ""; cat "$REPO/shell/claude-wrapper.zsh"; } >> "$RC"
  echo "  appended to $RC"
fi

if [[ "$WITH_MODELS" == 1 ]] && command -v ollama >/dev/null; then
  echo "== Pulling Ollama models from roles.conf (this is tens of GB)"
  awk -F= '!/^\s*#/ && NF==2 && $1 !~ /claude\./ {gsub(/[ \t]/,"",$2); sub(/#.*/,"",$2); print $2}' \
    "$HOME/.claude/local-mode/roles.conf" | sort -u | while read -r m; do
    [[ -n "$m" ]] && ollama pull "$m"
  done
fi

echo "== Syncing roles (agents frontmatter, models.env, tiers.json)"
if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
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
EOF
