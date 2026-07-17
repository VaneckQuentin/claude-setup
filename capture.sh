#!/usr/bin/env bash
# capture.sh — copy the LIVE setup files from this machine back into the repo,
# so tweaks made in ~/.claude get committed. Run before `git commit`.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

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
  cp "$src" "$dest"
done < "$REPO/MANIFEST"

echo "Captured. Review with:  git -C $REPO status"
git -C "$REPO" status --short 2>/dev/null || true
