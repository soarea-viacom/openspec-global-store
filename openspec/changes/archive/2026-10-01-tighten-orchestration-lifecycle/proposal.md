# Proposal

## Why

The tetris-game run (3 changes, ~83 min, 14 dispatches) shipped a defect to trunk and spent ~30 min on ceremony:

- A critic named the window-sizing fragility and its fix but filed it advisory; the requirement was a manual task, so Verify graded nothing; `openspec archive --yes` ran over 3 unchecked tasks and Gate 2 merged it.
- A pre-existing red `npx knip` on trunk surfaced mid-change and became a full max-tier lifecycle for an 8-line config fix.
- Four max-tier critiques took 250–330 s each; checkers re-read the whole codebase (~60–70k tokens) instead of seam files + spec + diff.
- The suite compiled a binary twice per run; the gate ran ~10 times.

## What Changes

1. **Trunk preflight.** New `scripts/run-change gate run --store <slug> --project <path> --mode full --trunk`: runs `gate_full` in a temporary detached worktree of the trunk ref (same resolution as merge-lane, extracted to `trunk_ref` in `scripts/lib.sh`), removes it, never writes state. SKILL.md Step 0 gains check 4 (runs after Step 2 resolves the store, before `slot acquire`); AUTONOMOUS-ORCHESTRATION.md Phases step 1 runs it before slot acquire. Red → stop, show output, open no change.
2. **Manual tasks block merge.** New `scripts/run-change tasks open --store <slug> --name <change>` lists unchecked `- [ ]` lines of the change's tasks.md and records `manual_tasks_open: <n>`. A green+`clean` check (and light green+`warnings:<m>`) now returns new action `tasks-open` (`set_phase: verified`) instead of `archive`; archive runs only from `verified`. At `verified`, `next_action` returns new action `gate2-manual` while `manual_tasks_open > 0` and `manual_accept` is empty; its reason says to show the task list together with the verify report. The human ticks each task (orchestrator edits tasks.md, reruns `tasks open`) or names the unverified requirements (`manual_accept: accepted:<req>;<req>`). `openspec archive --yes` (which the CLI needs on a non-TTY whenever specs update) is passed only when `manual_tasks_open: 0` was recorded at `verified`, or when `manual_accept` is set. Gate 2 lists accepted-unverified requirements. Cost: a change with unchecked tasks gets one extra human stop, before Archive. AUTONOMOUS-ORCHESTRATION.md Phases steps 6–9 and the action list updated.
3. **Testable = mechanism.** AUTONOMOUS-ORCHESTRATION.md Phases step 3 (Testable standard) and Checker loops (Severity): an approach the critic cannot see how to verify, or sees a concrete way to fail, is `blocking`; a nameable fix is that finding's remedy. Phases step 6: a requirement left as a manual task when a programmatic proxy exists is a `spec` finding.
4. **Build once.** AUTONOMOUS-ORCHESTRATION.md "Hard rule: written for agents" and Phases step 4: seconds-long artifacts are built once per test run into a shared fixture; per-test/per-file rebuilds are a Verify warning. SKILL.md Step 3 Phase 3: `gate_quick` stays under ~30 s; slow work lives in `gate_full`.
5. **Light lifecycle.** New state field `lifecycle: full|light` (state init: `full`; absent reads as `full`). In `next_action`, `light` drafts/revises at `standard` (critic resolves to `deep` via the existing one-tier-above rule) and turns green+`warnings:<m>` into `archive` instead of `sweep`. Gate 0 and everything else unchanged. Triage sets `light` on the bugfix change it opens. AUTONOMOUS-ORCHESTRATION.md "Bugs found mid-run", Phases steps 3–4, Checker loops (Pass line), Model/effort routing.
6. **Checker input contract.** New `checker_inputs critic|verify` in `scripts/lib.sh`; `model critic` / `model verify` print the bare model id on line 1, then the contract as `input:` lines. AUTONOMOUS-ORCHESTRATION.md Phases steps 3 and 6, Isolation (Context), Model/effort routing state the same contract.
7. **Gate 0 light option.** SKILL.md Step 3 fast path and "Autonomous only" Gate 0; AUTONOMOUS-ORCHESTRATION.md Gate 0: for a fast-path proposal the structured choice adds "Accept — light lifecycle" (`state set ... lifecycle light acceptance accepted`). The resume states what light changes and what it never skips. Never picked on the human's behalf. `next` gate0 reason names the option.

Also: AUTONOMOUS-ORCHESTRATION.md Phases step 2 cites "Step 0 check 4" for git init; it is check 3 — corrected while renumbering.

## Capabilities

### New Capabilities
- `orchestration-lifecycle`: engine-enforced lifecycle rules — trunk preflight, manual-task block, lifecycle field, checker input contract, checker standards, build-once fixtures, quick-gate budget.

### Modified Capabilities
(none)

## Impact

- Files: `scripts/lib.sh`, `scripts/run-change`, `tests/run.sh`, `SKILL.md`, `AUTONOMOUS-ORCHESTRATION.md`, `CONTEXT.md`, `README.md`, `releases.json` (1.3.0).
- Behavior: new commands `gate run --trunk`, `tasks open`; new actions `tasks-open`, `gate2-manual`; new state fields `lifecycle`, `manual_tasks_open`, `manual_accept`; `model critic|verify` output gains `input:` lines after line 1; light changes draft at `standard` and skip the sweep.
- Not changed: Gate 0 stays mandatory with no round cap and fires for light changes; `FIX_CAP`, `PROPOSE_CAP`, `ADVISOR_CAP`; fix-round tier ladder; `checker_pick`; `gate_tree` semantics; merge-lane; full-lifecycle outputs of `next_action` other than the `tasks-open` and `gate2-manual` branches and reason text.
- Installed copy `~/.claude/skills/openspec-orchestrator/SKILL.md` is not written; the human applies the diff.
