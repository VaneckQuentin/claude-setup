#!/usr/bin/env bash
# bootstrap-reverse.sh — install the reverse-engineering stack for the agent.
# Idempotent: safe to re-run. macOS (Homebrew).
#
#   ./bootstrap-reverse.sh              core: radare2 + r2ghidra + r2mcp + r2pipe
#   ./bootstrap-reverse.sh --decompiler also pull LLM4Decompile (22B, ~13GB)
#   ./bootstrap-reverse.sh --full       also frida, yara, binwalk, angr, unicorn
set -uo pipefail

step(){ printf "\n\033[1m==> %s\033[0m\n" "$1"; }
ok(){ printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn(){ printf "  \033[33m!\033[0m %s\n" "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

DECOMPILER=0; FULL=0
for a in "$@"; do case "$a" in --decompiler) DECOMPILER=1;; --full) FULL=1;; esac; done

# ---- 1. radare2 (brings r2pm) --------------------------------------------
step "radare2"
if have radare2; then ok "radare2 $(radare2 -v 2>/dev/null | head -1)"; else
  have brew || { warn "Homebrew required: https://brew.sh"; exit 1; }
  echo "  installing via brew…"; brew install radare2 && ok "radare2 installed"
fi

# ---- 2. r2 plugins: r2ghidra (decompiler, no JVM) + r2mcp (agent bridge) ---
step "r2pm plugins (r2ghidra, r2mcp)"
if have r2pm; then
  r2pm -U >/dev/null 2>&1 && ok "r2pm index updated"
  for pkg in r2ghidra r2mcp; do
    if r2pm -l 2>/dev/null | grep -qx "$pkg"; then ok "$pkg already installed"; else
      echo "  building $pkg (r2ghidra can take a few minutes)…"
      r2pm -ci "$pkg" && ok "$pkg installed" || warn "$pkg install failed — see 'r2pm -ci $pkg'"
    fi
  done
else warn "r2pm not found (radare2 install may have failed)"; fi

# ---- 3. python glue ------------------------------------------------------
step "python r2pipe"
python3 -c "import r2pipe" 2>/dev/null && ok "r2pipe present" || { pip3 install --user r2pipe >/dev/null 2>&1 && ok "r2pipe installed" || warn "r2pipe install failed"; }

# ---- 4. models -----------------------------------------------------------
step "ollama models"
DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/roles.conf"
# shellcheck source=roles-lib.sh
source "$DIR/roles-lib.sh"

if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  present(){ curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json;print('\n'.join(m['name'] for m in json.load(sys.stdin).get('models',[])))"; }
  AVAIL="$(present)"
  if [ -f "$CONF" ]; then
    # Unique Ollama tags referenced by roles.conf (plain + tier.* roles;
    # claude.* excluded, those are Anthropic aliases, not Ollama tags).
    MODELS="$(roles_conf_unique_models "$CONF")"
    # dolphin-mixtral is the uncensored `ollama_run` pass for reverse-engineer
    # (see the reverse-role comment in roles.conf) — not a role= value itself.
    if grep -q "dolphin-mixtral" "$CONF"; then
      MODELS="$(printf '%s\ndolphin-mixtral:latest\n' "$MODELS" | sort -u)"
    fi
  else
    warn "$CONF not found — falling back to the legacy hardcoded model list"
    MODELS="qwen3-coder-next:latest
dolphin-mixtral:latest
gemma4:latest"
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    tag="$m"; case "$tag" in *:*) ;; *) tag="$tag:latest" ;; esac
    grep -qx "$tag" <<<"$AVAIL" && ok "$tag" || { echo "  pulling $tag…"; ollama pull "$tag" && ok "$tag pulled"; }
  done <<<"$MODELS"
  if [ "$DECOMPILER" = 1 ]; then
    m="MHKetbi/llm4decompile-22b-v2"
    grep -q "^$m" <<<"$AVAIL" && ok "$m" || { echo "  pulling $m (large)…"; ollama pull "$m" && ok "$m pulled"; }
  else warn "LLM4Decompile not pulled — re-run with --decompiler to add asm→C decompiler model"; fi
else warn "ollama not reachable on :11434 — start it and re-run"; fi

# ---- 5. optional heavier tools ------------------------------------------
if [ "$FULL" = 1 ]; then
  step "optional RE tools (--full)"
  for f in yara binwalk; do have "$f" && ok "$f" || { brew install "$f" >/dev/null 2>&1 && ok "$f installed" || warn "$f failed"; }; done
  have frida || { pip3 install --user frida-tools >/dev/null 2>&1 && ok "frida-tools installed" || warn "frida failed"; }
  python3 -c "import angr" 2>/dev/null && ok "angr" || { pip3 install --user angr >/dev/null 2>&1 && ok "angr installed" || warn "angr failed (heavy; needs its own venv often)"; }
  python3 -c "import unicorn" 2>/dev/null && ok "unicorn" || pip3 install --user unicorn >/dev/null 2>&1 && ok "unicorn" || true
else
  step "optional tools"; warn "skipped (frida/yara/binwalk/angr/unicorn) — re-run with --full to add them"
fi

# ---- 6. status -----------------------------------------------------------
step "status"
for t in radare2 r2pm objdump nm strings otool lldb; do have "$t" && ok "$t" || warn "$t missing"; done
r2pm -l 2>/dev/null | grep -qx r2mcp && ok "r2mcp (agent bridge ready: r2pm -r r2mcp)" || warn "r2mcp missing"
r2pm -l 2>/dev/null | grep -qx r2ghidra && ok "r2ghidra (decompiler: use 'pdg' in r2)" || warn "r2ghidra missing"
echo
ok "Reverse stack ready. The reverse-engineer subagent auto-loads r2mcp when invoked."
