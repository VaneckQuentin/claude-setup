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
import shlex
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
    r"(^|/)(\.env(\.[^/]+)?|id_(rsa|ed25519|ecdsa|dsa)[^/]*|[^/]+\.(pem|p12|pfx|key)"
    r"|\.?credentials(\.json)?|\.claude\.json|history\.jsonl|\.netrc|\.pgpass)$"
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


# Top-level statement separators (`;`, `&&`, `||`, `&`, newline). Statements
# are executed in sequence, so a `cd` in one carries into the next — unlike
# `|`, which only separates pipeline STAGES of the same statement (see
# find_commit_invocations).
STATEMENT_SEPARATORS = {";", "&&", "||", "&", "\n"}

# git global options that consume a following argument (besides `-C`, which
# is handled separately since we need its values for cwd composition).
GIT_GLOBAL_OPTS_WITH_ARG = {
    "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix",
}

# `git commit` options that consume a following argument. Skipping these
# (rather than scanning their value) is what stops a commit message like
# `-m "-a"` from being mistaken for the `-a` flag.
COMMIT_LONG_OPTS_WITH_ARG = {
    "--message", "--file", "--reuse-message", "--reedit-message",
    "--fixup", "--squash", "--author", "--date", "--template", "--trailer",
}
COMMIT_SHORT_LETTERS_WITH_ARG = set("mFCct")


def tokenize(command):
    """shlex-tokenize `command` the way a shell would: quotes collapse (so
    `comm""it` and `c'o'mmit` both yield the token "commit"), and `;`, `&`,
    `&&`, `||`, `|` and newlines survive as their own tokens so callers can
    split on them. Raises on unparsable input (e.g. unbalanced quotes) —
    callers must fail open."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    return list(lexer)


def parse_git_invocation(tokens):
    """If `tokens` is a `git ...` invocation, return (subcommand, cd_dirs)
    where `subcommand` is the first non-option token (e.g. "commit", "add",
    "stage"; None if the invocation is only global options) and cd_dirs are
    the `-C <path>` values in the order given (git composes repeated -C
    relative to each other, then to cwd). Return None if `tokens` doesn't
    even start with `git`.

    Known limitation: `--git-dir=`/`--work-tree=`/a `GIT_DIR=` env prefix
    can also retarget which repo git operates on; we don't follow those, so
    a command relying on them gets scanned against the wrong (cwd) repo.
    Not a regression — the old regex didn't follow them either.

    Known limitation: a wrapper that hides the invocation behind a quoted
    sub-shell, e.g. `bash -c "git commit -m x"`, is invisible to us —
    tokenize() collapses the quoted string into a single opaque token, and
    we don't recursively parse it. Accepted gap, not an adversarial threat
    model."""
    if not tokens or tokens[0] != "git":
        return None
    cd_dirs = []
    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-C":
            if i + 1 < len(tokens):
                cd_dirs.append(tokens[i + 1])
            i += 2
            continue
        if tok in GIT_GLOBAL_OPTS_WITH_ARG:
            i += 2
            continue
        if tok.startswith("-"):
            i += 1  # other global flag with no argument (-p, --no-pager, …)
            continue
        return (tok, cd_dirs)  # first non-option token = subcommand
    return (None, cd_dirs)


def _short_cluster_has_a(letters):
    """Walk one short-option cluster's letters (e.g. "qam" from "-qam")
    left to right. `a` only counts if it's reached before any value-taking
    letter (m/F/C/c/t): once one of those is hit, the rest of the cluster —
    or, if it was the cluster's last letter, the NEXT token — is that
    letter's value, not more flags (so `-m"add auth"` doesn't read the `a`
    in "add auth" as `-a`, and `-mX -a` still sees the real trailing `-a`).
    Returns (has_a, consumes_next_token)."""
    for pos, c in enumerate(letters):
        if c == "a":
            return True, False
        if c in COMMIT_SHORT_LETTERS_WITH_ARG:
            return False, pos == len(letters) - 1
    return False, False


def commit_all_flag(tokens):
    """True if these tokens include `-a`/`--all`/`--include`, walking the
    token list so option arguments (`-m <msg>`, `-F <file>`, …) are skipped
    instead of scanned for a stray "a" character. Combined short clusters
    count (`-qam` -> True), and a value-taking letter mid-cluster stops the
    scan of that cluster (see _short_cluster_has_a)."""
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in ("--all", "--include"):
            return True
        if tok in COMMIT_LONG_OPTS_WITH_ARG:
            i += 2
            continue
        if tok.startswith("--"):
            i += 1
            continue
        if tok.startswith("-") and len(tok) > 1:
            has_a, consumes_next = _short_cluster_has_a(tok[1:])
            if has_a:
                return True
            i += 2 if consumes_next else 1
            continue
        i += 1
    return False


# A token is "the commit word" if it IS `commit` or starts with `commit`
# followed by a word boundary (so a quoted-together `commit -am x` from a
# pipe/xargs construction still counts) — but NOT merely containing
# "commit" anywhere, which would also fire on `--grep=commit` (git log) or
# a branch/file named `commitfix` (see looks_like_commit_pipeline).
COMMIT_WORD_RE = re.compile(r"^commit\b")


def looks_like_commit_pipeline(tokens):
    """Best-effort fallback for a `git commit` built up indirectly (e.g.
    `echo "commit -am x" | xargs git`), where no single pipeline stage is a
    literal `git ... commit` invocation. Requires an exact `git` token AND
    a `commit`-word token (see COMMIT_WORD_RE) — a false-positive scan of a
    clean tree is harmless, so we still err toward scanning rather than
    requiring the two to be adjacent."""
    return (any(t == "git" for t in tokens)
            and any(COMMIT_WORD_RE.match(t) for t in tokens))


def command_stages(statement):
    """Split one statement's tokens into pipeline stages on `|` (only `|`
    separates stages of the SAME statement; see find_commit_invocations)."""
    stages = [[]]
    for tok in statement:
        if tok == "|":
            stages.append([])
        else:
            stages[-1].append(tok)
    return [s for s in stages if s]


def staging_statement_flags(statements):
    """Scan every stage of every statement for a `git add`/`git stage`
    invocation. Returns (has_staging, has_forced_staging).

    has_staging is True if any such invocation exists anywhere in the
    command. The guard runs BEFORE the shell command executes, so a staging
    statement earlier in the same command line as a commit (e.g. `git add
    creds.txt && git commit -m x`) would otherwise slip a not-yet-staged
    secret past the scan. Deliberately not tied to matching cwd or ordering
    against the commit statement — a same-command `add` anywhere is treated
    as if it already ran, over-blocking beats missing a secret.

    has_forced_staging is True if one of those staging invocations also
    carries `-f`/`--force` (cheap token-membership check, not a full
    short-cluster parse like commit_all_flag's — good enough since a forced
    add hidden inside a combined cluster isn't a realistic pattern here).
    git silently skips gitignored paths on a plain `add`, so only a forced
    add needs the extra `git status --ignored` pass (see scan())."""
    has_staging = False
    has_forced = False
    for statement in statements:
        for stage in command_stages(statement):
            invocation = parse_git_invocation(stage)
            if invocation and invocation[0] in ("add", "stage"):
                has_staging = True
                if "-f" in stage or "--force" in stage:
                    has_forced = True
    return has_staging, has_forced


def find_commit_invocations(command, start_cwd):
    """Walk `command` statement by statement (split on ;/&&/||/&/newline),
    tracking `cd` so it carries into later statements the way a real shell
    would (honors ANY number of leading `cd`s, not just one). For each
    remaining statement, split into pipeline stages on `|` and look for a
    `git ... commit` invocation in each stage; fall back to the best-effort
    pipe/xargs heuristic if no stage matches directly. Yields one
    (cwd, include_unstaged, include_untracked, include_ignored) tuple per
    detected commit invocation — include_untracked/include_ignored are set
    for every commit in the command if the command ALSO contains a
    `git add`/`git stage` statement (see staging_statement_flags), since
    that staging would run before the commit even though the guard only
    sees the commit's own already-staged diff."""
    tokens = tokenize(command)

    statements = [[]]
    for tok in tokens:
        if tok in STATEMENT_SEPARATORS:
            statements.append([])
        else:
            statements[-1].append(tok)
    statements = [s for s in statements if s]

    same_command_staging, same_command_forced_staging = staging_statement_flags(statements)

    cwd = start_cwd
    invocations = []
    for statement in statements:
        if statement[0] == "cd" and len(statement) >= 2:
            cd_dir = os.path.expanduser(statement[1])
            cwd = cd_dir if os.path.isabs(cd_dir) else os.path.normpath(os.path.join(cwd, cd_dir))
            continue

        stages = command_stages(statement)

        matched = False
        for stage in stages:
            invocation = parse_git_invocation(stage)
            if invocation and invocation[0] == "commit":
                _, cd_dirs = invocation
                stage_cwd = cwd
                for d in cd_dirs:
                    d = os.path.expanduser(d)
                    stage_cwd = d if os.path.isabs(d) else os.path.normpath(os.path.join(stage_cwd, d))
                invocations.append((stage_cwd,
                                     commit_all_flag(stage) or same_command_staging,
                                     same_command_staging,
                                     same_command_forced_staging))
                matched = True
        if not matched and looks_like_commit_pipeline(statement):
            invocations.append((cwd,
                                 commit_all_flag(statement) or same_command_staging,
                                 same_command_staging,
                                 same_command_forced_staging))

    return invocations


def added_lines(diff):
    return [l[1:] for l in diff.splitlines()
            if l.startswith("+") and not l.startswith("+++")]


# Cap per-file reads when scanning files straight off disk (see
# scan_disk_files): there's no `git diff` to lean on for them, so a huge
# untracked/ignored blob could otherwise stall the scan.
DISK_FILE_READ_CAP = 1_000_000  # bytes


def untracked_file_paths(cwd):
    """Relative (to the repo root) paths of untracked files (`git status`
    `??` entries). Uses `-z` (NUL-separated, unquoted paths) so filenames
    with spaces or special characters parse safely."""
    status = git(["status", "--porcelain", "-z", "--untracked-files=all"], cwd)
    return [entry[3:] for entry in status.split("\0") if entry.startswith("?? ")]


def ignored_file_paths(cwd):
    """Relative (to the repo root) paths of gitignored files (`git status`
    `!!` entries, via `--ignored=matching`). Only needed when a same-command
    `git add -f`/`--force` would stage them despite .gitignore — a plain
    `add` silently no-ops on ignored paths (see staging_statement_flags)."""
    status = git(["status", "--porcelain", "-z", "--ignored=matching",
                  "--untracked-files=all"], cwd)
    return [entry[3:] for entry in status.split("\0") if entry.startswith("!! ")]


def scan_disk_files(cwd, rel_paths, checks):
    """Read files straight off disk and check them the same way scan()
    checks diff content — used for untracked and (when forced) gitignored
    files that a same-command `git add` would stage before any guard-
    visible commit diff exists. `git status` paths are always relative to
    the REPO ROOT regardless of the invocation cwd, so resolve the real
    toplevel once rather than joining onto cwd (a cwd inside a subdirectory
    would otherwise silently fail every open() and scan nothing). Mirrors
    the tracked-file checks: forbidden filenames block outright, content
    findings name the file (so a block from an untracked/ignored file can
    actually be traced), binaries are skipped (null-byte sniff — same
    effect as git diff's "Binary files … differ"), and reads are capped at
    DISK_FILE_READ_CAP."""
    toplevel = git(["rev-parse", "--show-toplevel"], cwd).strip() or cwd
    findings = []
    for rel_path in rel_paths:
        if FORBIDDEN_FILES.search(rel_path):
            findings.append(f"forbidden file staged: {rel_path}")
        try:
            with open(os.path.join(toplevel, rel_path), "rb") as fh:
                data = fh.read(DISK_FILE_READ_CAP)
        except OSError:
            continue
        if b"\0" in data:
            continue  # binary
        for line in data.decode("utf-8", "replace").splitlines():
            for rx, label in checks:
                if rx.search(line):
                    findings.append(f"{label} in {rel_path}: {line.strip()[:120]}")
                    break
    return findings


def scan(cwd, include_unstaged, include_untracked=False, include_ignored=False):
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

    if include_untracked:  # a same-command `git add`/`git stage` would pull these in too
        findings.extend(scan_disk_files(cwd, untracked_file_paths(cwd), checks))
    if include_ignored:  # ... and `-f`/`--force` would pull in gitignored files too
        findings.extend(scan_disk_files(cwd, ignored_file_paths(cwd), checks))

    return findings


def main():
    if os.environ.get("CLAUDE_COMMIT_GUARD", "1") == "0":
        return 0

    if len(sys.argv) > 1 and sys.argv[1] == "--staged":  # manual mode
        cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
        invocations = [(cwd, False, False, False)]
    else:  # hook mode
        try:
            data = json.load(sys.stdin)
        except Exception:
            return 0
        command = (data.get("tool_input") or {}).get("command") or ""
        cwd = data.get("cwd") or os.getcwd()
        try:
            invocations = find_commit_invocations(command, cwd)
        except Exception:
            return 0  # fail-open: e.g. shlex choked on unbalanced quotes
        if not invocations:
            return 0

    try:
        findings = []
        for scan_cwd, include_unstaged, include_untracked, include_ignored in invocations:
            findings.extend(scan(scan_cwd, include_unstaged, include_untracked, include_ignored))
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
