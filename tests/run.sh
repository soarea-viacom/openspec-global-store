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
check_out "state init has empty acceptance" 'acceptance: ""' $RC state get --store teststore --name feat-a
check_out "state init has full lifecycle" "lifecycle: full" $RC state get --store teststore --name feat-a
check_out "state init has empty manual_tasks_open" 'manual_tasks_open: ""' $RC state get --store teststore --name feat-a
check_out "state init has empty manual_accept" 'manual_accept: ""' $RC state get --store teststore --name feat-a
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

# generator/checker split: the checker is one tier above the generator
check_out "model get knows the max tier" "claude-fable-5-1" $RC model get --store teststore --tier max
check_out "model verify with no history assumes a standard implementer -> deep" "claude-opus-5-custom" $RC model verify --store teststore --name feat-verify
$RC session append --store teststore --name feat-verify role worker phase applying tier standard model claude-sonnet-5 transcript_id t1
check_out "model verify picks the tier above the implementer" "claude-opus-5-custom" $RC model verify --store teststore --name feat-verify
check_out "model verify contract names the store/name/seams field" "--store teststore --name feat-verify, field seams" $RC model verify --store teststore --name feat-verify
check_out "model verify first line is the bare model id" "claude-opus-5-custom" bash -c "$RC model verify --store teststore --name feat-verify | head -n1"
check_out "model verify contract mentions input and seam" "input:" $RC model verify --store teststore --name feat-verify
$RC session append --store teststore --name feat-infer role worker phase applying model claude-sonnet-5 transcript_id t1
check_out "model verify infers the tier from the model when an entry has none" "claude-opus-5-custom" $RC model verify --store teststore --name feat-infer
cat >> "$STORE/openspec/config.yaml" <<'EOF'
  model_standard: "claude-opus-5-custom"
EOF
check_out "model verify errors when a tier-less entry's model maps to no tier" "cannot tell which tier" bash -c "$RC model verify --store teststore --name feat-infer 2>&1; true"
$RC session append --store teststore --name feat-verify role worker phase applying tier deep model claude-opus-5-custom transcript_id t2
check_out "model verify for a deep implementer goes to max" "claude-fable-5-1" $RC model verify --store teststore --name feat-verify
cat >> "$STORE/openspec/config.yaml" <<'EOF'
  model_max: "claude-opus-5-custom"
EOF
check_out "model verify errors when the tier above resolves to the implementer's model" "resolves to the implementer's own model" bash -c "$RC model verify --store teststore --name feat-verify 2>&1; true"

# generator/checker split at Propose: the critic is one tier above the proposer
$RC state init --store teststore --name feat-critic
check_out "state init has propose_rounds" "propose_rounds: 0" $RC state get --store teststore --name feat-critic
$RC session append --store teststore --name feat-critic role worker phase proposed tier deep model claude-opus-5-custom transcript_id t1
check_out "model critic errors when max resolves to the proposer's model" "resolves to the proposer's own model" bash -c "$RC model critic --store teststore --name feat-critic 2>&1; true"
$RC session append --store teststore --name feat-critic role worker phase proposed tier deep model some-other-model transcript_id t2
check_out "model critic uses max for a deep proposer" "claude-opus-5-custom" $RC model critic --store teststore --name feat-critic
$RC session append --store teststore --name feat-critic role worker phase applying tier standard model claude-opus-5-custom transcript_id t3
check_out "model critic ignores non-proposed entries" "claude-opus-5-custom" $RC model critic --store teststore --name feat-critic
$RC session append --store teststore --name feat-critic role worker phase proposed tier max model claude-fable-5-1 transcript_id t4
check_out "model critic for a max proposer drops to deep, the second highest" "claude-opus-5-custom" $RC model critic --store teststore --name feat-critic
$RC session append --store teststore --name feat-critic role worker phase proposed tier max model claude-opus-5-custom transcript_id t5
check_out "model critic errors when deep resolves to a max proposer's model" "resolves to the proposer's own model" bash -c "$RC model critic --store teststore --name feat-critic 2>&1; true"
$RC session append --store teststore --name feat-critic role worker phase proposed tier standard model claude-sonnet-5 transcript_id t6
check_out "model critic first line is the bare model id" "claude-opus-5-custom" bash -c "$RC model critic --store teststore --name feat-critic | head -n1"
check_out "model critic contract mentions input and seam" "input:" $RC model critic --store teststore --name feat-critic
check_out "model critic contract names the store/name/seams field" "--store teststore --name feat-critic, field seams" $RC model critic --store teststore --name feat-critic

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
check_out "model critic works for an initiative name" "resolves to the proposer's own model" bash -c "$RC model critic --store teststore --name init-a 2>&1; true"
$RC session append --store teststore --name init-a role worker phase proposed tier deep model claude-opus-5-other transcript_id t10
check_out "model critic for an initiative (no change state file) prints the contract" "input:" $RC model critic --store teststore --name init-a
check_out "initiative merged refuses unlisted child" "not a child" bash -c "$RC initiative merged --store teststore --name init-a --child feat-zzz --commit abc 2>&1; true"
$RC initiative merged --store teststore --name init-a --child feat-a --commit abc1234
check_out "initiative merged records sha" "merged: feat-a=abc1234" $RC initiative get --store teststore --name init-a
$RC initiative merged --store teststore --name init-a --child feat-new --commit def5678
$RC initiative merged --store teststore --name init-a --child feat-a --commit aaa0000
check_out "initiative merged upserts and keeps order" "merged: feat-a=aaa0000,feat-new=def5678" $RC initiative get --store teststore --name init-a
check_out "status shows merged child with sha" "aaa0000" $RC status --store teststore

# lifecycle field: empty reads as full (exercised throughout below); any
# other value is refused outright
$RC state init --store teststore --name feat-bogus-lifecycle
$RC state set --store teststore --name feat-bogus-lifecycle lifecycle bogus
check_out "next: unknown lifecycle errors" "unknown lifecycle" bash -c "$RC next --store teststore --name feat-bogus-lifecycle 2>&1; true"

# next: the orchestration policy as code — walk a change through the lifecycle
N="$RC next --store teststore --name feat-next"
$RC state init --store teststore --name feat-next
check_out "next: fresh change -> propose at deep" "action: propose" $N
check_out "next: propose model is deep" "model: claude-opus-5-custom" $N
$RC session append --store teststore --name feat-next role worker phase proposed tier deep model claude-opus-5-plain transcript_id p1
check_out "next: draft exists -> critique" "action: critique" $N
check_out "next: critique of a deep draft runs at max" "tier: max" $N
$RC session append --store teststore --name feat-next role worker phase proposed tier max model claude-fable-5-1 transcript_id p2
check_out "next: critique of a max draft runs at deep" "tier: deep" $N
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
check_out "next: critique passed -> gate0" "action: gate0" $N
check_out "next: gate0 sets phase awaiting-acceptance" "set_phase: awaiting-acceptance" $N
check_out "next: gate0 reason names the fast-path option" "fast-path" $N
check_out "next: gate0 reason names light lifecycle" "light lifecycle" $N
$RC state set --store teststore --name feat-next phase awaiting-acceptance
check_out "next: awaiting-acceptance with no answer -> gate0 again" "action: gate0" $N

# Gate 0: a human "revise" answer restarts Propose; a fresh draft naturally
# lands back at critique (proposer_model is no longer empty), then Gate 0
# fires again on the new draft, then "accepted" reaches Apply.
$RC state set --store teststore --name feat-next acceptance revise
check_out "next: human requests changes -> propose (restart)" "action: propose" $N
check_out "next: revise restarts propose at deep" "tier: deep" $N
check_out "next: revise sets phase back to proposed" "set_phase: proposed" $N
$RC state set --store teststore --name feat-next phase proposed acceptance "" last_critique_result "" propose_rounds 0
$RC session append --store teststore --name feat-next role worker phase proposed tier deep model claude-opus-5-plain transcript_id p3
check_out "next: restarted draft exists -> critique again" "action: critique" $N
$RC state set --store teststore --name feat-next last_critique_result clean
check_out "next: second round critique clean -> gate0 again" "action: gate0" $N
$RC state set --store teststore --name feat-next phase awaiting-acceptance acceptance accepted
check_out "next: human accepts -> apply" "action: apply" $N
check_out "next: accept sets phase applying" "set_phase: applying" $N
$RC state set --store teststore --name feat-next phase applying acceptance ""
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
check_out "next: verify model is the tier above the implementer" "model: claude-opus-5-custom" $N
check_out "next: verify of a standard implementer runs at deep" "tier: deep" $N
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
check_out "next: verified clean -> tasks-open" "action: tasks-open" $N
check_out "next: verified clean sets phase verified" "set_phase: verified" $N

# verified: manual_tasks_open gates archive
$RC state set --store teststore --name feat-next phase verified manual_tasks_open "" manual_accept ""
check_out "next: verified with manual_tasks_open empty (fresh init) -> tasks-open" "action: tasks-open" $N
out="$($N)"
case "$out" in
  *"set_phase"*) echo "FAIL next: verified empty manual_tasks_open emits no set_phase (got: $out)"; fails=$((fails+1)) ;;
  *) echo "ok   next: verified empty manual_tasks_open emits no set_phase" ;;
esac
sed -i.bak '/^manual_tasks_open:/d' "$STORE/.orchestration/state/feat-next.yaml"; rm -f "$STORE/.orchestration/state/feat-next.yaml.bak"
check_out "next: verified with manual_tasks_open line missing (pre-1.3.0 state) -> tasks-open" "action: tasks-open" $N
$RC state set --store teststore --name feat-next manual_tasks_open 2
check_out "next: verified with manual_tasks_open 2 -> gate2-manual" "action: gate2-manual" $N
check_out "next: gate2-manual reason mentions the verify report" "verify report" $N
$RC state set --store teststore --name feat-next manual_accept "accepted:"
check_out "next: manual_accept 'accepted:' with no names errors" "names no requirements" bash -c "$N 2>&1; true"
$RC state set --store teststore --name feat-next manual_accept "accepted:R1"
check_out "next: manual_accept naming requirements -> archive" "action: archive" $N
$RC state set --store teststore --name feat-next manual_tasks_open 2 manual_accept yes
check_out "next: manual_accept not empty or accepted:* errors" "unknown manual_accept" bash -c "$N 2>&1; true"
$RC state set --store teststore --name feat-next manual_tasks_open 0 manual_accept ""
check_out "next: manual_tasks_open 0 -> archive" "action: archive" $N
check_out "next: archive reason says --yes allowed because the count is 0" "recorded manual_tasks_open count is 0" $N
$RC state set --store teststore --name feat-next manual_accept "accepted:R1"
$RC state set --store teststore --name feat-next phase archived
check_out "next: archived -> merge-lane" "action: merge-lane" $N
$RC state set --store teststore --name feat-next phase ready-to-merge
check_out "next: ready-to-merge -> gate2" "action: gate2" $N
check_out "next: ready-to-merge gate2 names accepted unverified requirements" "R1" $N
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

# light lifecycle: standard-tier drafting, deep critic (unchanged tier
# ladder rule), no sweep round; everything else matches full
L="$RC next --store teststore --name feat-light"
$RC state init --store teststore --name feat-light
$RC state set --store teststore --name feat-light lifecycle light
check_out "next: light fresh change -> propose at standard" "action: propose" $L
check_out "next: light propose tier is standard" "tier: standard" $L
$RC session append --store teststore --name feat-light role worker phase proposed tier standard model claude-sonnet-5 transcript_id lp1
check_out "next: light draft exists -> critique" "action: critique" $L
check_out "next: light critique of a standard draft runs at deep" "tier: deep" $L
$RC state set --store teststore --name feat-light last_critique_result blocking:2
check_out "next: light blocking critique -> revise at standard" "action: revise" $L
check_out "next: light revise tier is standard" "tier: standard" $L
$RC state set --store teststore --name feat-light last_critique_result clean propose_rounds 0
check_out "next: light clean critique -> gate0" "action: gate0" $L
$RC state set --store teststore --name feat-light phase awaiting-acceptance acceptance revise
check_out "next: light gate0 revise restarts propose at standard" "action: propose" $L
check_out "next: light gate0 revise tier is standard" "tier: standard" $L
$RC state set --store teststore --name feat-light phase checking last_gate_result green last_verify_result warnings:2
check_out "next: light green warnings -> tasks-open (sweep skipped)" "action: tasks-open" $L
check_out "next: light tasks-open sets phase verified" "set_phase: verified" $L
$RC state set --store teststore --name feat-light manual_tasks_open 0 phase ready-to-merge
check_out "next: light ready-to-merge gate2 mentions the unswept verify warnings" "unswept Verify warnings" $L
$RC state set --store teststore --name feat-light phase checking manual_tasks_open "" manual_accept ""
$RC state set --store teststore --name feat-light lifecycle full
check_out "next: the same state under full lifecycle -> sweep" "action: sweep" $L

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

# trunk preflight: gate_full against a detached worktree of trunk_ref,
# cleaned up whether green or red, never touching any change's state
before_tree="$(grep '^gate_tree:' "$STORE/.orchestration/state/feat-a.yaml")"
check_out "gate run --trunk green runs gate_full in a trunk-preflight worktree" "FULL-OK in $STORE/.orchestration/workspaces/trunk-preflight." $RC gate run --store teststore --project "$PROJECT" --mode full --trunk
check "gate run --trunk green leaves no trunk-preflight worktree behind" bash -c "! git -C '$PROJECT' worktree list | grep -q trunk-preflight"
check "gate run --trunk green leaves a change's gate_tree unchanged" test "$(grep '^gate_tree:' "$STORE/.orchestration/state/feat-a.yaml")" = "$before_tree"

# red trunk: a second store whose gate_full fails
mkdir -p "$TMP/store2/openspec"
cat >> "$OPENSPEC_STORE_REGISTRY" <<EOF
  teststore2:
    local_path: $TMP/store2
EOF
cat > "$TMP/store2/openspec/config.yaml" <<'EOF'
orchestration:
  concurrency: 1
  gate_quick: "echo QUICK-OK in $PWD"
  gate_full: "exit 1"
EOF
check_out "gate run --trunk red names the trunk as red" "is red" bash -c "$RC gate run --store teststore2 --project '$PROJECT' --mode full --trunk 2>&1; true"
check "gate run --trunk red exits non-zero" bash -c "! $RC gate run --store teststore2 --project '$PROJECT' --mode full --trunk >/dev/null 2>&1"
check "gate run --trunk red leaves no trunk-preflight worktree behind" bash -c "! git -C '$PROJECT' worktree list | grep -q trunk-preflight"

# tasks open: unchecked tasks.md lines, recorded as manual_tasks_open
$RC state init --store teststore --name feat-tasks
mkdir -p "$STORE/openspec/changes/feat-tasks"
cat > "$STORE/openspec/changes/feat-tasks/tasks.md" <<'EOF'
# Tasks
- [ ] 1.1 do thing
- [x] 1.2 done thing
- [ ] 1.3 another thing
EOF
check_out "tasks open prints the first unchecked line" "1.1 do thing" $RC tasks open --store teststore --name feat-tasks
check_out "tasks open prints the second unchecked line" "1.3 another thing" $RC tasks open --store teststore --name feat-tasks
$RC tasks open --store teststore --name feat-tasks >/dev/null
check_out "tasks open records the count" "manual_tasks_open: 2" $RC state get --store teststore --name feat-tasks

# `- [ ]` appearing mid-line (a checked task's own prose, or an unrelated
# bullet quoting the marker) must not be counted as an open task
$RC state init --store teststore --name feat-tasks-prose
mkdir -p "$STORE/openspec/changes/feat-tasks-prose"
cat > "$STORE/openspec/changes/feat-tasks-prose/tasks.md" <<'EOF'
# Tasks
- [x] 1.1 fix the `- [ ]` matching so checked lines aren't counted
- [ ] 1.2 add a tasks.md with two `- [ ]` lines for the test
EOF
out="$($RC tasks open --store teststore --name feat-tasks-prose)"
case "$out" in
  *"1.1"*) echo "FAIL tasks open counted a checked line containing '- [ ]' mid-line (got: $out)"; fails=$((fails+1)) ;;
  *) echo "ok   tasks open does not count a checked line containing '- [ ]' mid-line" ;;
esac
$RC tasks open --store teststore --name feat-tasks-prose >/dev/null
check_out "tasks open records 1 when only one real task line is unchecked" "manual_tasks_open: 1" $RC state get --store teststore --name feat-tasks-prose

mkdir -p "$STORE/openspec/changes/feat-allchecked"
cat > "$STORE/openspec/changes/feat-allchecked/tasks.md" <<'EOF'
- [x] 1.1 done
- [x] 1.2 done too
EOF
$RC state init --store teststore --name feat-allchecked
$RC tasks open --store teststore --name feat-allchecked >/dev/null
check_out "tasks open with every task checked records 0" "manual_tasks_open: 0" $RC state get --store teststore --name feat-allchecked

# a worktree copy of tasks.md wins over the store's own copy; done against
# "localstore" (local_path IS the project — SKILL.md Step 1), since in
# external mode (teststore) a project with its own openspec/ folder is
# refused outright by guard_project_openspec
mkdir -p "$PROJECT/openspec/changes/feat-wtask"
cat > "$PROJECT/openspec/changes/feat-wtask/tasks.md" <<'EOF'
- [ ] 9.1 store task
EOF
git -C "$PROJECT" add -A && git -C "$PROJECT" commit -qm "add feat-wtask tasks"
$RC workspace create --store localstore --project "$PROJECT" --name feat-wtask >/dev/null 2>&1
wtdir="$PROJECT/.orchestration/workspaces/feat-wtask"
cat > "$wtdir/openspec/changes/feat-wtask/tasks.md" <<'EOF'
- [ ] 2.1 worktree task
EOF
check_out "tasks open prefers the change's worktree copy over the store's" "worktree task" $RC tasks open --store localstore --name feat-wtask
check_out "tasks open records the worktree copy's count, not the store's" "manual_tasks_open: 1" $RC state get --store localstore --name feat-wtask
$RC workspace remove --store localstore --project "$PROJECT" --name feat-wtask
git -C "$PROJECT" rm -rq openspec/changes/feat-wtask >/dev/null 2>&1
git -C "$PROJECT" commit -qm "remove feat-wtask tasks" >/dev/null 2>&1
rmdir "$PROJECT/openspec" 2>/dev/null || rm -rf "$PROJECT/openspec"

# no change directory anywhere -> error, manual_tasks_open left untouched
$RC state init --store teststore --name feat-notasks
check_out "tasks open errors when no change directory exists anywhere" "no change directory found" bash -c "$RC tasks open --store teststore --name feat-notasks 2>&1; true"
check_out "tasks open writes nothing when no change directory exists" 'manual_tasks_open: ""' $RC state get --store teststore --name feat-notasks

# change directory exists but has no tasks.md (e.g. a triage bugfix)
mkdir -p "$STORE/openspec/changes/feat-notasksmd"
$RC state init --store teststore --name feat-notasksmd
check_out "tasks open without tasks.md reports it" "no tasks.md for feat-notasksmd" $RC tasks open --store teststore --name feat-notasksmd
check_out "tasks open without tasks.md records 0" "manual_tasks_open: 0" $RC state get --store teststore --name feat-notasksmd

echo
[ "$fails" -eq 0 ] && echo "all tests passed" || { echo "$fails test(s) failed"; exit 1; }
