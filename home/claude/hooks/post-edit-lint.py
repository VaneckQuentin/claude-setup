#!/usr/bin/env python3
"""
PostToolUse hook — fast, token-free syntax check after Edit/Write.

Deterministic local checkers catch syntax errors BEFORE the model spends
output tokens discovering them. Exit code 2 feeds stderr straight back to
Claude, which fixes the error immediately.

Fail-open by design: unknown extensions, missing tools, timeouts and crashes
are all silently ignored — this hook must never block a legitimate edit.
Rust is intentionally skipped (cargo check is too slow for a hook; the
rust-analyzer LSP plugin already surfaces diagnostics).
"""
import ast
import json
import os
import shutil
import subprocess
import sys

CHECK_TIMEOUT = 10  # seconds per checker — hooks must stay snappy


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=CHECK_TIMEOUT)


def check(path):
    """Return an error message string, or None if OK / not checkable."""
    ext = os.path.splitext(path)[1].lower()

    if ext == ".php" and shutil.which("php"):
        r = run(["php", "-l", path])
        if r.returncode != 0:
            return (r.stderr or r.stdout).strip()

    elif ext == ".py":
        # ast.parse instead of py_compile: no __pycache__ artifacts.
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                ast.parse(f.read(), filename=path)
        except SyntaxError as e:
            return f"Python syntax error: {e}"

    elif ext in (".sh", ".bash") and shutil.which("bash"):
        r = run(["bash", "-n", path])
        if r.returncode != 0:
            return (r.stderr or r.stdout).strip()

    elif ext == ".zsh" and shutil.which("zsh"):
        r = run(["zsh", "-n", path])
        if r.returncode != 0:
            return (r.stderr or r.stdout).strip()

    elif ext == ".json":
        try:
            with open(path, encoding="utf-8") as f:
                json.load(f)
        except Exception as e:
            return f"Invalid JSON: {e}"

    elif ext in (".js", ".mjs", ".cjs") and shutil.which("node"):
        r = run(["node", "--check", path])
        if r.returncode != 0:
            return (r.stderr or r.stdout).strip()

    return None


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    path = (data.get("tool_input") or {}).get("file_path") or ""
    if not path or not os.path.isfile(path):
        return 0
    try:
        err = check(path)
    except Exception:
        return 0  # fail-open
    if err:
        print(f"Syntax check failed for {path}:\n{err[:2000]}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
