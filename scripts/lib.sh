#!/usr/bin/env bash
# Shared helpers for run-change/status. Sourced, not executed directly.
set -euo pipefail

REGISTRY="${OPENSPEC_STORE_REGISTRY:-$HOME/.local/share/openspec/stores/registry.yaml}"

# store_path <slug> -> absolute local_path for that store, from the CLI's
# own registry (there is no other source of truth for slug -> path).
store_path() {
  local slug="$1"
  [ -f "$REGISTRY" ] || { echo "no store registry at $REGISTRY" >&2; return 1; }
  awk -v slug="$slug" '
    $0 ~ "^  "slug":$" { found=1; next }
    found && /^  [a-zA-Z0-9_-]+:$/ { exit }
    found && /local_path:/ { sub(/.*local_path:[ ]*/, ""); print; exit }
  ' "$REGISTRY"
}

orchestration_dir() {
  local slug="$1"
  local path
  path="$(store_path "$slug")"
  [ -n "$path" ] || { echo "store '$slug' not found in $REGISTRY" >&2; return 1; }
  echo "$path/.orchestration"
}

# concurrency_cap <project_path> -> N from that project's openspec/config.yaml
# orchestration.concurrency, default 1.
concurrency_cap() {
  local project="$1"
  local cfg="$project/openspec/config.yaml"
  local n
  n="$(awk '/^orchestration:/{f=1;next} f && /^[a-zA-Z]/{exit} f && /concurrency:/{print $2; exit}' "$cfg" 2>/dev/null || true)"
  echo "${n:-1}"
}

gate_command() {
  local project="$1" mode="$2" # quick|full -> reads orchestration.gate_quick / gate_full
  local cfg="$project/openspec/config.yaml"
  local key="gate_${mode}"
  awk -v key="$key" '
    /^orchestration:/ { f=1; next }
    f && /^[a-zA-Z]/ { exit }
    f && index($0, key":") { sub(".*"key":[ ]*", ""); gsub(/^"|"$/, ""); print; exit }
  ' "$cfg" 2>/dev/null || true
}

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
