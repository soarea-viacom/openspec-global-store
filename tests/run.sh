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
  gate_quick: "echo QUICK-OK in $PWD"
  gate_full: "echo FULL-OK in $PWD"
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

# syntax first: a parse error would make every check below fail for the
# same reason, so stop here instead of drowning it in noise.
check "run-change parses" bash -n scripts/run-change
check "lib.sh parses" bash -n scripts/lib.sh
check "run.sh parses" bash -n tests/run.sh
[ "$fails" -eq 0 ] || { echo "syntax errors — not running behavior tests"; exit 1; }

# dead-code pass (the bash stand-in for knip): every function defined in the
# engine must be referenced somewhere other than its own definition.
dead=""
for fn in $(grep -ohE '^[a-z_]+\(\)' scripts/lib.sh scripts/run-change | tr -d '()'); do
  if ! grep -hE "\b$fn\b" scripts/lib.sh scripts/run-change tests/run.sh | grep -qvE "^$fn\(\)"; then
    dead="$dead $fn"
  fi
done
check "no engine function without a caller${dead:+ (dead:$dead)}" test -z "$dead"

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
check_out "status shows advisor calls against cap" "0/2" $RC status --store teststore
# advisor cap is enforced by the engine, not just displayed
check_out "direct session append of role advisor is refused" "reserved" bash -c "$RC session append --store teststore --name feat-a role advisor tier deep model x 2>&1; true"
check_out "advisor request grants and prints deep model" "claude-opus-5" $RC advisor request --store teststore --name feat-a --worker w1
check_out "status counts advisor calls" "1/2" $RC status --store teststore
check_out "second request from same worker refused" "already used its one advisor call" bash -c "$RC advisor request --store teststore --name feat-a --worker w1 2>&1; true"
check_out "request from another worker granted" "claude-opus-5" $RC advisor request --store teststore --name feat-a --worker w2
check_out "third request hits the per-change cap" "advisor cap reached" bash -c "$RC advisor request --store teststore --name feat-a --worker w3 2>&1; true"
check_out "status shows cap reached" "2/2" $RC status --store teststore
check_out "advisor entry records the asking worker" "role=advisor tier=deep model=claude-opus-5 for=w1" $RC session list --store teststore --name feat-a

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
check "workspace lives under the store, not the project" test "$wt" = "$STORE/.orchestration/workspaces/feat-a"
check "project checkout has no untracked workspace dir" bash -c "[ -z \"\$(git -C '$PROJECT' status --porcelain)\" ]"
check_out "store ignores its workspaces dir" ".orchestration/workspaces/" cat "$STORE/.gitignore"
$RC workspace create --store teststore --project "$PROJECT" --name feat-dup >/dev/null 2>&1
check "gitignore entry not duplicated" test "$(grep -c '.orchestration/workspaces/' "$STORE/.gitignore")" = 1
$RC workspace remove --store teststore --project "$PROJECT" --name feat-dup
# gate runs in the change's worktree, never the project's main checkout
check_out "quick gate runs in the worktree" "QUICK-OK in $wt" $RC gate run --store teststore --project "$PROJECT" --name feat-a --mode quick
check_out "quick gate does not record gate_tree" 'gate_tree: ""' $RC state get --store teststore --name feat-a
check_out "full gate runs in the worktree" "FULL-OK in $wt" $RC gate run --store teststore --project "$PROJECT" --name feat-a --mode full
check "passing full gate records the tree it ran on" bash -c "grep -qE '^gate_tree: [0-9a-f]{40}\$' '$STORE/.orchestration/state/feat-a.yaml'"
check_out "gate run without a workspace errors" "no workspace for change" bash -c "$RC gate run --store teststore --project '$PROJECT' --name feat-none --mode quick 2>&1; true"
$RC workspace remove --store teststore --project "$PROJECT" --name feat-a
check "workspace removed" test ! -e "$wt"
check "branch removed" bash -c "! git -C '$PROJECT' rev-parse --verify -q change/feat-a"

# gates (config read from the store, project has no openspec/)

# tier -> model
check_out "model get falls back to default for mechanical" "claude-haiku-4-5-20251001" $RC model get --store teststore --tier mechanical
check_out "model get falls back to default for deep" "claude-opus-5" $RC model get --store teststore --tier deep
cat >> "$STORE/openspec/config.yaml" <<'EOF'
  model_deep: "claude-opus-5-custom"
EOF
check_out "model get honors store override" "claude-opus-5-custom" $RC model get --store teststore --tier deep

# stage -> project skill(s) (docs/proposals/skill-stage-mapping.md)
check_out "stage-skills get is empty when stage_skills is unset" "" $RC stage-skills get --store teststore --stage plan
cat >> "$STORE/openspec/config.yaml" <<'EOF'
  stage_skills:
    plan: project-spec-drafter
    critic: [project-code-review]
    test: [project-test-skill, project-contract-checker]
EOF
check_out "stage-skills get returns the single plan skill" "project-spec-drafter" $RC stage-skills get --store teststore --stage plan
check_out "stage-skills get returns a one-item critic list" "project-code-review" $RC stage-skills get --store teststore --stage critic
out="$($RC stage-skills get --store teststore --stage test)"
check "stage-skills get returns both test-stage skills" test "$out" = "project-test-skill
project-contract-checker"
check_out "stage-skills get is empty for an unmapped stage" "" $RC stage-skills get --store teststore --stage apply

# generator/checker split: verify must use a model distinct from the implementer's
check_out "model verify with no history uses standard default" "claude-sonnet-5" $RC model verify --store teststore --name feat-verify
$RC session append --store teststore --name feat-verify role worker phase applying tier standard model claude-sonnet-5 transcript_id t1
check_out "model verify escalates to deep on collision" "claude-opus-5-custom" $RC model verify --store teststore --name feat-verify
cat >> "$STORE/openspec/config.yaml" <<'EOF'
  model_standard: "claude-opus-5-custom"
EOF
$RC session append --store teststore --name feat-verify role worker phase applying tier deep model claude-opus-5-custom transcript_id t2
check_out "model verify errors when every tier collapses" "no model distinct" bash -c "$RC model verify --store teststore --name feat-verify 2>&1; true"

# generator/checker split at Propose: critic must differ from the proposer
$RC state init --store teststore --name feat-critic
check_out "state init has propose_rounds" "propose_rounds: 0" $RC state get --store teststore --name feat-critic
$RC session append --store teststore --name feat-critic role worker phase proposed tier deep model claude-opus-5-custom transcript_id t1
check_out "model critic errors when standard collides with proposer and deep is the same" "no model distinct from proposer" bash -c "$RC model critic --store teststore --name feat-critic 2>&1; true"
$RC session append --store teststore --name feat-critic role worker phase proposed tier deep model some-other-model transcript_id t2
check_out "model critic uses standard when distinct from proposer" "claude-opus-5-custom" $RC model critic --store teststore --name feat-critic
$RC session append --store teststore --name feat-critic role worker phase applying tier standard model claude-opus-5-custom transcript_id t3
check_out "model critic ignores non-proposed entries" "claude-opus-5-custom" $RC model critic --store teststore --name feat-critic

# initiatives: own record, own critique-round counter, shown as a tree in status
check "initiative init creates file" $RC initiative init --store teststore --name init-a
check_out "initiative get has critique_rounds" "critique_rounds: 0" $RC initiative get --store teststore --name init-a
$RC initiative set --store teststore --name init-a children feat-a,feat-new critique_rounds 1 last_critique_result blocking:2
check_out "initiative set upserts rounds" "critique_rounds: 1" $RC initiative get --store teststore --name init-a
$RC initiative set --store teststore --name init-a last_critique_result blocking:1
check_out "initiative set shifts prev critique result too" "prev_critique_result: blocking:2" $RC initiative get --store teststore --name init-a
check "initiative is not a change state file" bash -c "! test -f '$STORE/.orchestration/state/init-a.yaml'"
check_out "status shows initiative tree" "init-a" $RC status --store teststore
check_out "status shows started child phase" "feat-a" $RC status --store teststore
check_out "status shows unstarted child" "not-started" $RC status --store teststore
$RC session append --store teststore --name init-a role worker phase proposed tier deep model claude-opus-5-custom transcript_id t9
check_out "model critic works for an initiative name" "no model distinct from proposer" bash -c "$RC model critic --store teststore --name init-a 2>&1; true"
check_out "initiative merged refuses unlisted child" "not a child" bash -c "$RC initiative merged --store teststore --name init-a --child feat-zzz --commit abc 2>&1; true"
$RC initiative merged --store teststore --name init-a --child feat-a --commit abc1234
check_out "initiative merged records sha" "merged: feat-a=abc1234" $RC initiative get --store teststore --name init-a
$RC initiative merged --store teststore --name init-a --child feat-new --commit def5678
$RC initiative merged --store teststore --name init-a --child feat-a --commit aaa0000
check_out "initiative merged upserts and keeps order" "merged: feat-a=aaa0000,feat-new=def5678" $RC initiative get --store teststore --name init-a
check_out "status shows merged child with sha" "aaa0000" $RC status --store teststore

# next: the orchestration policy as code — walk a change through the lifecycle
N="$RC next --store teststore --name feat-next"
$RC state init --store teststore --name feat-next
check_out "next: fresh change -> propose at deep" "action: propose" $N
check_out "next: propose model is deep" "model: claude-opus-5-custom" $N
$RC session append --store teststore --name feat-next role worker phase proposed tier deep model claude-opus-5-custom transcript_id p1
check_out "next: draft exists -> critique" "action: critique" $N
$RC state set --store teststore --name feat-next last_critique_result blocking:2
check_out "next: blocking critique -> revise round 1" "action: revise" $N
$RC state set --store teststore --name feat-next last_critique_result blocking:2
check_out "next: critique count unchanged -> gate1 not converging" "critique not converging" $N
$RC state set --store teststore --name feat-next last_critique_result blocking:1
check_out "next: critique count fell -> revise" "action: revise" $N
$RC state set --store teststore --name feat-next propose_rounds 2
check_out "next: blocking critique at cap -> gate1" "action: gate1" $N
$RC state set --store teststore --name feat-next last_critique_result request propose_rounds 0
check_out "next: request finding -> gate1" "action: gate1" $N
$RC state set --store teststore --name feat-next last_critique_result warnings:1
check_out "next: critique passed -> apply" "action: apply" $N
check_out "next: apply sets phase applying" "set_phase: applying" $N
$RC state set --store teststore --name feat-next phase applying
check_out "next: applying -> apply then checking" "set_phase: checking" $N
$RC state set --store teststore --name feat-next phase checking
check_out "next: checking with no gate result -> check" "action: check" $N
check_out "next: check also dispatches verify concurrently" "also: verify" $N
check_out "next: concurrent verify gets the distinct-model id" "also_model: claude-opus-5-custom" $N
$RC state set --store teststore --name feat-next last_gate_result red
check_out "next: red gate -> fix round 1" "action: fix" $N
check_out "next: fix round 1 is standard" "tier: standard" $N
$RC state set --store teststore --name feat-next fix_attempts 2
check_out "next: fix round 3 is deep" "tier: deep" $N
$RC state set --store teststore --name feat-next fix_attempts 3
check_out "next: red gate out of rounds -> gate1" "action: gate1" $N
$RC state set --store teststore --name feat-next last_gate_result green fix_attempts 0
check_out "next: green gate unverified -> verify" "action: verify" $N
$RC session append --store teststore --name feat-next role worker phase applying tier standard model claude-sonnet-5 transcript_id a1
check_out "next: verify model differs from implementer" "model: claude-opus-5-custom" $N
$RC state set --store teststore --name feat-next last_verify_result blocking:3
check_out "next: blocking verify -> fix round" "action: fix" $N
check_out "next: first blocking result has no prev" "prev_verify_result: \"\"" $RC state get --store teststore --name feat-next
$RC state set --store teststore --name feat-next last_verify_result ""
check_out "next: clearing for recheck shifts last into prev" "prev_verify_result: blocking:3" $RC state get --store teststore --name feat-next
$RC state set --store teststore --name feat-next last_verify_result blocking:1
check_out "next: writing over empty keeps prev" "prev_verify_result: blocking:3" $RC state get --store teststore --name feat-next
check_out "next: falling blocking count converges -> fix" "action: fix" $N
$RC state set --store teststore --name feat-next last_verify_result blocking:1
check_out "next: same blocking count -> gate1 not converging" "verify not converging: blocking:1 -> blocking:1" $N
$RC state set --store teststore --name feat-next last_verify_result blocking:4
check_out "next: rising blocking count -> gate1" "action: gate1" $N
$RC state set --store teststore --name feat-next last_verify_result warnings:3
check_out "next: warnings only -> mechanical sweep" "action: sweep" $N
$RC state set --store teststore --name feat-next last_verify_result spec
check_out "next: spec finding -> gate1" "action: gate1" $N
$RC state set --store teststore --name feat-next last_verify_result clean
check_out "next: verified clean -> archive" "action: archive" $N
$RC state set --store teststore --name feat-next phase archived
check_out "next: archived -> merge-lane" "action: merge-lane" $N
$RC state set --store teststore --name feat-next phase ready-to-merge
check_out "next: ready-to-merge -> gate2" "action: gate2" $N
$RC state set --store teststore --name feat-next phase merged
check_out "next: merged -> done" "action: done" $N
$RC state set --store teststore --name feat-next phase blocked blocked_on feat-dep
check_out "next: blocked -> wait" "blocked on feat-dep" $N
$RC state set --store teststore --name feat-next phase checking last_gate_result purple
check_out "next: unknown gate result errors" "unknown last_gate_result" bash -c "$N 2>&1; true"

# check phase with a verify result already recorded (both ran concurrently)
R="$RC next --store teststore --name feat-red"
$RC state init --store teststore --name feat-red
$RC state set --store teststore --name feat-red phase checking last_gate_result red last_verify_result spec
check_out "next: red gate but verify says spec -> gate1" "action: gate1" $R
$RC state set --store teststore --name feat-red last_verify_result blocking:2
check_out "next: red gate with blocking verify -> one fix round for both" "verify blocking:2" $R
check_out "next: that fix round clears both results" "clear last_gate_result and last_verify_result" $R
$RC state set --store teststore --name feat-red last_verify_result blocking:2
check_out "next: red gate, verify not converging -> gate1" "verify not converging" $R

# a project with its own openspec/ folder is refused when the resolved
# store is a DIFFERENT external root (that combination means the caller
# picked the wrong store for a project that should run in local mode)
mkdir "$PROJECT/openspec"
check_out "slot acquire refuses project with openspec/ against a different store" "refusing" bash -c "$RC slot acquire --store teststore --project '$PROJECT' 2>&1; true"
check_out "workspace create refuses project with openspec/ against a different store" "refusing" bash -c "$RC workspace create --store teststore --project '$PROJECT' --name feat-x 2>&1; true"
check_out "gate run refuses project with openspec/ against a different store" "refusing" bash -c "$RC gate run --store teststore --project '$PROJECT' --name feat-x --mode quick 2>&1; true"
check_out "merge lane refuses project with openspec/ against a different store" "refusing" bash -c "$RC merge-lane run --store teststore --project '$PROJECT' --name feat-x 2>&1; true"

# local mode: a store whose local_path IS the project itself is not refused,
# even though the project has its own openspec/ folder (SKILL.md Step 1)
cat >> "$OPENSPEC_STORE_REGISTRY" <<EOF
  localstore:
    local_path: $PROJECT
EOF
cat > "$PROJECT/openspec/config.yaml" <<'EOF'
orchestration:
  concurrency: 1
  gate_quick: "echo QUICK-OK in $PWD"
  gate_full: "echo FULL-OK in $PWD"
EOF
check "slot acquire allowed when the store's local_path is the project (local mode)" "$RC" slot acquire --store localstore --project "$PROJECT"
$RC slot release --store localstore --slot 1 >/dev/null 2>&1 || true
rmdir "$PROJECT/openspec" 2>/dev/null || rm -rf "$PROJECT/openspec"

# merge lane: merges origin trunk into the change branch, reruns the full gate
# only if the merged tree differs from the one that already passed, releases lock
$RC workspace create --store teststore --project "$PROJECT" --name feat-a >/dev/null 2>&1
check_out "merge lane skips the gate when the tree already passed it" "skipping rerun" $RC merge-lane run --store teststore --project "$PROJECT" --name feat-a
echo moved > "$PROJECT/TRUNK-MOVED" && git -C "$PROJECT" add -A && git -C "$PROJECT" commit -qm trunk-moves && git -C "$PROJECT" push -q origin main
before="$(grep '^gate_tree:' "$STORE/.orchestration/state/feat-a.yaml")"
check_out "merge lane merges trunk and reruns full gate when the tree changed" "FULL-OK in $STORE/.orchestration/workspaces/feat-a" $RC merge-lane run --store teststore --project "$PROJECT" --name feat-a
check "rerun full gate records the new tree" test "$(grep '^gate_tree:' "$STORE/.orchestration/state/feat-a.yaml")" != "$before"

# merge lane on a local-only project (no remote): merges the local trunk
LOCAL="$TMP/local-project"
git init -q -b main "$LOCAL"
echo one > "$LOCAL/README" && git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm init
$RC workspace create --store teststore --project "$LOCAL" --name feat-local >/dev/null 2>&1
echo two > "$LOCAL/FROM-TRUNK" && git -C "$LOCAL" add -A && git -C "$LOCAL" commit -qm trunk-moves
check_out "merge lane falls back to local trunk without a remote" "FULL-OK" $RC merge-lane run --store teststore --project "$LOCAL" --name feat-local
check "local trunk commit reached the change worktree" test -f "$STORE/.orchestration/workspaces/feat-local/FROM-TRUNK"
$RC workspace remove --store teststore --project "$LOCAL" --name feat-local
# ... and errors clearly when there is no trunk to find at all
NOTRUNK="$TMP/notrunk-project"
git init -q -b trunk "$NOTRUNK"
echo x > "$NOTRUNK/README" && git -C "$NOTRUNK" add -A && git -C "$NOTRUNK" commit -qm init
$RC workspace create --store teststore --project "$NOTRUNK" --name feat-nt >/dev/null 2>&1
check_out "merge lane errors when no trunk is identifiable" "cannot determine trunk" bash -c "$RC merge-lane run --store teststore --project '$NOTRUNK' --name feat-nt 2>&1; true"
check "merge lock released after trunk error" test ! -d "$STORE/.orchestration/merge.lock"
$RC workspace remove --store teststore --project "$NOTRUNK" --name feat-nt
check "merge lock released" test ! -d "$STORE/.orchestration/merge.lock"
$RC workspace remove --store teststore --project "$PROJECT" --name feat-a

# a project that is not a repo yet gets initialized before the workspace is cut:
# empty folder -> git init on main + empty initial commit
EMPTY="$TMP/empty-project"
mkdir -p "$EMPTY"
check "workspace create on an empty folder succeeds" $RC workspace create --store teststore --project "$EMPTY" --name feat-empty
check "empty folder became a repo on main" test "$(git -C "$EMPTY" symbolic-ref --short HEAD)" = main
check "empty folder has an initial commit" git -C "$EMPTY" rev-parse --verify -q HEAD
check "change branch exists in the new repo" git -C "$EMPTY" rev-parse --verify -q refs/heads/change/feat-empty
$RC workspace remove --store teststore --project "$EMPTY" --name feat-empty
# ... and un-tracked files (a first idea already written) land in that initial commit
IDEA="$TMP/idea-project"
mkdir -p "$IDEA" && echo idea > "$IDEA/notes.md"
$RC workspace create --store teststore --project "$IDEA" --name feat-idea >/dev/null 2>&1
check "existing files are in the initial commit" git -C "$IDEA" cat-file -e HEAD:notes.md
check "worktree of the new repo carries those files" test -f "$STORE/.orchestration/workspaces/feat-idea/notes.md"
check "init is idempotent on a repo that already has a commit" test "$(git -C "$IDEA" rev-list --count main)" = 1
$RC workspace remove --store teststore --project "$IDEA" --name feat-idea

echo
[ "$fails" -eq 0 ] && echo "all tests passed" || { echo "$fails test(s) failed"; exit 1; }
