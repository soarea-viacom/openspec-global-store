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
`phase`, `fix_attempts`, `last_gate_result`, `last_verify_result`,
`initiative`, `depends_on`, `follows`, `supersedes`, `blocked_on`, and a
session history entry (`name`, `role: orchestrator|worker|resume`, `phase`,
`gates_hit`, `transcript_id`) per orchestrator run against this change.

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
3. **Propose** — draft the delta spec via the normal
   `openspec-orchestrator` propose phase, scoped to the workspace, `--store
   <slug>`. Before drafting prose, sketch the **seams** the change touches:
   existing seams preferred over new ones, fewest possible (one is ideal),
   each seam named with the files/modules behind it. Write this seam list
   to the change's state (`scripts/run-change state set ... seams
   "<seam>=<file>,<file>;<seam>=<file>"` — see **Seam list** in
   CONTEXT.md), not just narrated in the delta spec prose — it is the input
   dispatch groups are cut along in step 4 and what the disjoint-files
   check reads, not a separate exercise redone at Apply time. Commit on the
   branch. Never asks a human in autonomous mode.
4. **Apply** — implement in dispatch groups, one per seam from the Propose
   step's seam list (see model/effort tiers below). Before fanning groups
   out, run the disjoint-files check below; a change too small to have
   named more than one seam stays a single group. Run the project's *quick*
   gate (lint, type check, last-failed tests — `orchestration.gate_quick`
   command from the store's config) after each group.
5. **Check** — run the project's *full* gate
   (`orchestration.gate_full`, parallelized if the project's test runner
   supports it).
   - Red: auto-fix, bounded at 3 rounds (tier escalation: round 1
     mechanical/standard by triage, round 2 standard, round 3 deep). Still
     red after 3 → **Gate 1**: ask the human with the failure.
   - Green: continue to verify.
6. **Verify** — check the implementation matches the proposal. A critical
   finding → **Gate 1**. Otherwise continue.
7. **Archive** — finalize artifacts (`openspec-orchestrator` archive phase),
   commit on the branch.
8. **Merge lane** — `scripts/run-change merge-lane run --store <slug>
   --project <path> --name <name>`: acquire the project's single
   merge lock, merge current trunk into the branch, rerun the full gate.
   Red → back to the auto-fix step above. Green → **Gate 2**: ask the human
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
(`<store>/.orchestration/initiatives/<name>.yaml`: title, originating
request, ordered children with `depends_on`/`status`/`merged_commit`)
instead of inferring the split later.

- A child starts only when its dependencies are merged, up to the
  concurrency cap, and only after the disjoint-files check below clears it
  against every other in-flight child for that project.
- Gate 2 is per child by default. The first Gate 2 of an initiative may
  offer "approve this merge and let remaining green children merge
  autonomously." Gate 1 always asks.
- `scripts/run-change status` shows the initiative tree with per-child
  phase and blocker.
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

## Model/effort routing

Pick a tier per task, not per session:

- `none`: workspace create/remove, running the gate, merge lane, state/
  initiative bookkeeping, commit trailers, archival file moves.
- `mechanical`: lint/format fixes, type-annotation-only fixes, commit
  message drafting, first-round red-gate triage (flake vs lint vs type vs
  logic).
- `standard`: ordinary implementation tasks, tests, verify reports.
- `deep`: decomposing a request into an initiative, design docs, anything
  touching an invariant, fix rounds 2 and 3.

Pick the smallest tier that can be wrong safely. Fix-loop escalates
mechanical/standard → standard → deep → Gate 1. A worker that fails its own
check once retries one tier up before it counts as a fix round. Record
`model`/`tier` per session-history entry so a status/log view can show when
a change burned expensive calls on mechanical work.

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
- Verify/triage flags human-narrative comments and oversized artifacts as a
  warning, fixed at the mechanical tier.
