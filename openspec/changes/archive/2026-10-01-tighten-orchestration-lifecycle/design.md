# Design

## Decisions

### D1. `gate run --mode full --trunk` runs in a temporary detached worktree of the trunk ref

- Ref: `trunk_ref <project>` (new, `scripts/lib.sh`), extracted unchanged from `cmd_merge_lane_run`: `origin/<trunk>` if that remote ref exists, else local trunk; trunk = `origin/HEAD`, else `main`, else `master`; neither → existing "cannot determine trunk" error. Merge-lane calls the same function, so preflight and merge lane test the same ref. No fetch (merge-lane does not fetch either).
- Location: `mktemp -d` under `<store>/.orchestration/workspaces/trunk-preflight.XXXXXX` (already store-git-ignored via `ensure_workspace_ignored`), `git -C <project> worktree add --detach <tmp> <ref>`, run `gate_full` there, `git worktree remove --force` on EXIT trap (green or red). Exit status = gate's; on red, last stderr line `trunk <ref> is red under gate_full: ...`.
- Rejected: running in the project's main checkout — it may be dirty or on a non-trunk branch, and "never run a gate in the main checkout" is an existing rule. Rejected: a fixed path — two concurrent preflights would collide.
- `--name` not required: no change exists yet. `gate_tree` not written: it belongs to a change's state and means "this change's tree passed".
- `--mode` still required; `--trunk` with `quick` works but only `full` is documented. Unconfigured `gate_full` → the existing "no orchestration.gate_full configured" error, which Step 0 treats as a stop like red.
- Placement: Step 0 check 4 needs the store config, so it runs after Step 2 (not with checks 1–3), before `slot acquire`. Step 0 text says so. "Only when all three pass" → checks 1–3 gate Step 1; check 4 gates opening any change.

### D2. Manual tasks: `tasks open` records the count; `gate2-manual` fires at `verified`, before archive

- Data source: `run-change tasks open` resolves the change directory in order: `<worktree>/openspec/changes/<name>/`, `<worktree>/openspec/changes/archive/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-<name>/` (the CLI's date-prefixed archive name; a bare `*-<name>` glob would also match a different change whose name ends in `-<name>`; more than one match is an error), then the same two under `store_path` (worktree first because in local mode the branch's artifacts live in the worktree; external mode has none there). Prints each unchecked line, writes `manual_tasks_open: <n>` itself (`0` when none) (same pattern as `gate run` writing `gate_tree`). No change directory in any location → non-zero, nothing written. Directory found but no tasks.md (a triage bugfix skips planning artifacts) → prints `no tasks.md for <name>`, writes `manual_tasks_open: 0`, exits 0. Otherwise a change with no tasks.md would loop forever between `tasks-open` and `verified`.
- Rejected: orchestrator counts and writes the field — hand bookkeeping is exactly what failed. Rejected: `next_action` reads tasks.md — breaks its "state file + session log only" contract.
- Placement: at `verified`, not `ready-to-merge`. On a non-TTY, `openspec archive` (1.13.1) without `--yes` refuses whenever it would prompt: over unchecked tasks, and also with every task checked whenever a delta spec updates (only `--skip-specs` changes skip the prompt). So the orchestrator must pass `--yes` for any normal change. The flag can't be the guard; the guard is the engine's recorded count. The block has to sit before archive; Gate 2 itself is unchanged and still fires after merge-lane. Rejected: reorder to merge-lane → Gate 2 → archive — the archive commit (local mode) would then land after the last gate.
- New action `tasks-open` (`set_phase: verified`, tier none) replaces today's `archive` emit at `checking`/green/`clean` (and the light green/`warnings:*` emit): run `tasks open`, then record `verified`. `archive` is emitted only from `verified`, so the count always exists before archive is considered. Rejected: adding a reason sentence to the existing `archive` emit, because an orchestrator following the action would archive before `verified` is ever recorded.
- `--yes` rule: pass it only when phase is `verified` and either `manual_tasks_open: 0` (recorded by `tasks open` on the way in) or `manual_accept` is set; never otherwise. The `archive` reason states which condition holds.
- Distinct action `gate2-manual` instead of a list on `gate2`: it fires at a different phase, and tests/run.sh can assert it by action name. Its reason says to show the open-task list together with the verify report, so the human can judge each tick without waiting for Gate 2's material.
- Answers: tick → orchestrator edits `- [ ]`→`- [x]` for each task the human confirms done, reruns `tasks open`; partial ticks leave `gate2-manual`. Accept → `manual_accept: accepted:<req>;<req>`; `accepted:` with an empty list is an error in `next_action`.
- "Never counted" must differ from "counted, none open". So `state init` writes `manual_tasks_open: ""`, and `tasks open` always writes an explicit number, `0` included. At `verified`, empty → `tasks-open` with no `set_phase` (reason: count first); only a literal `0` reaches `archive`. A pre-1.3.0 state file (no field) and a hand-recorded `phase verified` therefore both get `tasks-open`, never `archive --yes`. Rejected: defaulting empty to 0 as `fix_attempts`/`propose_rounds` do — a skipped count would then read as "none open" and allow `--yes` over unchecked tasks.
- `manual_accept` is not cleared by later fix rounds: a code fix does not verify a manual requirement.

### D3. `lifecycle: full|light`

`next_action` reads `lifecycle` (empty → `full`, so older state files keep working; other values → error). `ptier` = `deep` (full) / `standard` (light), used everywhere `deep` was hard-coded for the proposer: `proposed` with no draft, `revise`, and `awaiting-acceptance`/`revise`. Outputs for light:

| state | action | tier |
|---|---|---|
| `proposed`, no draft | `propose` | `standard` |
| `proposed`, draft logged at `standard` | `critique` | `deep` (existing `checker_pick`) |
| `proposed`, `blocking:<n>` | `revise` | `standard` |
| critique pass / `awaiting-acceptance` | `gate0` | unchanged |
| `awaiting-acceptance`, `revise` | `propose` | `standard` |
| `accepted`, `applying`, `check`, fix rounds, Verify | unchanged | unchanged |
| `checking`, green, `warnings:<m>` | `tasks-open`, `set_phase: verified` | none; reason: sweep skipped in light, list warnings at Gate 2 |

- Item 5's "skip the sweep when Verify is clean": `clean` already skips the sweep in both lifecycles (now via `tasks-open`), so the only change is that light treats `warnings:<m>` like `clean`. Light does not change Verify's tier.
- "Propose+apply as one dispatch": Gate 0 has to sit between draft and code, so it cannot be literally one uninterrupted dispatch. In light, after accept, Apply goes to the same `standard` worker that drafted (resumed transcript) when the host can resume an agent, else a fresh `standard` worker. The savings are the shared context and a `standard` proposer; `next` output is identical either way. Rejected: a `propose-apply` action that crosses Gate 0 — it would let code exist before accept.
- Who sets it: triage, on the bugfix change it opens (`state set ... lifecycle light`, which auto-inits); the human, via Gate 0's third option. Never the orchestrator for any other change. Not enforceable in code (`state set` cannot tell who is calling), so this rule lives in the doc.
- A Gate-0 pick comes after a `deep` draft and a `max` critique, so for that change light only removes the sweep. The resume lists light's full definition and marks which parts already ran.

### D4. Checker input contract lives in `checker_inputs` and goes out through `model critic|verify`

- `checker_inputs <critic|verify> <store> <name>` (lib.sh) prints `input:` lines and reads no file. It substitutes the actual store and name, but names the field rather than resolving it, which keeps `model critic --name <initiative>` working since an initiative has no change state file. Critic = request, draft delta spec (+ design.md), seam list (`input: seam list — state get --store $STORE --name $NAME, field seams`, with the values filled in), prior critique report; Verify = proposal + delta spec, seam list, branch diff, prior verify report; both = "read other files only to confirm a seam is real or a dependency claim is true; do not explore the codebase; never the generator's transcript".
- `cmd_model_critic|verify` print the bare id on line 1, then those lines. tests/run.sh `check_out` uses substring matching, so existing cases pass. `next_action` gets models through `verify_model`/`critic_model` (`cut -d' ' -f2` on `*_pick`), not the CLI, so `model:`/`also_model:` stay single values. Callers that want only the id use `| head -n1`, which the doc states.
- Rejected: a `--contract` flag — the default output is what gets pasted into the dispatch prompt, and an opt-in flag gets left off. Rejected: printing to stderr — `$(...)` would drop it.

### D5. Doc placement

SKILL.md Step 0 check 4 + "Only when checks 1–3 pass … check 4 before any change opens"; AUTONOMOUS-ORCHESTRATION.md Phases step 1 runs the preflight before `slot acquire`. Step 2's "Step 0 check 4 of SKILL.md" (git init) is wrong today — git init is check 3 — and gets fixed in the same edit.
