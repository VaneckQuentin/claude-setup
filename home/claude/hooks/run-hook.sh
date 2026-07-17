#!/bin/sh
# run-hook.sh — launch a Python hook with the first WORKING interpreter.
#
# `command -v python3` is not enough on Windows: the Microsoft Store app
# execution aliases put fake python3.exe/python.exe stubs on PATH that exist
# but only print "Python was not found…" and fail. So probe each candidate
# with a no-op run and exec the first one that genuinely works.
# exec preserves stdin (hook JSON) and the exit code (2 = blocking feedback).
for c in python3 python py; do
  if "$c" -c "" >/dev/null 2>&1; then
    exec "$c" "$@"
  fi
done
echo "run-hook.sh: no working python found (tried python3, python, py)" >&2
exit 1
