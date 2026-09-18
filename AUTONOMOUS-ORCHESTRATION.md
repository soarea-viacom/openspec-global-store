# Autonomous change orchestration

Rule document for running OpenSpec changes autonomously instead of via three
manually-triggered `/sdd:propose` / `/sdd:apply` / `/sdd:archive` calls.
Read this before starting a change if the human asked for autonomous
execution (e.g. "just get this done", "run it end to end") rather than
step-by-step review. The plain manual mode in [SKILL.md](SKILL.md) stays
available and is the default when the human wants to review after each
phase.

The reader of this doc, the state files, and the scripts it drives is
another agent in a later session, not a human. Comments and state exist to
let that agent act correctly, not to narrate — see §8.

## Repo boundary (read this first)

This repo is the shared *engine*: this doc, `scripts/`, and the phase
definitions in [SKILL.md](SKILL.md). It ships once and applies to every
target project the `openspec-orchestrator` skill routes to.

A "change" always has two locations, never one:

- **Code and git history** live in the **target project's own repo** — the
  isolated workspace (branch `change/<name>` + worktree) is created there,
  never in this store.
- **Spec artifacts and orchestration state** live in that project's
  **store** — the directory the `openspec-orchestrator` skill resolved via
  `--store <slug>` (slug recomputed from `git remote get-url origin`, kebab-
  cased; see that skill for the exact algorithm — there is no persisted
  mapping file, so always recompute, never cache a slug across sessions).

Orchestration config (`orchestration.concurrency`, `gate_quick`,
`gate_full`) lives ONLY in the store's `openspec/config.yaml` — single
rule: a target project must not contain an `openspec/` folder at all, and
`scripts/run-change` refuses any project that does.

Runtime state (slots, merge lock, phase files, initiatives) lives under
`<store>/.orchestration/`, scoped to that one store/project. The concurrency
cap and merge lane in this doc are **per target project**, not global — two
changes against two different projects never contend for the same slot or
lock.

The `openspec` CLI has no built-in locking, concurrency, or phase-state
tracking (confirmed against v1.13.1 — `store setup` just creates a plain
git-backed folder). Everything below is userland, built from plain files.

## Phases

```
proposed → applying → checking → verified → archived → ready-to-merge → merged
```

plus `blocked` (see bug triage below). State lives in
`<store>/.orchestration/state/<change>.yaml`:
`phase`, `propose_rounds`, `last_critique_result`, `fix_attempts`,
`last_gate_result`, `last_verify_result`, `initiative`, `depends_on`, `seams`, `follows`, `supersedes`, `blocked_on`.
Session history is a separate append-only log, one line per
orchestrator/worker run against this change, at
`<store>/.orchestration/state/<change>.sessions.log` (see **Session log**
in CONTEXT.md) — `role: orchestrator|worker|resume`, `phase`, `gates_hit`,
`transcript_id`, `model`, `tier`, written via `scripts/run-change session
append`, never edited after the fact.

1. **Slot** — `scripts/run-change slot acquire --store <slug> --project
   <path>` before
   starting; blocks/queues if the project's concurrency cap (N, from the
   store's `openspec/config.yaml` `orchestration.concurrency`, default 1)
   is full. A change `blocked` on a dependency releases its slot while
   waiting — a dependency can never deadlock the cap.
2. **Workspace** — `scripts/run-change workspace create --store <slug>
   --project <path> --name <name>`: branch `change/<name>` off the project's trunk,
   worktree at a workspace root under the project, dependencies synced.
   Never dispatch work against the project's main checkout.
3. **Propose** — always runs at the `deep` tier (see Model/effort routing
   below), regardless of how small the change looks: a mistake here is the
   most expensive one, because every later phase inherits it. Draft the
   delta spec via the normal `openspec-orchestrator` propose phase, scoped
   to the workspace, `--store <slug>`. Before drafting prose, sketch the
   **seams** the change touches:
   existing seams preferred over new ones, fewest possible (one is ideal),
   each seam named with the files/modules behind it. Write this seam list
   to the change's state (`scripts/run-change state set ... seams
   "<seam>=<file>,<file>;<seam>=<file>"` — see **Seam list** in
   CONTEXT.md), not just narrated in the delta spec prose — it is the input
   dispatch groups are cut along in step 4 and what the disjoint-files
   check reads, not a separate exercise redone at Apply time. Log the
   session entry with `phase proposed` before the critique below runs.

   **Critique** — nothing downstream can catch a wrong spec, because Apply
   builds to it and Verify grades against it. So before the spec is
   committed, a critic with a fresh context and a model distinct from the
   proposer's (`scripts/run-change model critic --store <slug> --name
   <name>`) reads the originating request, the draft delta spec, the seam
   list, and the codebase — never the proposer's transcript — and judges
   the draft on five standards:
   - **Fidelity**: every part of the request is covered, nothing beyond it
     is added.
   - **Seams are real**: each named file exists, is where that behavior
     actually lives, and the list is complete — a missing file here breaks
     the disjoint-files check silently.
   - **Testable**: each requirement has a scenario a Verify checker could
     grade the code against without guessing.
   - **Right size**: smallest change that satisfies the request; flags
     when it should instead be an initiative (see below) or is padded.
   - **Written for agents**: the hard rule at the end of this doc.

   The critic writes a **critique report** to
   `<store>/.orchestration/state/<name>.critique.md` (overwritten each
   round) and sets `last_critique_result` per the **Checker loops** rules
   below — severity, pass line, convergence, and budget are defined once
   there:
   - `clean` or `warnings:<m>` — pass. Warnings are fixed in place at the
     mechanical tier, no re-critique. Commit the spec and seam list on the
     branch, continue.
   - `blocking:<n>` — the proposer (same `deep` tier) revises only what the
     findings name, logs another `proposed` entry, and the critic reruns
     with the prior report. `propose_rounds` counts these, cap 2. Out of
     rounds or not converging → **Gate 1** with the latest report and
     draft: the request is cheaper to clarify now than to build wrong.
   - `request` — the originating request is itself contradictory or too
     ambiguous to draft against. → **Gate 1** immediately.

   This is the one place autonomous mode may ask a human before code
   exists. The same critique, same standards where they apply, runs on
   every other deep-tier artifact — see **Critique beyond the spec** below.
4. **Apply** — implement in dispatch groups, one per seam from the Propose
   step's seam list (see model/effort tiers below). Before fanning groups
   out, run the disjoint-files check below; a change too small to have
   named more than one seam stays a single group. Run the project's *quick*
   gate (lint, type check, last-failed tests — `orchestration.gate_quick`
   command from the store's config) after each group.
5. **Check** — run the project's *full* gate
   (`orchestration.gate_full`, parallelized if the project's test runner
   supports it).
   - Red: a **fix round** (see below). Out of rounds → **Gate 1**: ask the
     human with the failure.
   - Green: continue to verify.
6. **Verify** — a checker with a fresh context and a model distinct from
   whichever one last wrote code for the change (`scripts/run-change model
   verify --store <slug> --name <name>` — see the generator/checker split
   under Model/effort routing) reads the proposal and the branch diff and
   judges whether the code satisfies the proposal. It never sees the
   implementer's transcript. It writes a **verify report** to
   `<store>/.orchestration/state/<name>.verify.md`, overwritten each
   round, and sets `last_verify_result` per the **Checker loops** rules
   below. Every finding names the proposal requirement, the `file:line`,
   what is wrong, what would satisfy it, and a severity; no finding without
   all five.
   - `clean` or `warnings:<m>` — pass. Warnings (human-narrative comments,
     oversized artifacts, the hard rule at the end of this doc) get one
     mechanical-tier sweep and a quick gate, no re-verify, not a round.
     Continue to Archive.
   - `blocking:<n>` — the code falls short of a proposal requirement. The
     report is the input to a **fix round** (below): set `phase: checking`,
     fix, rerun step 5, then re-run Verify. Out of rounds or not converging
     → **Gate 1** with the latest report.
   - `spec` — the proposal itself is wrong, ambiguous, or silent on what the
     code does, so no code change can close the finding. → **Gate 1**
     immediately: the human owns the spec in autonomous mode, and a fix
     round that edits the proposal would be the code grading itself.
7. **Archive** — finalize artifacts (`openspec-orchestrator` archive phase),
   commit on the branch.
8. **Merge lane** — `scripts/run-change merge-lane run --store <slug>
   --project <path> --name <name>`: acquire the project's single
   merge lock, merge current trunk into the branch, rerun the full gate.
   Red → a fix round (same budget). Green → **Gate 2**: ask the human
   with a summary (diffstat, gate log, verify report).
9. **Merged** — on approval, squash-merge into trunk (one commit, with the
   trailers below), remove the workspace, release the slot.

Everything between gates is autonomous. Commits on `change/<name>` never
ask. Squash-merge produces one commit per change on the project's trunk.

## Disjoint-files check

The one rule that gates every concurrency decision in this doc, at either
granularity it applies to:

> Two units of work may run at the same time only if the file lists behind
> their seams don't overlap. If they overlap, run them in dependency/seam
> order instead — never concurrently, and never merge the lists to "make it
> fit."

Seam file lists come from the change's state, not the delta spec prose:
each change's `seams` field (written during Propose, step 3 — see
**Seam list** in CONTEXT.md), read via `scripts/run-change state get
--store <slug> --name <change>`. Nothing infers them after the fact, and
nothing parses the delta spec to reconstruct them. The check applies at
two granularities, same rule, same data source:

- **Within a change**, across its own dispatch groups (step 4): compare
  the `seams` groups pairwise before fanning any group out; a change whose
  `seams` field names only one group never has this decision to make.
- **Across a project**, among in-flight initiative children: compare the
  `seams` field of every child not yet merged before starting a new one
  concurrently, on top of (not instead of) the `depends_on` ordering.

A file list that turns out to be wrong once real implementation starts
(a shared barrel export, config, or type file no seam sketch named) is a
mid-run finding, not a silent merge: fall back to sequential for the
groups/children involved and fix it with `state set ... seams "..."`, the
same command that wrote it.

## Resumability

`scripts/run-change status --store <slug>` discovers state from
`<store>/.orchestration/`, not chat memory. Commit on the branch after every
phase, so an interrupted run loses at most one phase. Re-running with no
arguments resumes each in-flight change from its recorded phase, checking
for uncommitted work first.

## Bugs found mid-run: ownership decides

Classify every red gate or verify finding by where the broken code lives —
this follows from file ownership, not judgement:

- **Inside the current change's scope**: fix in place, counts as a fix
  round. Never split out — a split change would depend on unmerged work.
- **Outside scope and blocking**: open a bugfix change autonomously (same
  lifecycle, lighter — skip full planning artifacts, proposal limited to
  symptom/cause/relations, plus a regression test), add a `depends_on` edge,
  set the current change to `blocked` with `blocked_on`, release its slot.
  The fix branches from trunk; once merged, the blocked change merges trunk
  in and resumes.
- **Outside scope and not blocking**: record a queued sibling with
  `follows: <current>`, no dependency edge; runs when a slot frees. Fixing
  it in place is scope creep.
- **In the change's own planning artifacts**: fix in place. In
  shared/global artifacts: a separate change.
- **After merge**: a new follow-up change, never reopening an archived one.

## Initiatives (complex work split into linked changes)

Split before creating a change when the request touches more than one
independent area, needs more than ~2 dispatch groups / ~8 tasks, or contains
parts that could merge independently. Record an initiative
(`scripts/run-change initiative init|set --store <slug> --name <name>
title ... request ... children a,b,c` →
`<store>/.orchestration/initiatives/<name>.yaml`, plus `critique_rounds`
and `last_critique_result` for its critique loop) instead of inferring the
split later. Per-child `depends_on` lives on each child's own state file.

- A child starts only when its dependencies are merged, up to the
  concurrency cap, and only after the disjoint-files check below clears it
  against every other in-flight child for that project.
- Gate 2 is per child by default. The first Gate 2 of an initiative may
  offer "approve this merge and let remaining green children merge
  autonomously." Gate 1 always asks.
- `scripts/run-change status` shows the initiative tree — critique rounds
  and result, then each child with its phase and blocker, or
  `not-started` if it has no state file yet.
- **Gates are orchestrator-owned.** Whether a child runs as a separate
  resumed session or as a subagent dispatched live by one orchestrator
  session, only the orchestrator talks to the human. A child that hits a
  Gate 1 or Gate 2 condition escalates the finding (phase, gate log,
  diffstat, verify report) up to the orchestrator and stops; it never
  prompts the human itself. This keeps N concurrent children from producing
  N uncoordinated interruptions and preserves the single-voice approval
  flow the gates are built around.

Every lifecycle commit (on the target project) carries trailers: `Change:`,
`Initiative:`, `Depends-On:` (repeated), `Session:` — including the
squash-merge commit, so `git log` in the target project reconstructs
provenance even after the change's own artifacts are archived.

## Checker loops

Both generator/checker pairs — proposer/critic and implementer/Verify —
follow the same four rules. They are what keeps two agents from grading
each other forever.

- **Severity is binary.** Every finding is `blocking` (the output fails
  the standard it is judged against: a requirement the code does not meet,
  a seam that names a wrong file, a part of the request the spec skips) or
  `warning` (the output is correct but violates the hard rule at the end
  of this doc). The checker assigns it; the fixer does not reclassify.
- **Pass is defined up front.** A change passes Verify when the full gate
  is green and the report has zero blocking findings. A draft passes
  critique when the report has zero blocking findings. Warnings never
  block a pass and never start a round: they get one mechanical sweep and
  move on. Without this line a loop spends its whole budget on comment
  style.
- **Budget, and convergence inside it.** Fix rounds cap at 3 per change,
  critique rounds at 2, then Gate 1. But the budget is a ceiling, not a
  target: a round is *converging* only if no finding the prior report
  marked closed reappears, and the blocking count is strictly lower than
  the prior round's. Either failing means the pair is not moving toward
  agreement — gate immediately with both reports, regardless of rounds
  left. Spending the remainder would only produce a third report saying
  the same thing.
- **Unconditional, by design.** The pattern is usually reserved for
  changes worth a senior review. Here it runs on every change, because in
  autonomous mode nobody reads the diff or the spec before Gate 2 — the
  checker *is* the senior review, not an addition to it. Cost is controlled
  by the tier (a `standard` model, one pass when the output is right) and
  by the pass line above, not by skipping the check.

### Critique beyond the spec

Wherever a deep-tier model generates an artifact, a distinct model
critiques it before anything is built on it. The delta spec is one case;
the others:

- **Initiative records** (`<store>/.orchestration/initiatives/<name>.yaml`).
  Standards: the children together cover the request and nothing more;
  `depends_on` is acyclic and every edge is real (the child cannot start
  without it); no two children that could run concurrently share a file
  in their seam lists — a miss here surfaces as a merge conflict several
  hours later; each child is small enough to be a single change. Log the
  author's session entry under the initiative's name (`session append
  --name <initiative> phase proposed`), so `model critic --name
  <initiative>` resolves a distinct model without new machinery. Rounds
  and the last result live on the initiative record (`scripts/run-change
  initiative set --store <slug> --name <initiative> critique_rounds <n>
  last_critique_result <value>`), cap 2, same values as a change's
  critique. The report goes to
  `<store>/.orchestration/initiatives/<name>.critique.md`.
- **Design docs** written at the deep tier during Propose. Same critic,
  logged under the owning change, standards: fidelity to the request,
  every decision names the alternative it rejected and why, nothing the
  spec will not need.

Same fresh-context rule, same report shape (what is wrong, what would
satisfy it, severity), same 2-round cap and convergence test.

## Model/effort routing

Pick a tier per task, not per session:

- `none`: workspace create/remove, running the gate, merge lane, state/
  initiative bookkeeping, commit trailers, archival file moves.
- `mechanical`: lint/format fixes, type-annotation-only fixes, commit
  message drafting, first-round red-gate triage (flake vs lint vs type vs
  logic).
- `standard`: ordinary implementation tasks, tests, verify reports (subject
  to the generator/checker override below — verify's model must differ
  from the implementer's, even if that means a tier it wouldn't otherwise need).
- `deep`: Propose (drafting the delta spec and seam list, every change, not
  just initiative decomposition), design docs, anything touching an
  invariant, fix rounds 2 and 3.

Specify/Plan (Propose) and Execute (Apply) are handled by the tiers above.
The two checkers — Propose's critic and Verify — are different: they
aren't sized by how hard the check is, but by whether they're independent
of whoever produced the thing being checked. A model is a weak
reviewer of its own output, so Verify runs in a fresh context (proposal,
diff, prior report — not the implementer's or fixer's transcript) and
never reuses the implementer's model — `scripts/run-change model verify --store <slug> --name <change>`
resolves `standard`'s model, and if that collides with the model the last
`applying`/`checking` session-history entry recorded, escalates to
`deep`'s model instead. `model critic` does the same against the last
`proposed` entry; since Propose runs at `deep`, the critic normally lands
on `standard`'s model. Use these commands' output for the checker steps,
not `model get --tier standard` directly.

Each tier maps to a concrete model, resolved via `scripts/run-change model
get --store <slug> --tier <tier>` — the store's `openspec/config.yaml`
(`orchestration.model_mechanical` / `model_standard` / `model_deep`) if
set, else the engine's default table (`model_for_tier` in
`scripts/lib.sh`):

| tier         | default model               |
|--------------|------------------------------|
| `mechanical` | `claude-haiku-4-5-20251001` |
| `standard`   | `claude-sonnet-5`           |
| `deep`       | `claude-opus-5`             |

`none` runs no model — it's plain bash bookkeeping (`scripts/run-change`
itself), never a task dispatched to an agent.

Pick the smallest tier that can be wrong safely.

### Fix rounds

One loop serves both a red full gate (step 5) and a non-clean Verify
(step 6): a fixer at the implementer tier receives the failure or the
verify report — never the checker's transcript — and changes only what the
findings name. `fix_attempts` counts both kinds against the same cap of 3
per change; a change does not get three rounds for tests and three more
for review, and a round that fails the convergence test under **Checker
loops** gates at once. Escalation is by round number: round 1 mechanical/standard by
triage, round 2 standard, round 3 deep, then Gate 1. Each fixer logs a
session entry with `phase checking` before Verify reruns, so `model verify`
sees the fixer as the latest implementer and picks a different model to
re-check its work. A worker that fails its own check once retries one tier
up before it counts as a fix round. Record
`model` and `tier` on every session-history entry — resolve the model with
`model get` first, then `scripts/run-change session append --store <slug>
--name <change> role worker phase applying tier mechanical model
<model-id> transcript_id <id>` — so `session list` gives the full history
and `status` surfaces each change's most recent tier in a `LAST_TIER`
column, to catch when a change burned expensive calls on mechanical work.

## Hard rule: written for agents

- Comments exist only to help a later agent act correctly: a constraint the
  code can't show, the requirement ID a block satisfies, why the obvious
  alternative is wrong, an external quirk, a boundary invariant. Forbidden:
  narrating the next line, restating a name, tutorial explanations,
  decorative headers, docstrings repeating the signature.
- Keep it simple: one script/function that does the job beats a framework;
  no abstraction with a single caller.
- Keep it short: the shortest artifact, rule, commit message, gate summary,
  or reply that is complete.
- Verify reports human-narrative comments and oversized artifacts as
  findings; the fix round for them runs at the mechanical tier.
