#!/usr/bin/env bash
# Black-box tests for scripts/run-change through its CLI interface only.
# Substitutes both seams: OPENSPEC_STORE_REGISTRY -> temp registry,
# --project -> temp git clone of a temp bare origin.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RC=scripts/run-change

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export OPENSPEC_STORE_REGISTRY="$TMP/registry.yaml"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

STORE="$TMP/store"
mkdir -p "$STORE/openspec"
cat > "$OPENSPEC_STORE_REGISTRY" <<EOF
stores:
  teststore:
    local_path: $STORE
EOF
# single rule: orchestration config lives in the store, never in the project
cat > "$STORE/openspec/config.yaml" <<'EOF'
orchestration:
  concurrency: 2
  gate_quick: "echo QUICK-OK"
  gate_full: "echo FULL-OK"
EOF

git init -q --bare -b main "$TMP/origin"
git clone -q "$TMP/origin" "$TMP/project"
PROJECT="$TMP/project"
echo hello > "$PROJECT/README"
git -C "$PROJECT" add -A && git -C "$PROJECT" commit -qm init && git -C "$PROJECT" push -q origin main

fails=0
check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $desc"; else echo "FAIL $desc"; fails=$((fails+1)); fi
}
check_out() { # check_out <desc> <expected-substring> <cmd...>
  local desc="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)" || { echo "FAIL $desc (exit)"; fails=$((fails+1)); return; }
  case "$out" in *"$want"*) echo "ok   $desc" ;; *) echo "FAIL $desc (got: $out)"; fails=$((fails+1)) ;; esac
}

# state
check "state init creates file" $RC state init --store teststore --name feat-a
check_out "state get returns phase" "phase: proposed" $RC state get --store teststore --name feat-a
$RC state set --store teststore --name feat-a phase applying blocked_on fix-b
check_out "state set updates phase" "phase: applying" $RC state get --store teststore --name feat-a
check_out "state set upserts new-style pair" "blocked_on: fix-b" $RC state get --store teststore --name feat-a
$RC state set --store teststore --name feat-a seams "auth=src/auth/session.ts,src/auth/token.ts;billing=src/billing/invoice.ts"
check_out "state set stores seam list" "auth=src/auth/session.ts,src/auth/token.ts;billing=src/billing/invoice.ts" $RC state get --store teststore --name feat-a
created="$(grep '^created_at:' "$STORE/.orchestration/state/feat-a.yaml")"
updated="$(grep '^updated_at:' "$STORE/.orchestration/state/feat-a.yaml")"
[ "${created#created_at:}" != "${updated#updated_at:}" ] || sleep 1
$RC state set --store teststore --name feat-a phase checking
updated2="$(grep '^updated_at:' "$STORE/.orchestration/state/feat-a.yaml")"
if [ "$updated2" != "created_at:${created#created_at:}" ] && [ -n "${updated2#updated_at: }" ]; then
  echo "ok   state set refreshes updated_at"
else
  echo "FAIL state set refreshes updated_at"; fails=$((fails+1))
fi

# session log
check_out "session list empty before any append" "" $RC session list --store teststore --name feat-a
$RC session append --store teststore --name feat-a role worker phase applying tier mechanical model haiku-4.5 transcript_id t1
$RC session append --store teststore --name feat-a role worker phase checking tier deep model opus-5 transcript_id t2
check_out "session list shows first entry" "tier=mechanical model=haiku-4.5" $RC session list --store teststore --name feat-a
check_out "session list shows second entry" "tier=deep model=opus-5" $RC session list --store teststore --name feat-a
lines="$($RC session list --store teststore --name feat-a | wc -l | tr -d ' ')"
[ "$lines" = "2" ] && echo "ok   session log appends, never rewrites" || { echo "FAIL session log appends, never rewrites (got $lines lines)"; fails=$((fails+1)); }

# status
check_out "status lists change" "feat-a" $RC status --store teststore
check_out "status shows phase" "checking" $RC status --store teststore
check_out "status shows last session tier" "deep" $RC status --store teststore

# slots (cap=2 from store config)
s1="$($RC slot acquire --store teststore --project "$PROJECT")"
s2="$($RC slot acquire --store teststore --project "$PROJECT")"
check_out "third slot refused at cap" "no free slot" bash -c "$RC slot acquire --store teststore --project '$PROJECT' 2>&1; true"
$RC slot release --store teststore --slot "$s1"
check "released slot reusable" $RC slot acquire --store teststore --project "$PROJECT"
$RC slot release --store teststore --slot "$s1"
$RC slot release --store teststore --slot "$s2"

# workspace
wt="$($RC workspace create --store teststore --project "$PROJECT" --name feat-a)"
check "workspace worktree exists" git -C "$wt" rev-parse --is-inside-work-tree
check "workspace branch exists" git -C "$PROJECT" rev-parse --verify change/feat-a
$RC workspace remove --store teststore --project "$PROJECT" --name feat-a
check "workspace removed" test ! -e "$wt"
check "branch removed" bash -c "! git -C '$PROJECT' rev-parse --verify -q change/feat-a"

# gates (config read from the store, project has no openspec/)
check_out "quick gate runs configured command" "QUICK-OK" $RC gate run --store teststore --project "$PROJECT" --mode quick
check_out "full gate runs configured command" "FULL-OK" $RC gate run --store teststore --project "$PROJECT" --mode full

# tier -> model
check_out "model get falls back to default for mechanical" "claude-haiku-4-5-20251001" $RC model get --store teststore --tier mechanical
check_out "model get falls back to default for deep" "claude-opus-5" $RC model get --store teststore --tier deep
cat >> "$STORE/openspec/config.yaml" <<'EOF'
  model_deep: "claude-opus-5-custom"
EOF
check_out "model get honors store override" "claude-opus-5-custom" $RC model get --store teststore --tier deep

# single rule: a project containing openspec/ is refused outright
mkdir "$PROJECT/openspec"
check_out "slot acquire refuses project with openspec/" "refusing" bash -c "$RC slot acquire --store teststore --project '$PROJECT' 2>&1; true"
check_out "workspace create refuses project with openspec/" "refusing" bash -c "$RC workspace create --store teststore --project '$PROJECT' --name feat-x 2>&1; true"
check_out "gate run refuses project with openspec/" "refusing" bash -c "$RC gate run --store teststore --project '$PROJECT' --mode quick 2>&1; true"
check_out "merge lane refuses project with openspec/" "refusing" bash -c "$RC merge-lane run --store teststore --project '$PROJECT' --name feat-x 2>&1; true"
rmdir "$PROJECT/openspec"

# merge lane: merges origin trunk into the change branch, reruns full gate, releases lock
$RC workspace create --store teststore --project "$PROJECT" --name feat-a >/dev/null 2>&1
check_out "merge lane merges trunk and runs full gate" "FULL-OK" $RC merge-lane run --store teststore --project "$PROJECT" --name feat-a
check "merge lock released" test ! -d "$STORE/.orchestration/merge.lock"
$RC workspace remove --store teststore --project "$PROJECT" --name feat-a

echo
[ "$fails" -eq 0 ] && echo "all tests passed" || { echo "$fails test(s) failed"; exit 1; }
