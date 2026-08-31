#!/usr/bin/env bash
# capture.sh — copy the LIVE setup files from this machine back into the repo,
# so tweaks made in ~/.claude get committed. Run before `git commit`.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

# Refuse to clobber uncommitted repo work: capture overwrites repo files with
# the live copies, silently reverting any repo-side edit that wasn't deployed
# yet. Commit/stash first, or CAPTURE_FORCE=1 to overwrite anyway.
if { ! git -C "$REPO" diff --quiet -- home/ 2>/dev/null || ! git -C "$REPO" diff --cached --quiet -- home/ 2>/dev/null; } && [[ "${CAPTURE_FORCE:-0}" != 1 ]]; then
  echo "ERROR: uncommitted changes under home/ would be overwritten by the live files." >&2
  { git -C "$REPO" diff --name-only -- home/; git -C "$REPO" diff --cached --name-only -- home/; } | sort -u | sed 's/^/  - /' >&2
  echo "Commit or stash them first (or CAPTURE_FORCE=1 to overwrite)." >&2
  exit 1
fi

# Probe for a WORKING interpreter, same as install.sh (Windows installs
# python as python/py, no python3; Microsoft Store aliases add fake stubs).
PYBIN=""
for c in python3 python py; do "$c" -c "" >/dev/null 2>&1 && { PYBIN="$c"; break; }; done
[[ -n "$PYBIN" ]] || { echo "ERROR: no working python found (tried python3, python, py)." >&2; exit 1; }

map_src() {
  case "$1" in
    claude-local/*) echo "$HOME/.claude-local/${1#claude-local/}" ;;
    claude/*)       echo "$HOME/.claude/${1#claude/}" ;;
    *)              return 1 ;;
  esac
}

# settings.json carries a machine-local top-level "model" pin that the repo
# deliberately does not ship (see install.sh's model-pin preservation block)
# — strip it into a scratch copy BEFORE anything touches the repo, so a
# corrupt live settings.json aborts cleanly instead of leaving a partial
# capture (and re-tripping the CAPTURE_FORCE guard above).
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

strip_model_pin() { # <src settings.json> <out path> — repo-relative path
                     # kept as the scratch filename to avoid basename
                     # collisions (claude/settings.json vs claude-local/*).
  local src="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  "$PYBIN" - "$src" "$out" <<'PY'
import json, sys
src_path, out_path = sys.argv[1], sys.argv[2]
with open(src_path) as f:
    data = json.load(f)
if isinstance(data, dict) and "model" in data:
    del data["model"]
with open(out_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

manifest_entries() {
  while IFS= read -r rel; do
    rel="${rel%$'\r'}"
    rel="${rel%%#*}"; rel="$(echo "$rel" | xargs 2>/dev/null || true)"
    [[ -z "$rel" ]] && continue
    printf '%s\n' "$rel"
  done < "$REPO/MANIFEST"
}

echo "== Validating live sources"
while IFS= read -r rel; do
  src="$(map_src "$rel")"
  [[ -f "$src" ]] || { echo "WARNING: $src not found on this machine, skipping." >&2; continue; }
  [[ "$rel" == *settings.json ]] || continue
  strip_model_pin "$src" "$SCRATCH/$rel" \
    || { echo "ERROR: failed to read/parse $src (corrupt settings.json?) — capture aborted, repo untouched." >&2; exit 1; }
done < <(manifest_entries)

echo "== Capturing"
while IFS= read -r rel; do
  src="$(map_src "$rel")"
  dest="$REPO/home/$rel"
  [[ -f "$src" ]] || continue
  mkdir -p "$(dirname "$dest")"
  # Agent `model:` lines are captured verbatim, same as everything else:
  # roles.conf is captured in this same run, so the repo's roles.conf and
  # agent frontmatter derive from the same live state and stay consistent
  # by construction (see tests/lint.sh's roles.conf <-> frontmatter check).
  if [[ "$rel" == *settings.json ]]; then
    cp "$SCRATCH/$rel" "$dest"
  else
    cp "$src" "$dest"
  fi
done < <(manifest_entries)

echo "Captured. Review with:  git -C $REPO status"
git -C "$REPO" status --short 2>/dev/null || true
