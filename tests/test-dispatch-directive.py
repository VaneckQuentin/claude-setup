#!/usr/bin/env python3
"""Behavioral tests for dispatch-directive.py (UserPromptSubmit hook).

The hook must inject the HYBRID directive in normal sessions and the
LOCAL-mode directive when the session runs from ~/.claude-local
(CLAUDE_CONFIG_DIR), because the two modes have opposite dispatch economics
(hybrid: parallel fan-out saves tokens; local: it just stacks prefill).
Bulk-gating and the kill switch must behave identically in both modes.
"""
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(REPO, "home", "claude", "hooks", "dispatch-directive.py")

failures = []

BULK_PROMPT = "summarize all the controllers in this repo one by one"
LOCAL_ENV = {"CLAUDE_CONFIG_DIR": os.path.expanduser("~/.claude-local")}


def run_hook(prompt, extra_env=None):
    """Returns the injected additionalContext, or '' when nothing injected."""
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
    env["CLAUDE_AUTODISPATCH"] = "1"
    env.update(extra_env or {})
    r = subprocess.run([sys.executable, HOOK], input=json.dumps({"prompt": prompt}),
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        # A crash must never masquerade as intentional non-injection.
        print(f"FAIL: hook crashed (exit {r.returncode}): {r.stderr.strip()}")
        failures.append("hook crash")
        return ""
    if not r.stdout.strip():
        return ""
    return json.loads(r.stdout)["hookSpecificOutput"]["additionalContext"]


def check(name, condition):
    if condition:
        print(f"PASS: {name}")
    else:
        print(f"FAIL: {name}")
        failures.append(name)


hybrid = run_hook(BULK_PROMPT)
check("hybrid: bulk prompt injects the hybrid directive",
      "Dispatch protocol" in hybrid and "parallel" in hybrid)
check("hybrid: no LOCAL-mode content leaks in", "LOCAL mode" not in hybrid)

local = run_hook(BULK_PROMPT, LOCAL_ENV)
check("local: bulk prompt injects the LOCAL directive",
      "LOCAL mode" in local and "SEQUENTIALLY" in local)
check("local: inline-first editing is stated", "INLINE" in local)
check("local: hybrid parallel advice is absent",
      "Spawn independent subtasks in parallel" not in local)

check("hybrid config dir ~/.claude is NOT local mode",
      "LOCAL mode" not in run_hook(
          BULK_PROMPT, {"CLAUDE_CONFIG_DIR": os.path.expanduser("~/.claude")}))

check("non-bulk prompt -> no injection (both modes)",
      run_hook("fix the login bug in auth.php please") == ""
      and run_hook("fix the login bug in auth.php please", LOCAL_ENV) == "")
check("short prompt -> no injection", run_hook("list all") == "")
check("kill switch works in local mode too",
      run_hook(BULK_PROMPT, {**LOCAL_ENV, "CLAUDE_AUTODISPATCH": "0"}) == "")

print()
if failures:
    print(f"dispatch-directive tests FAILED ({len(failures)}).")
    sys.exit(1)
print("OK — all dispatch-directive tests passed.")
