#!/usr/bin/env python3
"""Behavioral tests for statusline.py's plan-preset detection.

plan_preset() reverse-maps the claude.* role assignments in roles.conf to the
preset name that sync-local.sh --plan would have written (eco/balanced/best),
"custom" for any hand-edited combination, None when nothing is parseable.

The last test is a PARITY check: it runs the real sync-local.sh --plan in a
sandboxed HOME and asserts plan_preset() recognizes the result — so the two
copies of the preset table (bash and python) cannot drift silently.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

spec = importlib.util.spec_from_file_location(
    "statusline", os.path.join(REPO, "home", "claude", "hooks", "statusline.py"))
statusline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(statusline)

failures = []


def check(name, got, want):
    if got == want:
        print(f"PASS: {name}")
    else:
        print(f"FAIL: {name} (got {got!r}, want {want!r})")
        failures.append(name)


def conf_with(assignments):
    """Write a roles.conf holding the given claude.* dict; returns its path."""
    fd, path = tempfile.mkstemp(suffix=".conf")
    with os.fdopen(fd, "w") as fh:
        fh.write("# comment line\norchestrator = local-model:tag\n")
        for role, model in assignments.items():
            fh.write(f"claude.{role} = {model}  # inline comment\n")
    return path


PRESETS = {
    "eco": dict(explorer="haiku", implementer="sonnet", reviewer="sonnet",
                **{"reverse-engineer": "sonnet", "browser-headless": "sonnet",
                   "browser-headed": "sonnet"}),
    "balanced": dict(explorer="haiku", implementer="sonnet", reviewer="opus",
                     **{"reverse-engineer": "opus", "browser-headless": "sonnet",
                        "browser-headed": "sonnet"}),
    "best": dict(explorer="sonnet", implementer="opus", reviewer="fable",
                 **{"reverse-engineer": "fable", "browser-headless": "sonnet",
                    "browser-headed": "sonnet"}),
}

for name, roles in PRESETS.items():
    check(f"preset '{name}' recognized", statusline.plan_preset(conf_with(roles)), name)

hand_edited = dict(PRESETS["best"], reviewer="opus")
check("hand-edited combination -> 'custom'",
      statusline.plan_preset(conf_with(hand_edited)), "custom")

check("missing file -> None",
      statusline.plan_preset("/nonexistent/roles.conf"), None)

no_claude_fd, no_claude = tempfile.mkstemp(suffix=".conf")
with os.fdopen(no_claude_fd, "w") as fh:
    fh.write("orchestrator = some-model\ntier.code = other-model\n")
check("conf without claude.* lines -> None", statusline.plan_preset(no_claude), None)

# --- parity with sync-local.sh --plan -------------------------------------
# Run the real script in a throwaway HOME so its hardcoded ~/.claude paths
# resolve inside the sandbox, then assert plan_preset() names each result.
for preset in ("eco", "balanced", "best"):
    home = tempfile.mkdtemp(prefix="statusline-parity.")
    local_mode = os.path.join(home, ".claude", "local-mode")
    os.makedirs(local_mode)
    os.makedirs(os.path.join(home, ".claude", "agents"))
    os.makedirs(os.path.join(home, ".claude-local", "agents"))
    shutil.copy(os.path.join(REPO, "home", "claude", "local-mode", "roles-lib.sh"),
                local_mode)
    conf = os.path.join(local_mode, "roles.conf")
    with open(conf, "w") as fh:
        fh.write("orchestrator = local-model\ncheap = local-model\n"
                 "tier.code = local-model\ntier.cheap = local-model\n")
        for role in PRESETS["eco"]:
            fh.write(f"claude.{role} = placeholder\n")
    r = subprocess.run(
        ["bash", os.path.join(REPO, "home", "claude", "local-mode", "sync-local.sh"),
         "--plan", preset],
        env={**os.environ, "HOME": home}, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"FAIL: sync-local.sh --plan {preset} exited {r.returncode}:\n{r.stderr}")
        failures.append(f"parity {preset} (script failed)")
    else:
        check(f"parity: sync-local.sh --plan {preset} -> plan_preset() = '{preset}'",
              statusline.plan_preset(conf), preset)
    shutil.rmtree(home, ignore_errors=True)

# --- end-to-end: full payload through the script --------------------------
# The rendered line must carry the model with its effort level; the preset
# field depends on the machine's live ~/.claude/local-mode/roles.conf, so it
# is not asserted here (covered by the unit cases above).
payload = {
    "model": {"id": "claude-fable-5", "display_name": "Fable 5"},
    "effort": {"level": "high"},
    "workspace": {"current_dir": tempfile.gettempdir()},
    "rate_limits": {"five_hour": {"used_percentage": 12},
                    "seven_day": {"used_percentage": 34}},
    "context_window": {"used_percentage": 45},
}
r = subprocess.run(
    [sys.executable, os.path.join(REPO, "home", "claude", "hooks", "statusline.py")],
    input=json.dumps(payload), capture_output=True, text=True)
line = r.stdout.strip()
check("e2e: model shown with effort", "Fable 5 (high)" in line, True)
check("e2e: plan usage shown", "5h 12%" in line and "7d 34%" in line, True)
check("e2e: context %% shown", "ctx 45%" in line, True)

# The 5h label becomes a countdown to the window reset when resets_at (epoch
# seconds) is known and still ahead — knowing WHEN the quota returns is what
# the field is for; without it the static "5h" label stays.
def render_limits(five_hour):
    r = subprocess.run(
        [sys.executable, os.path.join(REPO, "home", "claude", "hooks", "statusline.py")],
        input=json.dumps(dict(payload, rate_limits={
            "five_hour": five_hour, "seven_day": {"used_percentage": 34}})),
        capture_output=True, text=True)
    return r.stdout.strip()


countdown_line = render_limits({"used_percentage": 12,
                                "resets_at": int(time.time()) + 8100})
check("e2e: 5h reset countdown replaces the '5h' label",
      "2:1" in countdown_line and "12%" in countdown_line and "5h " not in countdown_line,
      True)
check("e2e: countdown leaves the 7d field alone", "7d 34%" in countdown_line, True)
check("e2e: elapsed resets_at falls back to the '5h' label",
      "5h 12%" in render_limits({"used_percentage": 12,
                                 "resets_at": int(time.time()) - 60}), True)
check("e2e: no resets_at keeps the '5h' label",
      "5h 12%" in render_limits({"used_percentage": 12}), True)
check("e2e: millisecond-looking resets_at falls back to the '5h' label",
      "5h 12%" in render_limits({"used_percentage": 12,
                                 "resets_at": int(time.time() * 1000) + 8100}), True)

no_effort = dict(payload)
del no_effort["effort"]
r = subprocess.run(
    [sys.executable, os.path.join(REPO, "home", "claude", "hooks", "statusline.py")],
    input=json.dumps(no_effort), capture_output=True, text=True)
check("e2e: no effort field -> bare model name",
      r.stdout.strip().startswith("Fable 5 |"), True)

# --- preset field: hybrid vs local session --------------------------------
# The preset maps HYBRID subagent models; in a full-local session
# (CLAUDE_CONFIG_DIR=~/.claude-local) it is meaningless and must be hidden.
# A sandboxed HOME makes the roles.conf deterministic for both cases.
home = tempfile.mkdtemp(prefix="statusline-preset.")
local_mode = os.path.join(home, ".claude", "local-mode")
os.makedirs(local_mode)
with open(os.path.join(local_mode, "roles.conf"), "w") as fh:
    for role, model in PRESETS["eco"].items():
        fh.write(f"claude.{role} = {model}\n")


def render(extra_env):
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
    env["HOME"] = home
    env.update(extra_env)
    r = subprocess.run(
        [sys.executable, os.path.join(REPO, "home", "claude", "hooks", "statusline.py")],
        input=json.dumps(payload), capture_output=True, text=True, env=env)
    return r.stdout.strip()


check("e2e: hybrid session shows preset field",
      "preset:eco" in render({}), True)
check("e2e: local session hides preset field",
      "preset:" in render({"CLAUDE_CONFIG_DIR": os.path.join(home, ".claude-local")}),
      False)
shutil.rmtree(home, ignore_errors=True)

print()
if failures:
    print(f"statusline tests FAILED ({len(failures)}).")
    sys.exit(1)
print("OK — all statusline tests passed.")
