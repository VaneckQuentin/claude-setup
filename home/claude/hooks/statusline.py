#!/usr/bin/env python3
"""
statusLine command — one dense line: model (+ reasoning effort) | branch (or
dir) | subagent plan preset (preset:eco/balanced/best/custom) | plan usage
(5h window — labelled with the time left before it resets when known — and 7d
%, falling back to $cost under API billing) | context % | running subagents
with their task progress.

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
import time


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


def five_hour_label(window):
    """Time left before the 5h window resets ("2:17"), or the static "5h".

    resets_at is epoch seconds and disappears once the window has rolled over;
    anything else than a future number falls back to the plain label.
    """
    resets_at = window.get("resets_at")
    if isinstance(resets_at, (int, float)):
        remaining = resets_at - time.time()
        # > 7 days means resets_at is not epoch seconds (e.g. milliseconds).
        if 0 < remaining <= 7 * 24 * 3600:
            return f"{int(remaining // 3600)}:{int(remaining % 3600 // 60):02d}"
    return "5h"


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


BAR_SLOTS = 5
MAX_AGENTS_SHOWN = 3
LABEL_MAX_CHARS = 14
DONE_LINGER_SECONDS = 60
# Only meant to hide leftovers from a session that died without SessionEnd;
# a real agent can legitimately run for hours without touching its todos, and
# the 24h prune in agent-progress.py collects the rest.
RUNNING_STALE_SECONDS = 6 * 3600


def clean_label(value):
    """Agent type, bounded and control-char-free — the line must stay one line."""
    return "".join(c for c in str(value) if c >= " ")[:LABEL_MAX_CHARS] or "agent"


def agent_progress(session_id):
    """Running subagents and their task progress, e.g. "explorer [███░░] 3/5".

    Reads what hooks/agent-progress.py writes for this session (same root
    lookup). Returns "" when nothing is in flight, so the line stays exactly
    as it was before this segment existed. Cheap on purpose: the statusline
    re-runs every couple of seconds.
    """
    root = (os.environ.get("CLAUDE_AGENT_PROGRESS_DIR")
            or os.path.expanduser("~/.claude/agent-progress"))
    session_dir = os.path.join(root, str(session_id or ""))
    try:
        names = sorted(os.listdir(session_dir))
    except OSError:
        return ""

    now = time.time()
    entries = []
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(session_dir, name)
        try:
            mtime = os.path.getmtime(path)
            with open(path, encoding="utf-8") as fh:
                agent = json.load(fh)
            label = clean_label(agent.get("agent_type") or "agent")
            done, total = int(agent.get("done") or 0), int(agent.get("total") or 0)
        except Exception:
            continue
        if agent.get("state") == "done":
            ended = agent.get("ended_at")
            if now - (ended if isinstance(ended, (int, float)) else mtime) <= DONE_LINGER_SECONDS:
                entries.append(f"{label} ✓")
            continue
        if now - mtime > RUNNING_STALE_SECONDS:
            continue  # agent (or the whole session) died without a stop hook
        if total <= 0:
            entries.append(f"{label} …")
            continue
        filled = max(0, min(BAR_SLOTS, round(done / total * BAR_SLOTS)))
        entries.append(f"{label} [{'█' * filled}{'░' * (BAR_SLOTS - filled)}] {done}/{total}")

    shown = entries[:MAX_AGENTS_SHOWN]
    if len(entries) > MAX_AGENTS_SHOWN:
        shown.append(f"+{len(entries) - MAX_AGENTS_SHOWN}")
    return " · ".join(shown)


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

    # The preset names HYBRID subagent models — meaningless in a full-local
    # session (claude --local sets CLAUDE_CONFIG_DIR=~/.claude-local).
    conf_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").rstrip("/")
    if os.path.basename(conf_dir) != ".claude-local":
        preset = plan_preset(os.path.expanduser("~/.claude/local-mode/roles.conf"))
        if preset:
            parts.append(f"preset:{preset}")

    # Plan usage (subscription): 5-hour session window + weekly. Falls back to
    # the API-equivalent dollar figure when no rate limits exist (API billing).
    limits = data.get("rate_limits") or {}
    five_hour = limits.get("five_hour") or {}
    five_h = five_hour.get("used_percentage")
    seven_d = (limits.get("seven_day") or {}).get("used_percentage")
    if isinstance(five_h, (int, float)):
        usage = f"{five_hour_label(five_hour)} {round(five_h)}%"
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

    agents = agent_progress(data.get("session_id"))
    if agents:
        parts.append(agents)

    print(" | ".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("claude")
