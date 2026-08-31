#!/usr/bin/env bash
# tests/lint.sh — repo self-checks, runnable locally and in CI.
#   bash -n on every shell script, ast.parse on every .py, json.load on every
#   .json, and a two-way MANIFEST consistency check (install.sh/capture.sh
#   silently skip anything missing from MANIFEST — drift there is the real
#   failure mode).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

echo "== shell syntax (bash -n)"
while IFS= read -r f; do
  bash -n "$f" || { echo "FAIL: $f"; fail=1; }
done < <(git ls-files '*.sh'; echo home/claude/local-mode/claude-local)

echo "== shell syntax (zsh -n)"
if command -v zsh >/dev/null; then
  zsh -n shell/claude-wrapper.zsh || { echo "FAIL: shell/claude-wrapper.zsh"; fail=1; }
else
  echo "WARNING: zsh not found, skipping shell/claude-wrapper.zsh syntax check." >&2
fi

echo "== python syntax (ast.parse)"
while IFS= read -r f; do
  python3 - "$f" <<'PY' || fail=1
import ast, sys
p = sys.argv[1]
try:
    ast.parse(open(p, encoding="utf-8").read(), p)
except SyntaxError as e:
    print(f"FAIL: {p}: {e}"); sys.exit(1)
PY
done < <(git ls-files '*.py')

echo "== json validity"
while IFS= read -r f; do
  python3 -m json.tool "$f" >/dev/null || { echo "FAIL: $f"; fail=1; }
done < <(git ls-files '*.json')

echo "== MANIFEST consistency (two-way)"
manifest_entries() {
  sed 's/#.*//' MANIFEST | awk 'NF {gsub(/^[ \t]+|[ \t]+$/,""); print}'
}
while IFS= read -r rel; do
  [[ -f "home/$rel" ]] || { echo "FAIL: MANIFEST entry missing on disk: $rel"; fail=1; }
done < <(manifest_entries)
while IFS= read -r f; do
  rel="${f#home/}"
  manifest_entries | grep -qxF "$rel" \
    || { echo "FAIL: file not listed in MANIFEST: $f"; fail=1; }
done < <(git ls-files 'home/*')

echo "== roles.conf ↔ agent frontmatter"
CONF="home/claude/local-mode/roles.conf"
# shellcheck source=home/claude/local-mode/roles-lib.sh
source "home/claude/local-mode/roles-lib.sh"

# echo the model roles.conf assigns to <role> (dotted roles like
# claude.explorer / tier.code are escaped for the awk regex).
model_for_role() { roles_conf_get "$CONF" "$1"; }

# echo the `model:` value from an agent frontmatter file
agent_model() { grep -m1 '^model:' "$1" | sed -E 's/^model:[[:space:]]*//'; }

check_agent_model() { # <file> <role>
  local f="$1" role="$2" want got
  [[ -f "$f" ]] || { echo "FAIL: $f missing"; fail=1; return; }
  want="$(model_for_role "$role")"
  [[ -n "$want" ]] || { echo "FAIL: roles.conf has no value for role '$role'"; fail=1; return; }
  got="$(agent_model "$f")"
  [[ "$got" == "$want" ]] \
    || { echo "FAIL: $f has model: $got (roles.conf $role = $want)"; fail=1; }
}

# Role <-> agent-file mapping — MUST mirror sync-local.sh's update_agent calls.
check_agent_model home/claude-local/agents/explorer.md         explore
check_agent_model home/claude-local/agents/implementer.md      code
check_agent_model home/claude-local/agents/reviewer.md         orchestrator
check_agent_model home/claude-local/agents/reverse-engineer.md reverse

check_agent_model home/claude/agents/explorer.md         claude.explorer
check_agent_model home/claude/agents/implementer.md      claude.implementer
check_agent_model home/claude/agents/reviewer.md         claude.reviewer
check_agent_model home/claude/agents/reverse-engineer.md claude.reverse-engineer
check_agent_model home/claude/agents/browser-headless.md claude.browser-headless
check_agent_model home/claude/agents/browser-headed.md   claude.browser-headed

echo "== plan preset table has one prose-facing source (sync-local.sh --plans)"
# install.sh/README.md/commands/model-preset.md must point at
# `sync-local.sh --plans` instead of re-hardcoding the per-role model table —
# guard against the stale hardcoded phrasing creeping back in.
for f in install.sh README.md home/claude/commands/model-preset.md; do
  if grep -qE 'opus implementation, fable|opus for review/reverse|haiku recon, sonnet' "$f"; then
    echo "FAIL: $f still hardcodes the plan preset table — use sync-local.sh --plans instead"
    fail=1
  fi
done

echo "== commit-guard behavior (tests/test-commit-guard.sh)"
bash tests/test-commit-guard.sh || { echo "FAIL: tests/test-commit-guard.sh"; fail=1; }

echo "== ollama-delegate path confinement (tests/test-server-paths.py)"
python3 tests/test-server-paths.py || { echo "FAIL: tests/test-server-paths.py"; fail=1; }

echo "== statusline preset/effort display (tests/test-statusline.py)"
python3 tests/test-statusline.py || { echo "FAIL: tests/test-statusline.py"; fail=1; }

echo "== subagent progress files + statusline segment (tests/test-agent-progress.py)"
python3 tests/test-agent-progress.py || { echo "FAIL: tests/test-agent-progress.py"; fail=1; }

echo "== dispatch directive hybrid/local (tests/test-dispatch-directive.py)"
python3 tests/test-dispatch-directive.py || { echo "FAIL: tests/test-dispatch-directive.py"; fail=1; }

echo "== launcher keep-alive check (tests/test-keep-alive.sh)"
bash tests/test-keep-alive.sh || { echo "FAIL: tests/test-keep-alive.sh"; fail=1; }

echo "== install.sh / capture.sh sandbox behavior (tests/test-install-capture.sh)"
bash tests/test-install-capture.sh || { echo "FAIL: tests/test-install-capture.sh"; fail=1; }

echo "== powershell launcher (tests/test-claude-local-ps.ps1)"
# CI (ubuntu) ships pwsh; locally, point PWSH at a portable binary if needed.
PWSH_BIN="${PWSH:-pwsh}"
if command -v "$PWSH_BIN" >/dev/null; then
  "$PWSH_BIN" -NoProfile -File tests/test-claude-local-ps.ps1 \
    || { echo "FAIL: tests/test-claude-local-ps.ps1"; fail=1; }
else
  echo "WARNING: pwsh not found, skipping PowerShell launcher tests." >&2
fi

[[ "$fail" == 0 ]] && echo "OK — all checks passed."
exit "$fail"
