#!/usr/bin/env python3
"""
statusLine command — one dense line: model | branch (or dir) | plan usage
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
    parts.append(name)

    cwd = ((data.get("workspace") or {}).get("current_dir")
           or data.get("cwd") or os.getcwd())
    branch = git_branch(cwd)
    parts.append(branch if branch else os.path.basename(cwd))

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
