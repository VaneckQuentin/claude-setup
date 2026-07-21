#!/usr/bin/env python3
"""
statusLine command — one dense line: model (+ reasoning effort) | branch (or
dir) | subagent plan preset (agents:eco/balanced/best/custom) | plan usage
(5h/7d %, falling back to $cost under API billing) | context %.

Token discipline is this setup's core theme; the statusline makes it
observable (when to compact, when to delegate) instead of guessed.

Field names in the stdin JSON vary across Claude Code versions, so every
lookup is defensive and missing pieces are simply omitted. Fail-soft: any
crash prints a minimal line rather than breaking the UI.
"""
import json
import os
import subprocess
import sys


# Preset table — keep in sync with sync-local.sh --plan (parity enforced by
# tests/test-statusline.py, which runs the real script and compares).
PLAN_PRESETS = {
    "eco":      {"explorer": "haiku", "implementer": "sonnet",
                 "reviewer": "sonnet", "reverse-engineer": "sonnet",
                 "browser-headless": "sonnet", "browser-headed": "sonnet"},
    "balanced": {"explorer": "haiku", "implementer": "sonnet",
                 "reviewer": "opus", "reverse-engineer": "opus",
                 "browser-headless": "sonnet", "browser-headed": "sonnet"},
    "best":     {"explorer": "sonnet", "implementer": "opus",
                 "reviewer": "fable", "reverse-engineer": "fable",
                 "browser-headless": "sonnet", "browser-headed": "sonnet"},
}


def plan_preset(conf_path):
    """Name of the plan preset the claude.* lines in roles.conf match.

    The preset is never stored by name — sync-local.sh --plan just rewrites
    the claude.* assignments — so reverse-map them here. Returns "custom" for
    a hand-edited combination, None when the file or the lines are absent.
    """
    try:
        roles = {}
        with open(conf_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                if key.startswith("claude."):
                    roles[key[len("claude."):]] = value.strip()
        if not roles:
            return None
        for name, want in PLAN_PRESETS.items():
            if all(roles.get(role) == model for role, model in want.items()):
                return name
        return "custom"
    except Exception:
        return None


def git_branch(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "branch", "--show-current"],
                           capture_output=True, text=True, timeout=2)
        return r.stdout.strip()
    except Exception:
        return ""


def context_pct(data):
    """Best-effort context usage %, across schema variants."""
    for key in ("context_window", "contextWindow", "context"):
        cw = data.get(key)
        if not isinstance(cw, dict):
            continue
        for pk in ("used_percentage", "usedPercentage", "percent_used"):
            if isinstance(cw.get(pk), (int, float)):
                return round(cw[pk])
        used = cw.get("used_tokens") or cw.get("usedTokens") or cw.get("used")
        total = cw.get("max_tokens") or cw.get("maxTokens") or cw.get("total")
        if isinstance(used, (int, float)) and isinstance(total, (int, float)) and total:
            return round(100 * used / total)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    parts = []

    model = (data.get("model") or {})
    name = model.get("display_name") or model.get("id") or "?"
    # Live reasoning effort of the session (absent on models without the
    # effort parameter, or on older Claude Code versions).
    effort = (data.get("effort") or {}).get("level")
    parts.append(f"{name} ({effort})" if effort else name)

    cwd = ((data.get("workspace") or {}).get("current_dir")
           or data.get("cwd") or os.getcwd())
    branch = git_branch(cwd)
    parts.append(branch if branch else os.path.basename(cwd))

    preset = plan_preset(os.path.expanduser("~/.claude/local-mode/roles.conf"))
    if preset:
        parts.append(f"agents:{preset}")

    # Plan usage (subscription): 5-hour session window + weekly. Falls back to
    # the API-equivalent dollar figure when no rate limits exist (API billing).
    limits = data.get("rate_limits") or {}
    five_h = (limits.get("five_hour") or {}).get("used_percentage")
    seven_d = (limits.get("seven_day") or {}).get("used_percentage")
    if isinstance(five_h, (int, float)):
        usage = f"5h {round(five_h)}%"
        if isinstance(seven_d, (int, float)):
            usage += f" · 7d {round(seven_d)}%"
        parts.append(usage)
    else:
        cost = (data.get("cost") or {}).get("total_cost_usd")
        if isinstance(cost, (int, float)) and cost > 0:
            parts.append(f"${cost:.2f}")

    pct = context_pct(data)
    if pct is not None:
        flag = "!" if pct >= 80 else ""
        parts.append(f"ctx {pct}%{flag}")

    print(" | ".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("claude")
