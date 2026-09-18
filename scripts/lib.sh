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

# Orchestration config lives ONLY in the store's openspec/config.yaml.
# Single rule: a target project must not contain an openspec/ folder at all
# (require_no_project_openspec below); there is no project-side fallback.
store_config() {
  local slug="$1"
  local path
  path="$(store_path "$slug")"
  [ -n "$path" ] || { echo "store '$slug' not found in $REGISTRY" >&2; return 1; }
  echo "$path/openspec/config.yaml"
}

require_no_project_openspec() {
  local project="$1"
  [ ! -e "$project/openspec" ] || {
    echo "refusing: $project contains an openspec/ folder — orchestrated projects must not; orchestration config lives in the store's openspec/config.yaml" >&2
    return 1
  }
}

# concurrency_cap <store-slug> -> N from the store's openspec/config.yaml
# orchestration.concurrency, default 1.
concurrency_cap() {
  local cfg
  cfg="$(store_config "$1")"
  local n
  n="$(awk '/^orchestration:/{f=1;next} f && /^[a-zA-Z]/{exit} f && /concurrency:/{print $2; exit}' "$cfg" 2>/dev/null || true)"
  echo "${n:-1}"
}

gate_command() {
  local slug="$1" mode="$2" # quick|full -> reads orchestration.gate_quick / gate_full
  local cfg
  cfg="$(store_config "$slug")"
  local key="gate_${mode}"
  awk -v key="$key" '
    /^orchestration:/ { f=1; next }
    f && /^[a-zA-Z]/ { exit }
    f && index($0, key":") { sub(".*"key":[ ]*", ""); gsub(/^"|"$/, ""); print; exit }
  ' "$cfg" 2>/dev/null || true
}

# model_for_tier <store-slug> <tier> -> model id for mechanical|standard|deep
# (the `none` tier runs no model — it's plain bash bookkeeping). Reads
# orchestration.model_<tier> from the store's config first; falls back to
# the default table below when unset. The default table is the only place
# in the engine that names a specific model id — update it here, not
# per-callsite, when the current-best model changes.
model_for_tier() {
  local slug="$1" tier="$2"
  local cfg
  cfg="$(store_config "$slug")"
  local key="model_${tier}"
  local v
  v="$(awk -v key="$key" '
    /^orchestration:/ { f=1; next }
    f && /^[a-zA-Z]/ { exit }
    f && index($0, key":") { sub(".*"key":[ ]*", ""); gsub(/^"|"$/, ""); print; exit }
  ' "$cfg" 2>/dev/null || true)"
  if [ -n "$v" ]; then
    echo "$v"
    return 0
  fi
  case "$tier" in
    mechanical) echo "claude-haiku-4-5-20251001" ;;
    standard)   echo "claude-sonnet-5" ;;
    deep)       echo "claude-opus-5" ;;
    *)          echo "unknown tier: $tier" >&2; return 1 ;;
  esac
}

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# State module: sole owner of the state-file YAML dialect (flat "key: value",
# values may contain colons, optional surrounding quotes). Nothing outside
# these three functions may awk/grep a state file.
state_root() {
  echo "$(orchestration_dir "$1")/state"
}

# workspace_path <store-slug> <change-name> — where a change's worktree is
# checked out. Under the store, not the project: the project's repo owns
# the branch and history (git records the worktree in its .git/worktrees),
# but its main checkout must never see orchestration files. The store is a
# git repo too, so ensure_workspace_ignored keeps the checkout out of it.
workspace_path() {
  echo "$(orchestration_dir "$1")/workspaces/$2"
}

ensure_workspace_ignored() {
  local store; store="$(store_path "$1")"
  local ignore="$store/.gitignore"
  grep -qxF '.orchestration/workspaces/' "$ignore" 2>/dev/null && return 0
  echo '.orchestration/workspaces/' >> "$ignore"
}

# initiative_root <store-slug> — initiative records share the state-file YAML
# dialect (state_field/state_write) but live apart from change state so
# `status` never mistakes one for a change.
initiative_root() {
  echo "$(orchestration_dir "$1")/initiatives"
}

# state_field <file> <key> -> value with surrounding quotes stripped, empty if absent.
state_field() {
  awk -v k="$2" '
    index($0, k": ") == 1 {
      v = substr($0, length(k) + 3)
      gsub(/^"|"$/, "", v)
      print v; exit
    }
    $0 == k":" { print ""; exit }
  ' "$1"
}

# state_write <file> key value [key value ...] — upsert pairs, refresh updated_at.
state_write() {
  local f="$1"; shift
  while [ $# -ge 2 ]; do
    local key="$1" val="$2"; shift 2
    local tmp="$f.tmp"
    if grep -q "^$key:" "$f"; then
      awk -v k="$key" -v v="$val" '
        index($0, k":") == 1 { print k": "v; next } { print }
      ' "$f" > "$tmp"
    else
      cat "$f" > "$tmp"
      echo "$key: $val" >> "$tmp"
    fi
    mv "$tmp" "$f"
  done
  awk -v v="$(timestamp)" '
    index($0, "updated_at:") == 1 { print "updated_at: \""v"\""; next } { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# Session log: sole owner of the session-history file, one logfmt line per
# orchestrator/worker run against a change (name=value pairs, space
# separated, values must not contain spaces). Append-only — a run's entry
# is never edited after the fact, only added to. Nothing outside these four
# functions may write or parse a session log.
session_log_path() {
  echo "$(state_root "$1")/$2.sessions.log"
}

# session_append <file> key value [key value ...] — append one line, ts auto-set.
session_append() {
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  local line="ts=$(timestamp)"
  while [ $# -ge 2 ]; do
    line="$line $1=$2"
    shift 2
  done
  echo "$line" >> "$f"
}

# last_model_for_phases <store-slug> <change-name> <phase-regex> -> the
# model id of the most recent session entry whose phase matches, empty if
# none. The session log is the only record of who wrote what.
last_model_for_phases() {
  local f; f="$(session_log_path "$1" "$2")"
  [ -f "$f" ] || return 0
  grep -E "phase=($3)" "$f" 2>/dev/null | tail -n1 \
    | grep -o 'model=[^ ]*' | cut -d= -f2 || true
}

# advisor_calls <store-slug> <change-name> -> count of role=advisor session
# entries. The per-change advisor cap (see Advisor in
# AUTONOMOUS-ORCHESTRATION.md) is enforced by the orchestrator against this
# number; the log is the only record of it, so nothing else caches a count.
ADVISOR_CAP=2
advisor_calls() {
  local f; f="$(session_log_path "$1" "$2")"
  [ -f "$f" ] || { echo 0; return 0; }
  grep -c 'role=advisor' "$f" || true
}

# advisor_calls_for <store-slug> <change-name> <worker-transcript-id> -> how
# many advisor entries already name this worker (`for=<id>`). Per-worker cap
# is 1: a second question means the task isn't routine — escalate the task.
advisor_calls_for() {
  local f; f="$(session_log_path "$1" "$2")"
  [ -f "$f" ] || { echo 0; return 0; }
  grep 'role=advisor' "$f" | grep -c "for=$3\( \|$\)" || true
}

# implementer_model <store-slug> <change-name> -> model of the most recent
# applying/checking entry (the code currently on the branch).
implementer_model() { last_model_for_phases "$1" "$2" 'applying|checking'; }

# proposer_model <store-slug> <change-name> -> model of the most recent
# proposed entry (whoever drafted the current delta spec + seam list).
proposer_model() { last_model_for_phases "$1" "$2" 'proposed'; }

# checker_model <store-slug> <generator-model> <label> -> a model id
# guaranteed distinct from the generator's, for the generator/checker split.
# Baseline tier is `standard`; on collision escalate to `deep` rather than
# let a model review its own work. `mechanical` is never a candidate: too
# weak to judge a spec or a diff against one. Errors if standard and deep
# collapse to the generator's model (a store misconfiguration).
checker_model() {
  local slug="$1" gen="$2" label="$3"
  local candidate; candidate="$(model_for_tier "$slug" standard)"
  if [ -n "$gen" ] && [ "$candidate" = "$gen" ]; then
    candidate="$(model_for_tier "$slug" deep)"
  fi
  if [ -n "$gen" ] && [ "$candidate" = "$gen" ]; then
    echo "no model distinct from $label ($gen) available — check orchestration.model_* in $(store_config "$slug")" >&2
    return 1
  fi
  echo "$candidate"
}

# verify_model: checker for the Verify step, distinct from the implementer.
verify_model() { checker_model "$1" "$(implementer_model "$1" "$2")" implementer; }

# critic_model: checker for the Propose critique, distinct from the proposer.
# Propose runs at deep, so this normally resolves to standard's model.
critic_model() { checker_model "$1" "$(proposer_model "$1" "$2")" proposer; }
