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

map_src() {
  case "$1" in
    claude-local/*) echo "$HOME/.claude-local/${1#claude-local/}" ;;
    claude/*)       echo "$HOME/.claude/${1#claude/}" ;;
    *)              return 1 ;;
  esac
}

while IFS= read -r rel; do
  rel="${rel%%#*}"; rel="$(echo "$rel" | xargs 2>/dev/null || true)"
  [[ -z "$rel" ]] && continue
  src="$(map_src "$rel")"
  dest="$REPO/home/$rel"
  [[ -f "$src" ]] || { echo "WARNING: $src not found on this machine, skipping." >&2; continue; }
  mkdir -p "$(dirname "$dest")"
  # Agent `model:` lines are captured verbatim, same as everything else:
  # roles.conf is captured in this same run, so the repo's roles.conf and
  # agent frontmatter derive from the same live state and stay consistent
  # by construction (see tests/lint.sh's roles.conf <-> frontmatter check).
  cp "$src" "$dest"
done < "$REPO/MANIFEST"

echo "Captured. Review with:  git -C $REPO status"
git -C "$REPO" status --short 2>/dev/null || true
