#!/usr/bin/env python3
"""keep-awake.py — prevent SYSTEM sleep while a Claude Code turn is running.

The display may still sleep, and user-initiated sleep (lid close, Apple menu,
Start menu) is never blocked — only *idle* system sleep is held off, so long
agentic turns survive an unattended machine.

Modes (argv[1]):
  start  UserPromptSubmit hook. Spawns a detached "holder" process and records
         its pid in a per-session file under the temp dir.
  stop   Stop / SessionEnd hook. Deletes the pid file; the holder notices
         within one poll interval and releases the assertion.
  hold   Internal: the holder itself (argv: hold <pidfile> <ttl_seconds>).
         macOS: runs `caffeinate -i -t ttl` as a child.
         Windows: SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED).
         Exits when the pid file disappears, no longer names it, or the TTL
         expires (safety cap if Claude dies without firing the stop hook).

Stopping is done by DELETING the pid file, never by kill(): a recycled pid can
name an unrelated process, a missing file cannot. Everything fails open — a
broken hook must never block the session. Other platforms: silent no-op.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

try:
    TTL_SECONDS = int(float(os.environ.get("CLAUDE_KEEP_AWAKE_MAX_HOURS", "8")) * 3600)
except ValueError:
    TTL_SECONDS = 8 * 3600
POLL_SECONDS = 10

ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001


def pidfile_for_session() -> str:
    try:
        payload = json.load(sys.stdin)
        session = str(payload.get("session_id", "default"))
    except Exception:
        session = "default"
    safe = "".join(c for c in session if c.isalnum() or c in "._-") or "default"
    return os.path.join(tempfile.gettempdir(), f"claude-keepawake-{safe}.pid")


def start() -> None:
    if sys.platform not in ("darwin", "win32"):
        return
    pidfile = pidfile_for_session()
    script = os.path.abspath(__file__)
    kwargs = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if sys.platform == "win32":
        DETACHED_PROCESS = 0x00000008
        CREATE_NEW_PROCESS_GROUP = 0x00000200
        kwargs["creationflags"] = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    else:
        kwargs["start_new_session"] = True
    holder = subprocess.Popen(
        [sys.executable, script, "hold", pidfile, str(TTL_SECONDS)], **kwargs
    )
    # Overwriting an existing pid file retires the previous holder (it sees a
    # pid that is not its own) — one holder per session, TTL reset each prompt.
    with open(pidfile, "w") as f:
        f.write(str(holder.pid))


def stop() -> None:
    try:
        os.remove(pidfile_for_session())
    except OSError:
        pass


def pidfile_names_me(pidfile: str) -> bool:
    try:
        with open(pidfile) as f:
            return f.read().strip() == str(os.getpid())
    except OSError:
        return False


def hold(pidfile: str, ttl: int) -> None:
    # The start-mode parent writes the pid file just after spawning us — give
    # it a moment before treating "not mine" as an exit signal.
    for _ in range(20):
        if pidfile_names_me(pidfile):
            break
        time.sleep(0.25)
    else:
        return

    caffeinate = None
    if sys.platform == "darwin":
        caffeinate = subprocess.Popen(
            ["caffeinate", "-i", "-t", str(ttl)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    elif sys.platform == "win32":
        import ctypes

        ctypes.windll.kernel32.SetThreadExecutionState(
            ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        )

    try:
        deadline = time.monotonic() + ttl
        while time.monotonic() < deadline and pidfile_names_me(pidfile):
            if sys.platform == "win32":
                import ctypes

                ctypes.windll.kernel32.SetThreadExecutionState(
                    ES_CONTINUOUS | ES_SYSTEM_REQUIRED
                )
            time.sleep(POLL_SECONDS)
    finally:
        if caffeinate is not None:
            caffeinate.terminate()
        elif sys.platform == "win32":
            import ctypes

            ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS)
        if pidfile_names_me(pidfile):  # TTL expiry: clean up our own file
            try:
                os.remove(pidfile)
            except OSError:
                pass


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "start":
        start()
    elif mode == "stop":
        stop()
    elif mode == "hold" and len(sys.argv) >= 4:
        hold(sys.argv[2], int(sys.argv[3]))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # fail open: never disturb the session
    sys.exit(0)
