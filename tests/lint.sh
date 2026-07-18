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

# echo the model roles.conf assigns to <role> (dotted roles like
# claude.explorer / tier.code are escaped for the awk regex).
model_for_role() {
  local role_re
  role_re="$(printf '%s' "$1" | sed 's/\./\\./g')"
  awk -v re="^[[:space:]]*${role_re}[[:space:]]*=" '
    $0 ~ re {
      val=$0; sub(/^[^=]*=/, "", val); sub(/#.*/, "", val);
      gsub(/^[ \t]+|[ \t]+$/, "", val); print val; exit
    }' "$CONF"
}

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

[[ "$fail" == 0 ]] && echo "OK — all checks passed."
exit "$fail"
