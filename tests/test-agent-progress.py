#!/usr/bin/env python3
"""Behavioral tests for agent-progress.py and its statusline segment.

agent-progress.py turns hook events into per-agent JSON files under
CLAUDE_AGENT_PROGRESS_DIR/<session_id>/<agent_id>.json; statusline.py renders
them as a progress segment. Zero tokens are involved on either side, so the
only contract worth guarding is the file format and its lifecycle:
create on SubagentStart, count on TodoWrite/TaskCreate/TaskUpdate, finish on
SubagentStop, clean up on SessionEnd — and never raise, whatever the input.

Everything runs against a throwaway progress root so no live session state is
touched.
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
HOOKS = os.path.join(REPO, "home", "claude", "hooks")


def load(module_name, filename):
    spec = importlib.util.spec_from_file_location(
        module_name, os.path.join(HOOKS, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agent_progress = load("agent_progress", "agent-progress.py")

failures = []


def check(name, got, want):
    if got == want:
        print(f"PASS: {name}")
    else:
        print(f"FAIL: {name} (got {got!r}, want {want!r})")
        failures.append(name)


ROOT = tempfile.mkdtemp(prefix="agent-progress.")
os.environ["CLAUDE_AGENT_PROGRESS_DIR"] = ROOT

SESSION = "session-1"
AGENT = "agent-aaa"


def agent_file(session=SESSION, agent=AGENT):
    return os.path.join(ROOT, session, f"{agent}.json")


def read_agent(session=SESSION, agent=AGENT):
    with open(agent_file(session, agent), encoding="utf-8") as fh:
        return json.load(fh)


def event(name, **fields):
    return dict(session_id=SESSION, hook_event_name=name, **fields)


def start_event(agent=AGENT, agent_type="explorer"):
    return event("SubagentStart", agent_id=agent, agent_type=agent_type)


def tool_event(tool_name, tool_input, agent=AGENT):
    payload = event("PostToolUse", tool_name=tool_name, tool_input=tool_input)
    if agent is not None:
        payload["agent_id"] = agent
        payload["agent_type"] = "explorer"
    return payload


# --- 1. SubagentStart creates the agent file ------------------------------
agent_progress.handle_event(start_event())
state = read_agent()
check("SubagentStart: state running", state.get("state"), "running")
check("SubagentStart: agent_type recorded", state.get("agent_type"), "explorer")
check("SubagentStart: done 0 / total 0", (state.get("done"), state.get("total")), (0, 0))

# --- 2. TodoWrite counts todos --------------------------------------------
todos = [{"content": f"step {i}", "activeForm": f"doing {i}",
          "status": "completed" if i < 2 else "pending"} for i in range(5)]
agent_progress.handle_event(tool_event("TodoWrite", {"todos": todos}))
state = read_agent()
check("TodoWrite: done 2 / total 5", (state.get("done"), state.get("total")), (2, 5))

# --- 3. TaskCreate / TaskUpdate (undocumented schema) ---------------------
TASK_AGENT = "agent-bbb"
agent_progress.handle_event(start_event(TASK_AGENT))
for _ in range(3):
    agent_progress.handle_event(tool_event("TaskCreate", {"description": "x"}, TASK_AGENT))
agent_progress.handle_event(tool_event("TaskUpdate", {"status": "completed"}, TASK_AGENT))
state = read_agent(agent=TASK_AGENT)
check("TaskCreate x3 + TaskUpdate completed: done 1 / total 3",
      (state.get("done"), state.get("total")), (1, 3))

# A shrinking total must drag done down with it, or the bar overflows
# ("3/1" rendered as a full bar).
CLAMP_AGENT = "agent-clamp"
agent_progress.handle_event(start_event(CLAMP_AGENT))
all_done = [{"content": "step", "status": "completed"} for _ in range(3)]
agent_progress.handle_event(tool_event("TodoWrite", {"todos": all_done}, CLAMP_AGENT))
for _ in range(2):
    agent_progress.handle_event(tool_event("TaskUpdate", {"delete": True}, CLAMP_AGENT))
state = read_agent(agent=CLAMP_AGENT)
check("TaskUpdate delete: done never exceeds total",
      (state.get("done"), state.get("total")), (1, 1))

# --- 4. Main-session tool calls are ignored -------------------------------
MAIN_SESSION_ONLY = "session-main"
agent_progress.handle_event(dict(session_id=MAIN_SESSION_ONLY,
                                 hook_event_name="PostToolUse",
                                 tool_name="TodoWrite", tool_input={"todos": todos}))
check("PostToolUse without agent_id: nothing created",
      os.path.exists(os.path.join(ROOT, MAIN_SESSION_ONLY)), False)

# --- 5. SubagentStop finishes the agent -----------------------------------
agent_progress.handle_event(event("SubagentStop", agent_id=AGENT, agent_type="explorer"))
state = read_agent()
check("SubagentStop: state done", state.get("state"), "done")
check("SubagentStop: ended_at set", isinstance(state.get("ended_at"), (int, float)), True)
check("SubagentStop: done == total", state.get("done"), state.get("total"))

# --- 6. SessionEnd removes the session dir --------------------------------
agent_progress.handle_event(event("SessionEnd"))
check("SessionEnd: session dir removed", os.path.exists(os.path.join(ROOT, SESSION)), False)

# --- 7. A corrupt agent file is rewritten, not raised on ------------------
CORRUPT_SESSION = "session-corrupt"
os.makedirs(os.path.join(ROOT, CORRUPT_SESSION), exist_ok=True)
with open(agent_file(CORRUPT_SESSION), "w", encoding="utf-8") as fh:
    fh.write("{not json at all")
corrupt_todo = dict(tool_event("TodoWrite", {"todos": todos}), session_id=CORRUPT_SESSION)
try:
    agent_progress.handle_event(corrupt_todo)
    raised = None
except Exception as exc:  # noqa: BLE001 — the point of the test
    raised = exc
check("corrupt agent file: no exception", raised, None)
try:
    state = read_agent(CORRUPT_SESSION)
except Exception:
    state = None
check("corrupt agent file: rewritten valid",
      state and (state.get("done"), state.get("total")), (2, 5))

# --- 8. ids are path components, so unsafe ones are refused ---------------
for unsafe in ("..", "../x", "a/b", "a\\b", ""):
    check(f"is_safe_id({unsafe!r}) rejected", agent_progress.is_safe_id(unsafe), False)
check("is_safe_id: normal id accepted",
      agent_progress.is_safe_id("9f8b0c3a-1d2e-4f56-8a90-b1c2d3e4f567"), True)

# --- 9. sessions left behind by a crash are pruned ------------------------
PRUNE_ROOT = tempfile.mkdtemp(prefix="agent-progress-prune.")
old_session = os.path.join(PRUNE_ROOT, "session-old")
fresh_session = os.path.join(PRUNE_ROOT, "session-fresh")
os.makedirs(old_session)
os.makedirs(fresh_session)
stray = os.path.join(PRUNE_ROOT, "stray.json")
with open(stray, "w", encoding="utf-8") as fh:
    fh.write("{}")
long_ago = time.time() - 25 * 3600
os.utime(old_session, (long_ago, long_ago))
os.utime(stray, (long_ago, long_ago))
agent_progress.prune_old_sessions(PRUNE_ROOT)
check("prune: >24h session dir removed", os.path.exists(old_session), False)
check("prune: fresh session dir kept", os.path.exists(fresh_session), True)
check("prune: stray root-level file untouched", os.path.exists(stray), True)
shutil.rmtree(PRUNE_ROOT, ignore_errors=True)

# --- 10. statusline rendering ---------------------------------------------
RENDER_SESSION = "session-render"
os.makedirs(os.path.join(ROOT, RENDER_SESSION), exist_ok=True)
with open(agent_file(RENDER_SESSION), "w", encoding="utf-8") as fh:
    json.dump({"agent_id": AGENT, "agent_type": "implementer", "state": "running",
               "started_at": time.time(), "done": 3, "total": 5}, fh)


def render(session_id):
    payload = {
        "model": {"id": "claude-fable-5", "display_name": "Fable 5"},
        "workspace": {"current_dir": tempfile.gettempdir()},
        "session_id": session_id,
        "context_window": {"used_percentage": 45},
    }
    r = subprocess.run(
        [sys.executable, os.path.join(HOOKS, "statusline.py")],
        input=json.dumps(payload), capture_output=True, text=True,
        env={**os.environ, "CLAUDE_AGENT_PROGRESS_DIR": ROOT})
    return r.stdout.strip()


line = render(RENDER_SESSION)
check("statusline: agent type shown", "implementer" in line, True)
check("statusline: progress ratio shown", "3/5" in line, True)

# The statusline is a ONE-line contract: a long or control-char-carrying
# agent_type must not widen or break it.
HOSTILE_SESSION = "session-hostile"
hostile_type = "x" * 10 + "\n\x1b[31m" + "y" * 24
os.makedirs(os.path.join(ROOT, HOSTILE_SESSION), exist_ok=True)
with open(agent_file(HOSTILE_SESSION), "w", encoding="utf-8") as fh:
    json.dump({"agent_id": AGENT, "agent_type": hostile_type, "state": "running",
               "started_at": time.time(), "done": 1, "total": 2}, fh)
hostile_line = render(HOSTILE_SESSION)
check("statusline: hostile agent_type stays one line",
      "\n" in hostile_line or "\x1b" in hostile_line, False)
check("statusline: agent_type sanitized and truncated to 14 chars",
      "x" * 10 + "[31m" in hostile_line and hostile_type not in hostile_line, True)

empty_session = "session-empty"
os.makedirs(os.path.join(ROOT, empty_session), exist_ok=True)
check("statusline: empty progress dir renders like no progress at all",
      render(empty_session), render("session-absent"))

shutil.rmtree(ROOT, ignore_errors=True)

print()
if failures:
    print(f"agent-progress tests FAILED ({len(failures)}).")
    sys.exit(1)
print("OK — all agent-progress tests passed.")
