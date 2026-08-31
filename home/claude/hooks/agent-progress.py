#!/usr/bin/env python3
"""agent-progress.py — record subagent task progress for the statusline.

Hooks fire for subagent tool calls too, and their stdin JSON carries
`agent_id` + `agent_type` (absent for the main session; `session_id` is shared
by parent and children). That is enough to track what each running subagent is
doing without a single token: this hook maintains one small JSON file per
agent, and statusline.py renders them as progress bars.

Layout: <root>/<session_id>/<agent_id>.json, root being
CLAUDE_AGENT_PROGRESS_DIR (tests) or ~/.claude/agent-progress.

Events:
  SubagentStart  create the file (state running, 0/0).
  PostToolUse    TodoWrite -> done/total from the todo list;
                 TaskCreate -> total += 1;
                 TaskUpdate -> undocumented schema, so read it defensively.
  SubagentStop   state done.
  SessionEnd     drop this session's dir, prune ones left behind by crashes.

Writes are atomic (tmp + os.replace) because the statusline reads these files
every couple of seconds and must never see a half-written one. Fail-soft: any
error is swallowed, nothing is ever printed, exit code is always 0.
"""
import json
import os
import shutil
import sys
import time

BAR_TOTAL_CAP = 999  # guard against a runaway total from a malformed payload
PRUNE_AFTER_SECONDS = 24 * 3600


def progress_root():
    """Root dir holding the per-session progress files.

    The env override exists for hermetic tests; keep it in sync with the same
    lookup in hooks/statusline.py, which reads what this hook writes.
    """
    return (os.environ.get("CLAUDE_AGENT_PROGRESS_DIR")
            or os.path.expanduser("~/.claude/agent-progress"))


def is_safe_id(value):
    """Ids land in a filesystem path — refuse anything that could escape."""
    return bool(value) and "/" not in value and "\\" not in value and value not in (".", "..")


def read_agent(path, event):
    """Current state for this agent, or a fresh one (missing/corrupt file)."""
    try:
        with open(path, encoding="utf-8") as fh:
            agent = json.load(fh)
        if isinstance(agent, dict):
            return agent
    except Exception:
        pass
    return {"agent_id": event.get("agent_id"), "agent_type": event.get("agent_type"),
            "state": "running", "started_at": time.time(), "done": 0, "total": 0}


def write_agent(path, agent):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(agent, fh)
    os.replace(tmp, path)


def count(agent, key):
    value = agent.get(key)
    return value if isinstance(value, int) and value >= 0 else 0


def apply_tool(agent, tool_name, tool_input):
    """Fold one tool call into the agent's done/total counters."""
    if tool_name == "TodoWrite":
        todos = tool_input.get("todos")
        if isinstance(todos, list):
            agent["total"] = len(todos)
            agent["done"] = sum(1 for t in todos
                                if isinstance(t, dict) and t.get("status") == "completed")
    elif tool_name == "TaskCreate":
        agent["total"] = min(count(agent, "total") + 1, BAR_TOTAL_CAP)
    elif tool_name == "TaskUpdate":
        # Schema is not publicly documented: look for whatever status-ish
        # string it carries, and ignore anything we don't recognize.
        status = tool_input.get("status") or tool_input.get("state")
        status = status.lower() if isinstance(status, str) else ""
        if status in ("completed", "done"):
            agent["done"] = count(agent, "done") + 1
        elif status == "deleted" or tool_input.get("delete"):
            agent["total"] = max(0, count(agent, "total") - 1)
    # A shrinking total must drag done down with it — the statusline renders
    # done/total as a bar and cannot show 3/1.
    agent["done"] = min(count(agent, "done"), count(agent, "total"))


def prune_old_sessions(root):
    """Remove session dirs left behind by a crash (no SessionEnd ever fired)."""
    cutoff = time.time() - PRUNE_AFTER_SECONDS
    for name in os.listdir(root):
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        try:
            if os.path.getmtime(path) < cutoff:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def handle_event(event):
    session_id = str(event.get("session_id") or "")
    root = progress_root()
    if not is_safe_id(session_id):
        return
    session_dir = os.path.join(root, session_id)
    hook_event = event.get("hook_event_name")

    if hook_event == "SessionEnd":
        shutil.rmtree(session_dir, ignore_errors=True)
        try:
            prune_old_sessions(root)
        except OSError:
            pass
        return

    agent_id = str(event.get("agent_id") or "")
    if not is_safe_id(agent_id):
        return  # main-session tool call: nothing to track
    path = os.path.join(session_dir, f"{agent_id}.json")

    if hook_event == "SubagentStart":
        write_agent(path, {"agent_id": agent_id, "agent_type": event.get("agent_type"),
                           "state": "running", "started_at": time.time(),
                           "done": 0, "total": 0})
        return

    agent = read_agent(path, event)
    if hook_event == "PostToolUse":
        tool_input = event.get("tool_input")
        if not isinstance(tool_input, dict):
            return
        apply_tool(agent, event.get("tool_name"), tool_input)
    elif hook_event == "SubagentStop":
        agent["state"] = "done"
        agent["ended_at"] = time.time()
        if count(agent, "total") > 0:
            agent["done"] = agent["total"]
    else:
        return
    write_agent(path, agent)


def main():
    handle_event(json.load(sys.stdin))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # fail-soft: progress display is never worth disturbing a session
    sys.exit(0)
