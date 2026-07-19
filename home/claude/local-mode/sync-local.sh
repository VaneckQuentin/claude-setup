#!/usr/bin/env bash
# sync-local.sh — apply roles.conf (the ONE source of truth) everywhere:
#   plain roles    -> ~/.claude-local/agents frontmatter + models.env (full-local)
#   tier.* roles   -> tiers.json (read by the ollama-delegate MCP / ollama_run)
#   claude.* roles -> ~/.claude/agents frontmatter (hybrid-mode subagents)
# No proxy: Claude Code talks to Ollama's native Anthropic endpoint directly.
#
#   ~/.claude/local-mode/sync-local.sh            apply roles.conf
#   ~/.claude/local-mode/sync-local.sh --detect   list models + role suggestions
#   ~/.claude/local-mode/sync-local.sh --plan X   set hybrid subagent models to
#                                                 a Claude-plan preset, then sync
#                                                 (X = eco | balanced | best;
#                                                 recommended for Pro | Max
#                                                 5x/$100 | Max 20x/$200 resp.;
#                                                 old names pro|max100|max200
#                                                 still work)
set -euo pipefail

DIR="$HOME/.claude/local-mode"
CONF="$DIR/roles.conf"
ENVFILE="$DIR/models.env"
TIERSFILE="$DIR/tiers.json"
AGENTS_LOCAL="$HOME/.claude-local/agents"
AGENTS_HYBRID="$HOME/.claude/agents"
OLLAMA="http://localhost:11434"

installed_models() { curl -sf "$OLLAMA/api/tags" 2>/dev/null | python3 -c "import sys,json;[print(m['name']) for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null; }

if [[ "${1:-}" == "--detect" ]]; then
  echo "Installed Ollama models:"; installed_models | sed 's/^/  - /'
  echo; echo "Heuristic role suggestions:"
  installed_models | while read -r m; do
    lc=$(echo "$m" | tr '[:upper:]' '[:lower:]'); role="general"
    case "$lc" in
      *dolphin*|*uncensored*|*abliterated*) role="uncensored ollama_run passes (usually NO tool support)" ;;
      *laguna*|*coder*|*devstral*|*deepseek*) role="orchestrator / code / tier.code (agentic coder)" ;;
      *gemma*|*phi*|*mini*|*qwen*|*3b*|*7b*|*8b*|*12b*) role="explore / cheap / tier.cheap (fast)" ;;
    esac
    printf "  %-32s -> %s\n" "$m" "$role"
  done
  echo; echo "Edit $CONF to assign, then run without --detect."
  exit 0
fi

# --plan: rewrite the claude.* lines to a preset matched to the Claude
# subscription's budget, then fall through to a normal sync.
if [[ "${1:-}" == "--plan" ]]; then
  case "${2:-}" in
    eco|pro)         ex=haiku;  im=sonnet; rv=sonnet; re=sonnet; br=sonnet ;;
    balanced|max100) ex=haiku;  im=sonnet; rv=opus;   re=opus;   br=sonnet ;;
    best|max200)     ex=sonnet; im=opus;   rv=fable;  re=fable;  br=sonnet ;;
    *)
      echo "Usage: sync-local.sh --plan eco|balanced|best" >&2
      echo "  eco       (recommended for Claude Pro)          haiku recon, sonnet everything else" >&2
      echo "  balanced  (recommended for Max 5x/\$100)          opus for review/reverse" >&2
      echo "  best      (recommended for Max 20x/\$200)         sonnet recon, opus implementation, fable review" >&2
      echo "  (old names pro|max100|max200 still work as aliases)" >&2
      exit 1 ;;
  esac
  set_claude_role() { # <role-suffix> <model> — rewrite one claude.* line in place
    awk -v re="^[[:space:]]*claude\\.$1[[:space:]]*=" -v m="$2" \
      '$0 ~ re { sub(/=[[:space:]]*[^#[:space:]]+/, "= " m) } { print }' \
      "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  }
  set_claude_role explorer         "$ex"
  set_claude_role implementer      "$im"
  set_claude_role reviewer         "$rv"
  set_claude_role reverse-engineer "$re"
  set_claude_role browser-headless "$br"
  set_claude_role browser-headed   "$br"
  echo "Applied plan preset '$2' to claude.* roles in roles.conf."
fi

[[ -f "$CONF" ]] || { echo "ERROR: $CONF not found." >&2; exit 1; }

# Parse roles.conf -> parallel arrays (bash 3.2 safe: no assoc arrays).
roles=(); models=()
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs 2>/dev/null || true)"
  [[ -z "$line" ]] && continue
  role="$(echo "$line" | cut -d= -f1 | xargs)"
  model="$(echo "$line" | cut -d= -f2- | xargs)"
  # tolerate a stray trailing integer (legacy num_ctx column)
  last="${model##* }"; [[ "$model" == *" "* && "$last" =~ ^[0-9]+$ ]] && model="${model% *}"
  roles+=("$role"); models+=("$model")
done < "$CONF"
[[ ${#roles[@]} -gt 0 ]] || { echo "ERROR: no roles parsed." >&2; exit 1; }

model_for() { local r="$1" i; for i in "${!roles[@]}"; do [[ "${roles[$i]}" == "$r" ]] && { echo "${models[$i]}"; return; }; done; }

# Warn about referenced-but-missing models (claude.* roles are Anthropic
# aliases, not Ollama tags — skip them).
avail="$(installed_models || true)"
if [[ -n "$avail" ]]; then
  for i in "${!roles[@]}"; do
    [[ "${roles[$i]}" == claude.* ]] && continue
    m="${models[$i]}"; [[ "$m" == *:* ]] || m="$m:latest"  # tagless -> implicit :latest
    grep -qxF "$m" <<<"$avail" || echo "WARNING: '${models[$i]}' is not installed (ollama pull it)." >&2
  done
fi

update_agent() { # <dir> <file> <tag>
  local f="$1/$2" tag="$3"
  [[ -f "$f" ]] || { echo "WARNING: agent $f missing, skipping." >&2; return; }
  [[ -n "$tag" ]] || { echo "WARNING: no model mapped for agent $2." >&2; return; }
  # -i.bak + rm: portable across BSD (macOS) and GNU (Linux/WSL) sed
  sed -i.bak -E "s|^model:.*|model: $tag|" "$f" && rm -f "$f.bak"
  printf "  %-22s model: %s\n" "$2" "$tag"
}

echo "Applying local roles to subagents in $AGENTS_LOCAL:"
update_agent "$AGENTS_LOCAL" explorer.md         "$(model_for explore)"
update_agent "$AGENTS_LOCAL" implementer.md      "$(model_for code)"
update_agent "$AGENTS_LOCAL" reviewer.md         "$(model_for orchestrator)"
update_agent "$AGENTS_LOCAL" reverse-engineer.md "$(model_for reverse)"

echo "Applying Claude roles to hybrid subagents in $AGENTS_HYBRID:"
update_agent "$AGENTS_HYBRID" explorer.md         "$(model_for claude.explorer)"
update_agent "$AGENTS_HYBRID" implementer.md      "$(model_for claude.implementer)"
update_agent "$AGENTS_HYBRID" reviewer.md         "$(model_for claude.reviewer)"
update_agent "$AGENTS_HYBRID" reverse-engineer.md "$(model_for claude.reverse-engineer)"
update_agent "$AGENTS_HYBRID" browser-headless.md "$(model_for claude.browser-headless)"
update_agent "$AGENTS_HYBRID" browser-headed.md   "$(model_for claude.browser-headed)"

# tiers.json — consumed by the ollama-delegate MCP server at startup.
{
  echo "{"
  echo "  \"_comment\": \"AUTO-GENERATED by sync-local.sh — edit roles.conf (tier.*) instead.\","
  echo "  \"code\": \"$(model_for tier.code)\","
  echo "  \"cheap\": \"$(model_for tier.cheap)\""
  echo "}"
} > "$TIERSFILE"
echo "Wrote $TIERSFILE (code=$(model_for tier.code), cheap=$(model_for tier.cheap))."

ORCH="$(model_for orchestrator)"; CHEAP="$(model_for cheap)"
{
  echo "# AUTO-GENERATED by sync-local.sh — do not edit; edit roles.conf instead."
  echo "ANTHROPIC_MODEL=$ORCH"
  echo "ANTHROPIC_SMALL_FAST_MODEL=${CHEAP:-$ORCH}"
} > "$ENVFILE"

echo "Wrote $ENVFILE (main=$ORCH, background=${CHEAP:-$ORCH})."
echo "Done. Start full-local mode with:  claude --local"
