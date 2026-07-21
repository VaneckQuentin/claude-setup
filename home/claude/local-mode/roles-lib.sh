#!/usr/bin/env bash
# roles-lib.sh — shared roles.conf reader/writer (bash 3.2 compatible: no
# associative arrays). Sourced by sync-local.sh, install.sh,
# bootstrap-reverse.sh and tests/lint.sh — keep those four in sync with this
# file instead of hand-rolling parsers again.
#
# roles.conf format:  <role> = <model-tag>   [# comment]

# roles_conf_get <conf> <role> — echo the value assigned to an exact role
# (dots in <role>, e.g. "claude.explorer" or "tier.code", are regex-escaped).
# Empty output if the role is absent or its value is empty. Tolerates a stray
# trailing integer (legacy num_ctx column).
roles_conf_get() {
  local conf="$1" role="$2" role_re val last
  role_re="$(printf '%s' "$role" | sed 's/\./\\./g')"
  val="$(awk -v re="^[[:space:]]*${role_re}[[:space:]]*=" '
    $0 ~ re {
      v=$0; sub(/^[^=]*=/, "", v); sub(/#.*/, "", v);
      gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit
    }' "$conf")"
  last="${val##* }"; [[ "$val" == *" "* && "$last" =~ ^[0-9]+$ ]] && val="${val% *}"
  echo "$val"
}

# roles_conf_list_models <conf> — echo "role model" pairs for the
# Ollama-backed roles with a non-empty value (claude.* roles are Anthropic
# aliases, not Ollama tags, and are excluded).
roles_conf_list_models() {
  awk -F= '!/^[[:space:]]*#/ && NF>=2 && $1 !~ /claude\./ {
    role=$1; gsub(/[[:space:]]/,"",role);
    val=$2; sub(/#.*/,"",val); gsub(/[[:space:]]/,"",val);
    if (val != "") print role, val
  }' "$1"
}

# roles_conf_unique_models <conf> — unique, sorted Ollama tags to pull.
roles_conf_unique_models() {
  roles_conf_list_models "$1" | awk '{print $2}' | sort -u
}

# roles_conf_set <conf> <role> <model> — rewrite one assignment in place,
# keeping its trailing comment (dots in <role> are regex-escaped).
roles_conf_set() {
  local conf="$1" role="$2" model="$3" role_re
  role_re="$(printf '%s' "$role" | sed 's/\./\\./g')"
  awk -v re="^[[:space:]]*${role_re}[[:space:]]*=" -v m="$model" \
    '$0 ~ re { sub(/=[[:space:]]*[^#[:space:]]+/, "= " m) } { print }' \
    "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
}
