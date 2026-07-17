# --- Claude Code: `claude --local` launches full-local (Ollama) mode ---
claude() {
  if [[ "$1" == "--local" ]]; then
    shift
    "$HOME/.claude/local-mode/claude-local" "$@"
  else
    command claude "$@"
  fi
}
