#!/usr/bin/env bash
# tests/test-keep-alive.sh — behavioral tests for keep_alive_is_long() in the
# claude-local launcher. Test vectors live in keep-alive-cases.tsv, SHARED
# with the PowerShell port's tests so both implementations stay in lockstep.
# The function is extracted by name (stable signature, closing brace at
# column 0) so the launcher's own startup checks don't run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

eval "$(sed -n '/^keep_alive_is_long()/,/^}/p' home/claude/local-mode/claude-local)"
if ! declare -f keep_alive_is_long >/dev/null; then
  echo "FAIL: could not extract keep_alive_is_long() from the launcher."
  exit 1
fi

cases=0
while IFS=$'\t' read -r value expected; do
  [[ "$value" == \#* ]] && continue
  [[ -z "$expected" ]] && continue
  [[ "$value" == "(empty)" ]] && value=""
  cases=$((cases + 1))
  if keep_alive_is_long "$value"; then got=long; else got=short; fi
  if [[ "$got" == "$expected" ]]; then
    echo "PASS: '$value' -> $got"
  else
    echo "FAIL: '$value' -> $got (expected $expected)"
    fail=1
  fi
done < tests/keep-alive-cases.tsv

if [[ "$cases" -lt 10 ]]; then
  echo "FAIL: only $cases vectors parsed from keep-alive-cases.tsv — format broken?"
  fail=1
fi

if [[ "$fail" == 0 ]]; then
  echo "OK — all keep-alive tests passed ($cases cases)."
else
  echo "keep-alive tests FAILED."
fi
exit "$fail"
