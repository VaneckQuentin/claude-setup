#!/usr/bin/env bash
# tests/test-commit-guard.sh — behavioral tests for the pre-commit secret
# guard (home/claude/hooks/commit-guard.py). Creates throwaway git repos
# under mktemp -d, invokes the hook exactly as Claude Code does (the
# PreToolUse(Bash) JSON payload on stdin), and asserts exit codes (2 =
# blocked, 0 = allowed). Prints PASS/FAIL per case; leaves no state behind;
# exits nonzero if any case fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HOOK="$PWD/home/claude/hooks/commit-guard.py"
fail=0

# The fake secret is assembled at runtime so the literal PEM marker never
# appears verbatim in this committed source — otherwise the commit guard would
# (correctly) refuse to commit its own test fixture. The expanded value written
# into the throwaway repos below is a normal, complete PEM block.
PEM_KIND="RSA PRIVATE KEY"
FAKE_PEM="-----BEGIN ${PEM_KIND}-----
MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu
KUpRKfFLfRYC9AIKjbJTWit+CqvjWYzvQwECAwEAAQJAIJLixBy2qpFoS4DSmoEm
o3qGy0t6z09AIJtzOu0hFsIH6RmO+bA5UYFkAiUiOc9zsGeCPewJ4Hoz4YRvw9rf
gQIhAKNhTppdCXfTh+GXHFPYPu2NNu3fpxk80qsZ81/DdBLLAiEA0e0Uh+A9WLBS
CvwDx5C+kZTanF9Cv7HzZjHYD+8s7ZECIDMWvEJdEqcYDBrx7hpKQdaBSDoINn9x
tKmM/lCKk4tpAiEAyDkVn5B2GsPPTf6gYNc9Fmr9lJn3D9V2xcM6xO/YT5ECIQCX
NVwEGrEd23kOgOZLBz5cVX/ijk8V9RHu4NAtdo1cvw==
-----END ${PEM_KIND}-----"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

new_repo() { # -> prints the new repo's absolute path
  local dir
  dir="$(mktemp -d "$TMP_ROOT/repo.XXXXXX")"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf '%s\n' "$dir"
}

# Build the JSON payload Claude Code feeds a PreToolUse(Bash) hook on stdin
# and run commit-guard.py with it; prints the hook's exit code.
run_hook() { # <command> <cwd> [env_var=value ...]
  local command="$1" cwd="$2"
  shift 2
  env "$@" python3 -c '
import json, subprocess, sys
command, cwd, hook = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.dumps({"tool_input": {"command": command}, "cwd": cwd})
r = subprocess.run([sys.executable, hook], input=payload,
                    capture_output=True, text=True)
sys.exit(r.returncode)
' "$command" "$cwd" "$HOOK"
}

check() { # <name> <expected_exit> <command> <cwd> [env_var=value ...]
  local name="$1" expected="$2" command="$3" cwd="$4" got
  shift 4
  run_hook "$command" "$cwd" "$@"
  got=$?
  if [[ "$got" == "$expected" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (expected exit $expected, got $got)"
    fail=1
  fi
}

# --- fixtures -----------------------------------------------------------

# Repo with the fake PEM STAGED.
REPO_STAGED="$(new_repo)"
printf '%s\n' "$FAKE_PEM" > "$REPO_STAGED/secret.txt"
git -C "$REPO_STAGED" add secret.txt

# Clean repo, nothing staged.
REPO_CLEAN="$(new_repo)"
echo "hello" > "$REPO_CLEAN/file.txt"
git -C "$REPO_CLEAN" add file.txt
git -C "$REPO_CLEAN" commit -q -m init

# Repo with the fake PEM committed, then modified but left UNSTAGED
# (tracked-file change git commit -a would pick up).
REPO_UNSTAGED="$(new_repo)"
echo "placeholder" > "$REPO_UNSTAGED/secret.txt"
git -C "$REPO_UNSTAGED" add secret.txt
git -C "$REPO_UNSTAGED" commit -q -m init
printf '%s\n' "$FAKE_PEM" > "$REPO_UNSTAGED/secret.txt"

# Repo with forbidden filenames staged (empty content — the filename alone
# must be enough to block).
REPO_FORBIDDEN="$(new_repo)"
: > "$REPO_FORBIDDEN/id_ecdsa"
: > "$REPO_FORBIDDEN/server.key"
: > "$REPO_FORBIDDEN/.pgpass"
git -C "$REPO_FORBIDDEN" add id_ecdsa server.key .pgpass

# Repo with an UNTRACKED file containing a fake AWS key (never staged nor
# committed — only present on disk). Covers the same-command staging gap:
# the guard runs BEFORE the command, so `git add` in the same command line
# as `git commit` must be treated as if it already ran.
REPO_UNTRACKED_SECRET="$(new_repo)"
echo "hello" > "$REPO_UNTRACKED_SECRET/file.txt"
git -C "$REPO_UNTRACKED_SECRET" add file.txt
git -C "$REPO_UNTRACKED_SECRET" commit -q -m init
printf 'AWS_KEY=AKIA1234567890ABCDEF\n' > "$REPO_UNTRACKED_SECRET/creds.txt"

# Repo with only a clean UNTRACKED file — no secret anywhere in it, so
# staging + committing must still be allowed.
REPO_UNTRACKED_CLEAN="$(new_repo)"
echo "hello" > "$REPO_UNTRACKED_CLEAN/file.txt"
git -C "$REPO_UNTRACKED_CLEAN" add file.txt
git -C "$REPO_UNTRACKED_CLEAN" commit -q -m init
printf 'nothing sensitive here\n' > "$REPO_UNTRACKED_CLEAN/clean.txt"

OTHER_DIR="$(mktemp -d "$TMP_ROOT/other.XXXXXX")"

# --- required behaviors ---------------------------------------------------

check "1 plain commit, staged PEM -> blocked" \
  2 "git commit -m x" "$REPO_STAGED"

check "2 quote-split 'comm\"\"it', staged PEM -> blocked" \
  2 'git comm""it -m x' "$REPO_STAGED"

check "3 git -C <A> commit from cwd B, staged PEM in A -> blocked" \
  2 "git -C $REPO_STAGED commit -m x" "$OTHER_DIR"

check "4 git commit -qam (combined flags), unstaged secret -> blocked" \
  2 "git commit -qam x" "$REPO_UNSTAGED"

check "5 clean repo, plain commit -> allowed" \
  0 "git commit -m x" "$REPO_CLEAN"

check "6 git status -> allowed" \
  0 "git status" "$REPO_STAGED"

check "7 cd <repo> && git commit, staged PEM -> blocked" \
  2 "cd $REPO_STAGED && git commit -m x" "$OTHER_DIR"

check "8 staged PEM + CLAUDE_COMMIT_GUARD=0 -> allowed (escape hatch)" \
  0 "git commit -m x" "$REPO_STAGED" CLAUDE_COMMIT_GUARD=0

check "9 forbidden filenames staged (id_ecdsa, server.key, .pgpass) -> blocked" \
  2 "git commit -m x" "$REPO_FORBIDDEN"

check "10 unstaged secret, plain commit (no -a) -> allowed (no false positive)" \
  0 "git commit -m x" "$REPO_UNSTAGED"

# --- bonus coverage for defects explicitly called out in the design ------

check "11 chained 'cd a && cd b && git commit' honors ALL leading cds" \
  2 "cd $TMP_ROOT && cd $(basename "$REPO_STAGED") && git commit -m x" "$OTHER_DIR"

check "12 commit message containing '-a' text doesn't fake-trigger -a" \
  0 'git commit -m "-a"' "$REPO_UNSTAGED"

check "13 piped/xargs construction (echo | xargs git), staged PEM -> blocked" \
  2 'echo "commit -am x" | xargs git' "$REPO_STAGED"

# --- cross-review findings (H1/M2/M3) ------------------------------------

check "14 [H1] attached -m\"add auth\" (no -a), unstaged secret -> allowed" \
  0 'git commit -m"add auth"' "$REPO_UNSTAGED"

check "15 [M2] -mX -a (real -a, separate token), unstaged secret -> blocked" \
  2 "git commit -mX -a" "$REPO_UNSTAGED"

check "16 [M3] git log --grep=commit, staged PEM -> allowed (read-only)" \
  0 "git log --grep=commit" "$REPO_STAGED"

# --- Finding 1: same-command staging (git add ... && git commit ...) -----

check "17 [F1] git add <untracked AWS key> && git commit -> blocked" \
  2 "git add creds.txt && git commit -m x" "$REPO_UNTRACKED_SECRET"

check "18 [F1] git add -A && git commit -am, untracked AWS key -> blocked" \
  2 "git add -A && git commit -am x" "$REPO_UNTRACKED_SECRET"

check "19 [F1] git add <untracked clean file> && git commit -> allowed" \
  0 "git add clean.txt && git commit -m x" "$REPO_UNTRACKED_CLEAN"

check "20 [F1] git add <untracked file>, no commit in command -> allowed" \
  0 "git add creds.txt" "$REPO_UNTRACKED_SECRET"

# --------------------------------------------------------------------------

if [[ "$fail" == 0 ]]; then
  echo "OK — all commit-guard tests passed."
else
  echo "commit-guard tests FAILED."
fi
exit "$fail"
