# Spec Delta

## Purpose

Lifecycle rules the engine enforces in `scripts/run-change` / `next_action` and states in SKILL.md / AUTONOMOUS-ORCHESTRATION.md, so a change cannot merge unverified work, trunk failures don't turn into mid-run detours, and small fixes don't carry full-weight ceremony.

## ADDED Requirements

### Requirement: Trunk preflight
`scripts/run-change gate run --store <slug> --project <path> --mode full --trunk` SHALL run `orchestration.gate_full` in a temporary detached worktree of the trunk ref (resolved as the merge lane resolves it), SHALL remove that worktree whether the gate passes or fails, SHALL NOT require `--name`, and SHALL NOT write any state file. It SHALL exit non-zero when the gate fails. The orchestrator SHALL run it before `slot acquire`; on failure it SHALL stop, show the human the output, and open no change.

#### Scenario: Green trunk
- **WHEN** `gate run --mode full --trunk` runs against a project whose `gate_full` passes
- **THEN** it exits 0, the gate output shows a working directory under `<store>/.orchestration/workspaces/trunk-preflight.`, no such worktree remains in `git worktree list`, and no state file changes

#### Scenario: Red trunk
- **WHEN** the store's `gate_full` fails on trunk
- **THEN** the command exits non-zero with output naming the trunk ref as red, and no preflight worktree remains

#### Scenario: Preflight precedes any change
- **WHEN** a reader follows SKILL.md Step 0 and AUTONOMOUS-ORCHESTRATION.md Phases step 1
- **THEN** the trunk preflight is check 4 and runs before `slot acquire` and `workspace create`

### Requirement: Unchecked tasks block archive and merge
`scripts/run-change tasks open --store <slug> --name <change>` SHALL print every unchecked task line of the change's tasks.md and record their count as `manual_tasks_open`, writing `0` explicitly when none are unchecked. State init SHALL write `manual_tasks_open: ""` (not counted). When the full gate is green and `last_verify_result` is `clean` (whether first-pass or after a sweep), or `warnings:<m>` under `light`, `next_action` SHALL return `action: tasks-open` with `set_phase: verified`, and SHALL return `archive` only from phase `verified`. At `verified`, an empty `manual_tasks_open` SHALL return `action: tasks-open` with no `set_phase`; only a recorded `0` SHALL lead to `archive`. At `verified`, `next_action` SHALL return `action: gate2-manual` while `manual_tasks_open` is greater than 0 and `manual_accept` is empty, with a reason that says to show the task list alongside the verify report. The orchestrator SHALL resolve `gate2-manual` only by ticking tasks the human confirms done, or by recording `manual_accept: accepted:<requirement>[;<requirement>...]` naming the unverified requirements, and SHALL NOT offer trying it after merge as an answer. `openspec archive` SHALL be run with `--yes` only at `verified` when `manual_tasks_open: 0` is recorded or `manual_accept` is set, and never otherwise. Gate 2 SHALL list accepted-unverified requirements.

#### Scenario: Clean verify counts tasks before archive
- **WHEN** a change is `checking` with `last_gate_result: green` and `last_verify_result: clean`
- **THEN** `next` returns `action: tasks-open` and `set_phase: verified`, not `archive`

#### Scenario: Count recorded
- **WHEN** the change's tasks.md has two `- [ ]` lines and `tasks open` runs
- **THEN** both lines are printed and the state file holds `manual_tasks_open: 2`

#### Scenario: Open tasks stop the flow
- **WHEN** phase is `verified`, `manual_tasks_open: 2`, `manual_accept: ""`
- **THEN** `next` returns `action: gate2-manual`, and its reason names the verify report

#### Scenario: Human accepts named unverified requirements
- **WHEN** phase is `verified`, `manual_tasks_open: 2`, `manual_accept: accepted:Window fits content`
- **THEN** `next` returns `action: archive`, and `gate2` at `ready-to-merge` names `Window fits content`

#### Scenario: Acceptance without names is refused
- **WHEN** `manual_accept: accepted:` with nothing after the colon
- **THEN** `next` exits non-zero

#### Scenario: No open tasks
- **WHEN** phase is `verified` and `manual_tasks_open: 0`
- **THEN** `next` returns `action: archive`, whose reason says `--yes` is allowed because the recorded count is 0

#### Scenario: Not yet counted
- **WHEN** phase is `verified` and `manual_tasks_open` is empty or absent (a fresh state file, a pre-1.3.0 state file, or `verified` recorded by hand)
- **THEN** `next` returns `action: tasks-open` with no `set_phase`, not `archive`

#### Scenario: Zero written explicitly
- **WHEN** `tasks open` runs on a tasks.md with every task checked
- **THEN** the state file holds `manual_tasks_open: 0`

#### Scenario: Change without tasks.md
- **WHEN** the change directory exists but holds no tasks.md (e.g. a triage bugfix), and `tasks open` runs
- **THEN** it prints `no tasks.md for <name>`, exits 0, and the state file holds `manual_tasks_open: 0`; it exits non-zero only when no change directory is found

### Requirement: Lifecycle field
State init SHALL write `lifecycle: full`; a missing value SHALL read as `full`; any value other than `full` or `light` SHALL make `next` exit non-zero. Under `light`, `next_action` SHALL return `propose` and `revise` at tier `standard`, the critic SHALL resolve one tier above the logged proposer, and a green gate with `last_verify_result: warnings:<m>` SHALL return `tasks-open` instead of `sweep`. Every other output SHALL match `full`, including `gate0`. Under `light`, Apply SHALL resume the proposer's worker when the host supports resuming an agent, and otherwise dispatch a fresh `standard` worker; `next` output is the same either way. Triage sets `light` on the bugfix change it opens, and the human sets it through Gate 0's light option. The orchestrator never picks it for any other change.

#### Scenario: Light drafts at standard
- **WHEN** a change with `lifecycle: light` is at `proposed` with no draft
- **THEN** `next` returns `action: propose` and `tier: standard`

#### Scenario: Light critic one tier above
- **WHEN** a light change has a `proposed` session entry at `tier standard`
- **THEN** `next` returns `action: critique` and `tier: deep`

#### Scenario: Light skips the sweep
- **WHEN** a light change is `checking` with `last_gate_result: green`, `last_verify_result: warnings:2`
- **THEN** `next` returns `action: tasks-open`, while the same state under `full` returns `action: sweep`

#### Scenario: Light keeps Gate 0
- **WHEN** a light change's critique is `clean`
- **THEN** `next` returns `action: gate0`

#### Scenario: Doc states light Apply and who sets light
- **WHEN** a reader checks AUTONOMOUS-ORCHESTRATION.md Phases step 4, "Bugs found mid-run", and Gate 0
- **THEN** step 4 says light Apply resumes the proposer's worker when the host can, else a fresh `standard` worker; triage and Gate 0's light option are named as the only two ways `light` gets set; and the orchestrator never picks `light` itself

### Requirement: Gate 0 light option
For a proposal Propose classified as a small, non-breaking fix, Gate 0's structured choice SHALL offer Accept, Accept — light lifecycle, and Request changes. The resume SHALL state what light changes (standard-tier drafting, deep-tier critic, no sweep round, marking which already ran) and what it never skips (Gate 0, the full gate incl. dead-code pass, Verify, the manual-task block, Gate 2). Plain Accept SHALL keep `lifecycle: full`.

#### Scenario: Gate 0 reason names the option
- **WHEN** `next` returns `gate0` at `awaiting-acceptance`
- **THEN** its reason says that if Propose classified the change as a fast-path fix, the human is also offered "Accept — light lifecycle"

### Requirement: Checker input contract
`model critic` and `model verify` SHALL print the bare model id on the first line, followed by static `input:` lines (they read no state file; the seam list is named as the `seams` field, not resolved) listing the checker's inputs (critic: request, draft, seam list, prior report; Verify: proposal, seam list, branch diff, prior report) and the rule that other files are read only to confirm a seam or a dependency claim, never to explore the codebase.

#### Scenario: Contract emitted
- **WHEN** `model verify` runs for a change with history
- **THEN** line 1 is exactly the checker model id and later lines include `input:` and `seam`

#### Scenario: Contract for an initiative critic
- **WHEN** `model critic --name <initiative>` runs for an initiative that has a `proposed` session entry and no change state file
- **THEN** it prints the model id followed by the `input:` lines

### Requirement: Checker standards for unverifiable mechanisms
The critic's Testable standard SHALL apply to the proposed implementation approach: one the critic cannot see how to verify, or sees a concrete way to fail, SHALL be `blocking`, with the fix as its remedy when the critic can name it. Verify SHALL report a requirement left as a manual task when a programmatic proxy exists as `spec`.

#### Scenario: Doc states the rules
- **WHEN** a reader checks AUTONOMOUS-ORCHESTRATION.md Phases steps 3 and 6
- **THEN** the Testable standard names the mechanism rule as `blocking`, and Verify names the manual-task-with-proxy rule as `spec`

### Requirement: Build-once fixtures and quick-gate budget
Apply SHALL build seconds-long test artifacts once per test run into a shared fixture; Verify SHALL report per-test or per-file rebuilds as a warning. `gate_quick` SHALL stay under about 30 s; slow checks belong in `gate_full`.

#### Scenario: Doc states the rules
- **WHEN** a reader checks the Hard rule section and Phases step 4 of AUTONOMOUS-ORCHESTRATION.md, and SKILL.md Step 3
- **THEN** the build-once rule and its Verify-warning severity appear in both doc sections, and SKILL.md states the ~30 s `gate_quick` budget
