#!/usr/bin/env python3
"""
PreToolUse(Bash) hook — block `git commit` when the staged changes contain
secrets or personal data. Exit 2 feeds the reason back to Claude (blocking);
anything else is fail-open so a broken guard never wedges normal work.

Personal identifiers (home path, git email) are derived AT RUNTIME so this
file itself stays shareable — never hardcode them here.

Also runnable by hand:  commit-guard.py --staged [repo-dir]
Kill switch (with explicit user approval only): CLAUDE_COMMIT_GUARD=0
"""
import json
import os
import re
import subprocess
import sys

SECRETS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(r"\b(gho|ghp|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"), "GitHub token"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), "Anthropic API key"),
    (re.compile(r"\bsk-[A-Za-z0-9]{32,}"), "API key (sk-…)"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{10,}\."), "JWT"),
    (re.compile(r"(?i)\b(api[_-]?key|secret|passwd|password|token)\b\s*[:=]\s*['\"][^'\"\s]{16,}['\"]"),
     "hardcoded credential"),
]

# Files that must never be committed, regardless of content.
FORBIDDEN_FILES = re.compile(
    r"(^|/)(\.env(\.[^/]+)?|id_(rsa|ed25519)[^/]*|[^/]+\.(pem|p12|pfx)"
    r"|\.?credentials(\.json)?|\.claude\.json|history\.jsonl|\.netrc)$"
)


def git(args, cwd):
    return subprocess.run(["git", "-C", cwd] + args,
                          capture_output=True, text=True, timeout=15).stdout


def personal_patterns(cwd):
    pats = []
    home = os.path.expanduser("~")
    if home and home not in ("/", ""):
        pats.append((re.compile(re.escape(home) + r"\b"), "home path (username)"))
    try:
        email = git(["config", "user.email"], cwd).strip()
        if email and "noreply" not in email:
            pats.append((re.compile(re.escape(email)), "personal git email"))
    except Exception:
        pass
    return pats


def added_lines(diff):
    return [l[1:] for l in diff.splitlines()
            if l.startswith("+") and not l.startswith("+++")]


def scan(cwd, include_unstaged):
    findings = []
    names = git(["diff", "--cached", "--name-only"], cwd)
    diff = git(["diff", "--cached", "-U0"], cwd)
    if include_unstaged:  # `git commit -a` also commits unstaged tracked changes
        names += git(["diff", "--name-only"], cwd)
        diff += git(["diff", "-U0"], cwd)

    for f in set(filter(None, names.splitlines())):
        if FORBIDDEN_FILES.search(f):
            findings.append(f"forbidden file staged: {f}")

    checks = SECRETS + personal_patterns(cwd)
    for line in added_lines(diff):
        for rx, label in checks:
            if rx.search(line):
                findings.append(f"{label}: {line.strip()[:120]}")
                break
    return findings


def main():
    if os.environ.get("CLAUDE_COMMIT_GUARD", "1") == "0":
        return 0

    if len(sys.argv) > 1 and sys.argv[1] == "--staged":  # manual mode
        cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
        include_unstaged = False
    else:  # hook mode
        try:
            data = json.load(sys.stdin)
        except Exception:
            return 0
        command = (data.get("tool_input") or {}).get("command") or ""
        if not re.search(r"\bgit\b[^|;&]*\bcommit\b", command):
            return 0
        cwd = data.get("cwd") or os.getcwd()
        include_unstaged = bool(re.search(r"\s-a(m|\b)", command))

    try:
        findings = scan(cwd, include_unstaged)
    except Exception:
        return 0  # fail-open

    if findings:
        uniq = sorted(set(findings))[:15]
        print("COMMIT BLOCKED — staged changes contain sensitive/personal data:\n- "
              + "\n- ".join(uniq)
              + "\nRemove or redact the data (unstage the file, scrub the value), "
                "then commit again. Do NOT bypass without explicit user approval.",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
