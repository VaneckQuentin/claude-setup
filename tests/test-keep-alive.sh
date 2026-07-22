#!/usr/bin/env bash
# tests/test-keep-alive.sh — behavioral tests for keep_alive_is_long() in the
# claude-local launcher. The function is extracted by name (stable signature,
# closing brace at column 0) so the launcher's own startup checks don't run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

eval "$(sed -n '/^keep_alive_is_long()/,/^}/p' home/claude/local-mode/claude-local)"
if ! declare -f keep_alive_is_long >/dev/null; then
  echo "FAIL: could not extract keep_alive_is_long() from the launcher."
  exit 1
fi

check() { # <value> <expected: long|short>
  local value="$1" expected="$2" got
  if keep_alive_is_long "$value"; then got=long; else got=short; fi
  if [[ "$got" == "$expected" ]]; then
    echo "PASS: '$value' -> $got"
  else
    echo "FAIL: '$value' -> $got (expected $expected)"
    fail=1
  fi
}

check "-1"    long    # Ollama: never unload
check "-1s"   long    # any negative duration = never unload
check "1h"    long
check "24h"   long
check "1h30m" long    # compound Go duration
check "30m"   long
check "1800"  long    # plain seconds
check "3600s" long
check "0h"    short   # zero = unload immediately — the case the warning is FOR
check "0m"    short
check "0"     short
check "29m"   short
check "1799"  short
check "5m"    short   # Ollama's default
check ""      short
check "abc"   short

if [[ "$fail" == 0 ]]; then
  echo "OK — all keep-alive tests passed."
else
  echo "keep-alive tests FAILED."
fi
exit "$fail"
