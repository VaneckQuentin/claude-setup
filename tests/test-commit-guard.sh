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

# Like check(), but for a blocked case: also asserts the block message on
# stderr names the offending file (so a user can actually find it).
check_blocked_mentions() { # <name> <command> <cwd> <needle>
  local name="$1" command="$2" cwd="$3" needle="$4" out got_exit got_stderr
  out="$(python3 -c '
import json, subprocess, sys
command, cwd, hook = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.dumps({"tool_input": {"command": command}, "cwd": cwd})
r = subprocess.run([sys.executable, hook], input=payload,
                    capture_output=True, text=True)
print(r.returncode)
print(r.stderr)
' "$command" "$cwd" "$HOOK")"
  got_exit="$(printf '%s' "$out" | head -1)"
  got_stderr="$(printf '%s' "$out" | tail -n +2)"
  if [[ "$got_exit" == "2" ]] && printf '%s' "$got_stderr" | grep -qF "$needle"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (exit=$got_exit, expected stderr to mention '$needle')"
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
mkdir -p "$REPO_UNTRACKED_SECRET/sub"

# Repo with only a clean UNTRACKED file — no secret anywhere in it, so
# staging + committing must still be allowed.
REPO_UNTRACKED_CLEAN="$(new_repo)"
echo "hello" > "$REPO_UNTRACKED_CLEAN/file.txt"
git -C "$REPO_UNTRACKED_CLEAN" add file.txt
git -C "$REPO_UNTRACKED_CLEAN" commit -q -m init
printf 'nothing sensitive here\n' > "$REPO_UNTRACKED_CLEAN/clean.txt"

# Repo with a gitignored .env holding a fake Anthropic key — invisible to a
# plain `git add` (git silently skips gitignored paths) but staged by a
# FORCED add (`git add -f`). Finding 3 coverage.
REPO_IGNORED_SECRET="$(new_repo)"
echo "hello" > "$REPO_IGNORED_SECRET/file.txt"
printf '.env\n' > "$REPO_IGNORED_SECRET/.gitignore"
git -C "$REPO_IGNORED_SECRET" add file.txt .gitignore
git -C "$REPO_IGNORED_SECRET" commit -q -m init
printf 'ANTHROPIC_API_KEY=sk-ant-1234567890abcdefghijklmnopqrstuvwxyz\n' > "$REPO_IGNORED_SECRET/.env"

OTHER_DIR="$(mktemp -d "$TMP_ROOT/other.XXXXXX")"

# --- required behaviors ---------------------------------------------------

check "1 plain commit, staged PEM -> blocked" \
  2 "git commit -m 'chore: x'" "$REPO_STAGED"

check "2 quote-split 'comm\"\"it', staged PEM -> blocked" \
  2 'git comm""it -m "chore: x"' "$REPO_STAGED"

check "3 git -C <A> commit from cwd B, staged PEM in A -> blocked" \
  2 "git -C $REPO_STAGED commit -m 'chore: x'" "$OTHER_DIR"

check "4 git commit -qam (combined flags), unstaged secret -> blocked" \
  2 "git commit -qam x" "$REPO_UNSTAGED"

check "5 clean repo, plain commit -> allowed" \
  0 "git commit -m 'chore: x'" "$REPO_CLEAN"

check "6 git status -> allowed" \
  0 "git status" "$REPO_STAGED"

check "7 cd <repo> && git commit, staged PEM -> blocked" \
  2 "cd $REPO_STAGED && git commit -m 'chore: x'" "$OTHER_DIR"

check "8 staged PEM + CLAUDE_COMMIT_GUARD=0 -> allowed (escape hatch)" \
  0 "git commit -m 'chore: x'" "$REPO_STAGED" CLAUDE_COMMIT_GUARD=0

check "9 forbidden filenames staged (id_ecdsa, server.key, .pgpass) -> blocked" \
  2 "git commit -m 'chore: x'" "$REPO_FORBIDDEN"

check "10 unstaged secret, plain commit (no -a) -> allowed (no false positive)" \
  0 "git commit -m 'chore: x'" "$REPO_UNSTAGED"

# --- bonus coverage for defects explicitly called out in the design ------

check "11 chained 'cd a && cd b && git commit' honors ALL leading cds" \
  2 "cd $TMP_ROOT && cd $(basename "$REPO_STAGED") && git commit -m 'chore: x'" "$OTHER_DIR"

check "12 commit message containing '-a' text doesn't fake-trigger -a" \
  0 'git commit -m "-a"' "$REPO_UNSTAGED" CLAUDE_COMMIT_CONVENTION=0

check "13 piped/xargs construction (echo | xargs git), staged PEM -> blocked" \
  2 'echo "commit -am x" | xargs git' "$REPO_STAGED"

# --- cross-review findings (H1/M2/M3) ------------------------------------

check "14 [H1] attached -m\"add auth\" (no -a), unstaged secret -> allowed" \
  0 'git commit -m"add auth"' "$REPO_UNSTAGED" CLAUDE_COMMIT_CONVENTION=0

check "15 [M2] -mX -a (real -a, separate token), unstaged secret -> blocked" \
  2 "git commit -mX -a" "$REPO_UNSTAGED"

check "16 [M3] git log --grep=commit, staged PEM -> allowed (read-only)" \
  0 "git log --grep=commit" "$REPO_STAGED"

# --- Finding 1: same-command staging (git add ... && git commit ...) -----

check_blocked_mentions "17 [F1][F2] git add <untracked AWS key> && git commit -> blocked, names creds.txt" \
  "git add creds.txt && git commit -m 'chore: x'" "$REPO_UNTRACKED_SECRET" "creds.txt"

check "18 [F1] git add -A && git commit -am, untracked AWS key -> blocked" \
  2 "git add -A && git commit -am x" "$REPO_UNTRACKED_SECRET"

check "19 [F1] git add <untracked clean file> && git commit -> allowed" \
  0 "git add clean.txt && git commit -m 'chore: x'" "$REPO_UNTRACKED_CLEAN"

check "20 [F1] git add <untracked file>, no commit in command -> allowed" \
  0 "git add creds.txt" "$REPO_UNTRACKED_SECRET"

# --- round-2 review findings (F1 root-relative paths, F3 forced ignored) --

check "21 [F1 r2] git add ... && git commit, cwd is a SUBDIR of the repo -> blocked" \
  2 "git add creds.txt && git commit -m 'chore: x'" "$REPO_UNTRACKED_SECRET/sub"

check "22 [F1 r2] cd sub && git add ... && git commit, from repo-root cwd -> blocked" \
  2 "cd sub && git add creds.txt && git commit -m 'chore: x'" "$REPO_UNTRACKED_SECRET"

check "23 [F3] git add -f <gitignored .env w/ secret> && git commit -> blocked" \
  2 "git add -f .env && git commit -m 'chore: x'" "$REPO_IGNORED_SECRET"

check "24 [F3] git add <gitignored .env, no -f> && git commit -> allowed (no-op add)" \
  0 "git add .env && git commit -m 'chore: x'" "$REPO_IGNORED_SECRET"

# --- Conventional Commits message check --------------------------------------
# Only the message is under test here: the repo has one harmless staged file.

REPO_CONV="$(new_repo)"
printf 'hello\n' > "$REPO_CONV/hello.txt"
git -C "$REPO_CONV" add hello.txt
printf 'docs: message read from a file\n\nBody paragraph.\n' > "$REPO_CONV/good-msg.txt"
printf 'Message read from a file\n' > "$REPO_CONV/bad-msg.txt"

check "30 [CC] feat: x -> allowed" 0 'git commit -m "feat: add x"' "$REPO_CONV"
check "31 [CC] fix(scope): x -> allowed" 0 'git commit -m "fix(install): x"' "$REPO_CONV"
check "32 [CC] feat!: x (breaking marker) -> allowed" 0 'git commit -m "feat!: x"' "$REPO_CONV"
check "33 [CC] comma scope + uppercase acronym in description -> allowed" \
  0 'git commit -m "fix(install,capture): CRLF-proof MANIFEST"' "$REPO_CONV"
check "34 [CC] capitalized type (Fix:) -> blocked" 2 'git commit -m "Fix: x"' "$REPO_CONV"
check "35 [CC] no type prefix -> blocked" 2 'git commit -m "update stuff"' "$REPO_CONV"
check "36 [CC] unknown type -> blocked" 2 'git commit -m "wip: x"' "$REPO_CONV"
check "37 [CC] missing space after colon -> blocked" 2 'git commit -m "feat:x"' "$REPO_CONV"
check "38 [CC] subject longer than 72 chars -> blocked" \
  2 "git commit -m 'feat: $(printf 'a%.0s' $(seq 1 70))'" "$REPO_CONV"
check "39 [CC] subject exactly 72 chars -> allowed" \
  0 "git commit -m 'feat: $(printf 'a%.0s' $(seq 1 66))'" "$REPO_CONV"
check "40 [CC] trailing period in subject -> blocked" 2 'git commit -m "feat: x."' "$REPO_CONV"
check "41 [CC] several -m (subject + body paragraphs) -> allowed" \
  0 'git commit -m "feat: x" -m "Body paragraph."' "$REPO_CONV"
check "42 [CC] second -m is the subject? no: first -m is; bad first -> blocked" \
  2 'git commit -m "bad" -m "feat: x"' "$REPO_CONV"
check "43 [CC] body glued to subject (no blank line) -> blocked" \
  2 $'git commit -m "feat: x\nbody without blank line"' "$REPO_CONV"
check "44 [CC] subject, blank line, body in one -m -> allowed" \
  0 $'git commit -m "feat: x\n\nbody"' "$REPO_CONV"
check "45 [CC] --message=feat: x (long form, =) -> allowed" \
  0 'git commit --message="feat: x"' "$REPO_CONV"
check "46 [CC] --message bad -> blocked" 2 'git commit --message "bad"' "$REPO_CONV"
check "47 [CC] attached short form -m\"feat: x\" -> allowed" 0 'git commit -m"feat: x"' "$REPO_CONV"
check "48 [CC] attached short form -m\"bad\" -> blocked" 2 'git commit -m"bad"' "$REPO_CONV"

HEREDOC_GOOD=$(cat <<'CMD'
git commit -m "$(cat <<'EOF'
feat: heredoc subject

Body line.
EOF
)"
CMD
)
HEREDOC_BAD=$(cat <<'CMD'
git commit -m "$(cat <<'EOF'
Heredoc subject without a type

Body line.
EOF
)"
CMD
)
check "49 [CC] -m \"\$(cat <<'EOF' …)\" heredoc, good -> allowed" 0 "$HEREDOC_GOOD" "$REPO_CONV"
check "50 [CC] -m \"\$(cat <<'EOF' …)\" heredoc, bad -> blocked" 2 "$HEREDOC_BAD" "$REPO_CONV"

STDIN_GOOD=$(cat <<'CMD'
git commit -F - <<'EOF'
chore: message on stdin

Body line.
EOF
CMD
)
STDIN_BAD=$(cat <<'CMD'
git commit -F - <<'EOF'
message on stdin without a type
EOF
CMD
)
check "51 [CC] -F - <<'EOF' heredoc, good -> allowed" 0 "$STDIN_GOOD" "$REPO_CONV"
check "52 [CC] -F - <<'EOF' heredoc, bad -> blocked" 2 "$STDIN_BAD" "$REPO_CONV"
check "53 [CC] -F file, good -> allowed" 0 'git commit -F good-msg.txt' "$REPO_CONV"
check "54 [CC] -F file, bad -> blocked" 2 'git commit -F bad-msg.txt' "$REPO_CONV"
check "55 [CC] --file=file, bad -> blocked" 2 'git commit --file=bad-msg.txt' "$REPO_CONV"
check "56 [CC] -F missing file -> allowed (fail-open, git will error itself)" \
  0 'git commit -F does-not-exist.txt' "$REPO_CONV"

check "57 [CC] no message (editor) -> allowed" 0 'git commit' "$REPO_CONV"
check "58 [CC] --amend --no-edit -> allowed" 0 'git commit --amend --no-edit' "$REPO_CONV"
check "59 [CC] --amend -m bad -> blocked" 2 'git commit --amend -m "bad"' "$REPO_CONV"
check "60 [CC] --fixup HEAD (auto message) -> allowed" 0 'git commit --fixup HEAD' "$REPO_CONV"
check "61 [CC] -C HEAD (reused message) -> allowed" 0 'git commit -C HEAD' "$REPO_CONV"
check "62 [CC] CLAUDE_COMMIT_CONVENTION=0 disables only the message check" \
  0 'git commit -m "bad"' "$REPO_CONV" CLAUDE_COMMIT_CONVENTION=0
check "63 [CC] CLAUDE_COMMIT_CONVENTION=0 keeps the secret scan" \
  2 'git commit -m "bad"' "$REPO_STAGED" CLAUDE_COMMIT_CONVENTION=0
check "64 [CC] cd repo && git commit -m bad -> blocked (message check follows statements)" \
  2 "cd $REPO_CONV && git commit -m 'bad'" "$TMP_ROOT"
check "65 [CC] git -C repo commit -m bad -> blocked" \
  2 "git -C $REPO_CONV commit -m 'bad'" "$TMP_ROOT"
check "66 [CC] a non-commit git command with a bad-looking -m -> allowed" \
  0 'git tag -a v1 -m "bad"' "$REPO_CONV"
check_blocked_mentions "67 [CC] block message explains the expected format" \
  'git commit -m "bad"' "$REPO_CONV" "Conventional Commits"

# --------------------------------------------------------------------------

if [[ "$fail" == 0 ]]; then
  echo "OK — all commit-guard tests passed."
else
  echo "commit-guard tests FAILED."
fi
exit "$fail"
