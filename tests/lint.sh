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

[[ "$fail" == 0 ]] && echo "OK — all checks passed."
exit "$fail"
