#!/usr/bin/env bash
# tests/test-install-capture.sh — behavioral tests for install.sh/capture.sh,
# the two scripts capable of clobbering real user state (~/.claude,
# ~/.claude-local). Everything runs under mktemp -d with HOME overridden for
# every invocation; NEVER touches the real home directory. Same PASS/FAIL
# check/report style as tests/test-commit-guard.sh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"
fail=0

ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- neutralize side-effecting external tools ------------------------------
# install.sh reaches out to a few external, side-effecting tools even with
# --no-models: the Playwright pre-warm step (npx), MCP registration (the
# claude binary), and a localhost:11434 probe (curl) that — if a real Ollama
# daemon happens to be running on the host running this suite — would go on
# to invoke the real sync-local.sh. None of that is safe or deterministic in
# a test. Stub all three on PATH before install.sh ever runs, loudly, the
# same way tests/lint.sh explicitly skips the PowerShell suite when pwsh is
# missing rather than silently doing the wrong thing.
echo "NOTE: stubbing claude/npx/curl on PATH so install.sh never touches the network or a real Claude/Ollama config in this suite."
STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUBS/npx" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
# Simulates "Ollama not reachable" so install.sh's localhost:11434 probe
# never fires the real sync-local.sh against a possibly-live daemon.
exit 1
EOF
chmod +x "$STUBS/claude" "$STUBS/npx" "$STUBS/curl"
export PATH="$STUBS:$PATH"

run_install() { # <HOME dir> [repo dir, default $REPO]
  local home="$1" repo="${2:-$REPO}"
  HOME="$home" "$repo/install.sh" --no-models </dev/null >"$TMP_ROOT/install.out" 2>&1
}

manifest_dest() { # <HOME dir> <MANIFEST rel> -> prints mapped destination
  case "$2" in
    claude-local/*) printf '%s\n' "$1/.claude-local/${2#claude-local/}" ;;
    claude/*)       printf '%s\n' "$1/.claude/${2#claude/}" ;;
  esac
}

manifest_entries() {
  sed 's/#.*//' "$REPO/MANIFEST" | awk 'NF {gsub(/^[ \t]+|[ \t]+$/,""); print}'
}

# =====================================================================
# 1. Fresh install: every MANIFEST entry deployed, hooks executable.
# =====================================================================
SANDBOX="$TMP_ROOT/sandbox"
mkdir -p "$SANDBOX"
if run_install "$SANDBOX"; then
  ok "1a fresh install exits 0"
else
  bad "1a fresh install exits 0"
  cat "$TMP_ROOT/install.out" >&2
fi

missing=0
while IFS= read -r rel; do
  dest="$(manifest_dest "$SANDBOX" "$rel")"
  [[ -f "$dest" ]] || { echo "  missing: $dest" >&2; missing=1; }
done < <(manifest_entries)
[[ "$missing" == 0 ]] && ok "1b every MANIFEST entry deployed" || bad "1b every MANIFEST entry deployed"

hooks_ok=1
for h in local-mode/claude-local local-mode/sync-local.sh local-mode/bootstrap-reverse.sh \
         local-mode/roles-lib.sh hooks/dispatch-directive.py hooks/post-edit-lint.py \
         hooks/keep-awake.py hooks/commit-guard.py hooks/statusline.py hooks/run-hook.sh; do
  [[ -x "$SANDBOX/.claude/$h" ]] || { echo "  not executable: $SANDBOX/.claude/$h" >&2; hooks_ok=0; }
done
[[ "$hooks_ok" == 1 ]] && ok "1c hook files executable" || bad "1c hook files executable"

# =====================================================================
# 2. roles.conf survival: user edit must NOT be reverted by a re-run.
# =====================================================================
CONF="$SANDBOX/.claude/local-mode/roles.conf"
sed -E -i.orig 's/^claude\.reviewer[[:space:]]*=.*/claude.reviewer = sonnet/' "$CONF"
rm -f "$CONF.orig"
run_install "$SANDBOX"
if grep -Eq '^claude\.reviewer[[:space:]]*=[[:space:]]*sonnet' "$CONF"; then
  ok "2a roles.conf edit survives a re-run"
else
  bad "2a roles.conf edit survives a re-run"
fi
if ! ls "$SANDBOX/.claude/local-mode/roles.conf.bak."* >/dev/null 2>&1; then
  ok "2b roles.conf never backed up (install-if-absent, no overwrite)"
else
  bad "2b roles.conf never backed up (install-if-absent, no overwrite)"
fi
grep -q "kept existing roles.conf" "$TMP_ROOT/install.out" \
  && ok "2c install.sh prints the kept-existing note" \
  || bad "2c install.sh prints the kept-existing note"

# =====================================================================
# 3. Model pin + general settings.json merge.
# =====================================================================
SETTINGS="$SANDBOX/.claude/settings.json"
python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["model"] = "claude-x"
data["myLocalKey"] = True
data["effortLevel"] = "low"  # diverge from the repo's shipped "high"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
run_install "$SANDBOX"
python3 - "$SETTINGS" <<'PY' && merge_read=0 || merge_read=1
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("model") == "claude-x", f"model pin lost: {data.get('model')!r}"
assert data.get("myLocalKey") is True, f"myLocalKey lost: {data.get('myLocalKey')!r}"
assert data.get("effortLevel") == "high", f"repo-shipped key not kept: {data.get('effortLevel')!r}"
PY
[[ "$merge_read" == 0 ]] && ok "3 model pin + unknown key survive, repo wins on shipped keys" \
  || bad "3 model pin + unknown key survive, repo wins on shipped keys"

# =====================================================================
# 4. Malformed deployed settings.json -> clean re-install, valid JSON.
# =====================================================================
printf '{ this is not json' > "$SETTINGS"
if run_install "$SANDBOX"; then
  ok "4a re-install exits 0 despite malformed live settings.json"
else
  bad "4a re-install exits 0 despite malformed live settings.json"
fi
python3 -m json.tool "$SETTINGS" >/dev/null 2>&1 \
  && ok "4b settings.json is valid JSON afterwards" \
  || bad "4b settings.json is valid JSON afterwards"

# =====================================================================
# 5 & 6. capture.sh, run from a scratch CLONE of the repo — never capture
# into this worktree.
# =====================================================================
# A full filesystem copy + fresh `git init` + one snapshot commit, rather
# than `git clone` (which would clone the worktree's last COMMIT and miss
# any uncommitted changes under test) — self-contained, decoupled from the
# real worktree's .git, and gives capture.sh's "uncommitted changes under
# home/" guard a clean baseline to diff against. This repo dogfoods its own
# worktree-isolated agents under .claude/worktrees/ — each one a nested git
# checkout — so .claude (and .git) are dropped before any git command runs:
# copying them in would make `git add -A` below try to add embedded repos
# (noisy "warning: adding embedded git repository" spam) and would waste
# time copying potentially many sibling worktrees we don't need.
CLONE="$TMP_ROOT/clone"
mkdir -p "$CLONE"
cp -R "$REPO/." "$CLONE"
rm -rf "${CLONE:?}/.git" "${CLONE:?}/.claude"
git -C "$CLONE" init -q
git -C "$CLONE" config user.email "test@example.com"
git -C "$CLONE" config user.name "Test"
add_out="$(git -C "$CLONE" add -A 2>&1)"
git -C "$CLONE" commit -q -m "snapshot for capture.sh sandbox test"
if grep -q "embedded git repository" <<<"$add_out"; then
  bad "5x clone excludes .claude/.git (no embedded-repo warning)"
  echo "$add_out" >&2
else
  ok "5x clone excludes .claude/.git (no embedded-repo warning)"
fi

# --- 5. clean-abort on a corrupt live settings.json -------------------
CORRUPT_HOME="$TMP_ROOT/corrupt-home"
mkdir -p "$CORRUPT_HOME/.claude"
printf '{ this is not json' > "$CORRUPT_HOME/.claude/settings.json"
if HOME="$CORRUPT_HOME" bash "$CLONE/capture.sh" >"$TMP_ROOT/capture-abort.out" 2>&1; then
  bad "5a capture.sh aborts (nonzero exit) on a corrupt live settings.json"
else
  ok "5a capture.sh aborts (nonzero exit) on a corrupt live settings.json"
fi
grep -q "ERROR" "$TMP_ROOT/capture-abort.out" \
  && ok "5b clean one-line error, no raw traceback" \
  || bad "5b clean one-line error, no raw traceback"
if [[ -z "$(git -C "$CLONE" status --porcelain)" ]]; then
  ok "5c clone's tracked files left untouched"
else
  bad "5c clone's tracked files left untouched"
fi

# --- 6. happy path: change in live HOME shows up in the clone ---------
CAPTURE_HOME="$TMP_ROOT/capture-home"
mkdir -p "$CAPTURE_HOME"
run_install "$CAPTURE_HOME" "$CLONE"
MARKER="# capture-test-marker-$$"
printf '\n%s\n' "$MARKER" >> "$CAPTURE_HOME/.claude/hooks/run-hook.sh"
python3 - "$CAPTURE_HOME/.claude/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data["model"] = "claude-y"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
if HOME="$CAPTURE_HOME" bash "$CLONE/capture.sh" >"$TMP_ROOT/capture-happy.out" 2>&1; then
  ok "6a capture.sh happy path exits 0"
else
  bad "6a capture.sh happy path exits 0"
  cat "$TMP_ROOT/capture-happy.out" >&2
fi
grep -qF "$MARKER" "$CLONE/home/claude/hooks/run-hook.sh" \
  && ok "6b live hook edit appears in the clone" \
  || bad "6b live hook edit appears in the clone"
if grep -q '"model"' "$CLONE/home/claude/settings.json"; then
  bad "6c captured settings.json has no model key"
else
  ok "6c captured settings.json has no model key"
fi

# =====================================================================
# 7. settings.json merge robustness: idempotence + non-ASCII round-trip.
# =====================================================================
SANDBOX_MERGE="$TMP_ROOT/sandbox-merge"
mkdir -p "$SANDBOX_MERGE"
run_install "$SANDBOX_MERGE"
SETTINGS_MERGE="$SANDBOX_MERGE/.claude/settings.json"

# 7a: a divergence that carries ZERO machine-local keys (same keys/values,
# just reformatted) must not make install.sh rewrite the file — the old
# code unconditionally re-dumped it even when nothing was merged, silently
# byte-diverging it from the repo copy (default ensure_ascii escaping) and
# so littering a FRESH backup on every single subsequent re-run forever.
python3 - "$SETTINGS_MERGE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
with open(path, "w") as f:
    json.dump(data, f, indent=4)  # same content, different formatting
    f.write("\n")
PY
run_install "$SANDBOX_MERGE"   # 1st re-run: reformat differs -> one backup
# STAMP has 1-second resolution — sleep so the two re-runs can't collide on
# the same *.bak.<timestamp> filename and mask a real second backup.
sleep 1
run_install "$SANDBOX_MERGE"   # 2nd re-run: must NOT add a second backup
bak_count="$(ls "$SETTINGS_MERGE".bak.* 2>/dev/null | wc -l | tr -d ' ')"
[[ "$bak_count" == 1 ]] \
  && ok "7a reformat-only divergence (no machine-local keys) litters exactly one backup, not one per re-run" \
  || bad "7a reformat-only divergence (no machine-local keys) litters exactly one backup ($bak_count found)"
cmp -s "$REPO/home/claude/settings.json" "$SETTINGS_MERGE" \
  && ok "7a2 file is byte-identical to the repo copy after a no-op merge (no needless rewrite)" \
  || bad "7a2 file is byte-identical to the repo copy after a no-op merge (no needless rewrite)"

# 7b: a real merge (a key genuinely gets carried over) must still preserve
# non-ASCII repo values byte-identically instead of \uXXXX-escaping them.
python3 - "$SETTINGS_MERGE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["model"] = "claude-z"  # forces a genuine key restoration -> real rewrite
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
run_install "$SANDBOX_MERGE"
if grep -qF "Routing…" "$SETTINGS_MERGE" && ! grep -q '\\u2026' "$SETTINGS_MERGE"; then
  ok "7b non-ASCII repo value ('Routing…') survives a real merge rewrite un-escaped"
else
  bad "7b non-ASCII repo value ('Routing…') survives a real merge rewrite un-escaped"
fi

# =====================================================================
# 8. sync-local.sh --plans (headless smoke test).
# =====================================================================
if plans_out="$(HOME="$SANDBOX" "$SANDBOX/.claude/local-mode/sync-local.sh" --plans 2>&1)"; then
  ok "8a sync-local.sh --plans exits 0"
else
  bad "8a sync-local.sh --plans exits 0"
  echo "$plans_out" >&2
fi
plans_ok=1
for preset in eco balanced best; do
  grep -q "$preset" <<<"$plans_out" || { echo "  missing preset in output: $preset" >&2; plans_ok=0; }
done
[[ "$plans_ok" == 1 ]] \
  && ok "8b --plans output mentions eco/balanced/best" \
  || bad "8b --plans output mentions eco/balanced/best"

# =====================================================================
# 9. Legacy "claude-fable-5" model-pin exclusion.
# =====================================================================
SANDBOX_FABLE="$TMP_ROOT/sandbox-fable"
mkdir -p "$SANDBOX_FABLE"
run_install "$SANDBOX_FABLE"
SETTINGS_FABLE="$SANDBOX_FABLE/.claude/settings.json"

python3 - "$SETTINGS_FABLE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["model"] = "claude-fable-5"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
run_install "$SANDBOX_FABLE"
if grep -q '"model"' "$SETTINGS_FABLE"; then
  bad "9a legacy 'claude-fable-5' pin is NOT resurrected on upgrade"
else
  ok "9a legacy 'claude-fable-5' pin is NOT resurrected on upgrade"
fi

python3 - "$SETTINGS_FABLE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["model"] = "claude-opus-4"  # any OTHER model value is a deliberate pin
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
run_install "$SANDBOX_FABLE"
if grep -q '"model": *"claude-opus-4"' "$SETTINGS_FABLE"; then
  ok "9b a non-legacy model pin DOES survive an upgrade"
else
  bad "9b a non-legacy model pin DOES survive an upgrade"
fi

if [[ "$fail" == 0 ]]; then
  echo "OK — all install/capture sandbox tests passed."
else
  echo "install/capture sandbox tests FAILED."
fi
exit "$fail"
