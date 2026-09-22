# Autonomous change orchestration

Rule document for running OpenSpec changes. It is the **only** execution
mode of the `openspec-orchestrator` skill: whenever the skill is invoked on
a change, read this doc and run the three phases in [SKILL.md](SKILL.md) end
to end, asking the human only if something is wrong. The human never has to
say "run autonomously" — that is always assumed, and there is no
step-by-step alternative to fall back to. Stopping between phases to wait
for approval is a bug, not a mode.

The reader of this doc, the state files, and the scripts it drives is
another agent in a later session, not a human. Comments and state exist to
let that agent act correctly, not to narrate — see §8.

## Repo boundary (read this first)

This repo is the shared *engine*: this doc, `scripts/`, and the phase
definitions in [SKILL.md](SKILL.md). It ships once and applies to every
target project the `openspec-orchestrator` skill routes to.

A "change" always has two locations, never one:

- **Code and git history** live in the **target project's own repo** — the
  branch `change/<name>` and every commit on it belong to that repo. Its
  worktree is *checked out* under the store
  (`<store>/.orchestration/workspaces/<name>`, ignored by the store's git)
  so the project's main checkout never shows orchestration files; git
  still records the worktree in the project's `.git/worktrees`.
- **Spec artifacts and orchestration state** live in that project's
  **store** — the directory the `openspec-orchestrator` skill resolved via
  `--store <slug>` (slug recomputed from `git remote get-url origin`, kebab-
  cased; see that skill for the exact algorithm — there is no persisted
  mapping file, so always recompute, never cache a slug across sessions).
  That directory is usually a separate external root
  (`~/openspec-stores/<slug>`), but when the project already has its own
  `openspec/` folder, the skill's Step 1 registers the project **as** the
  store (same slug, `local_path` pointing at the project itself) — see
  SKILL.md's local-mode routing. The two locations above then collapse into
  one directory, but the CLI-level split (`--store <slug>` for artifacts,
  plain project paths for code) is unchanged.

Orchestration config (`orchestration.concurrency`, `gate_quick`,
`gate_full`) lives ONLY in the resolved store's `openspec/config.yaml`.
`scripts/run-change` refuses a project that has its own `openspec/` folder
**only when** the store it's being pointed at is a genuinely different
external root — that combination means the wrong store was resolved for a
project that should be running in local mode instead (`guard_project_openspec`
in `scripts/lib.sh`). A project running in local mode (store `local_path` ==
the project) is never refused.

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
`phase`, `propose_rounds`, `last_critique_result`, `prev_critique_result`,
`fix_attempts`, `last_gate_result`, `gate_tree`, `last_verify_result`,
`prev_verify_result`, `initiative`, `depends_on`, `seams`, `follows`,
`supersedes`, `blocked_on`. `gate_tree` is written by `gate run --mode full`
itself, only when the gate passes: the git tree id it ran on. The `prev_*`
fields are written by `state set`
itself whenever a real `last_*_result` is overwritten — by a new result or
by the `""` written before a recheck; overwriting an empty value shifts
nothing — so the orchestrator never sets them.
Session history is a separate append-only log, one line per
orchestrator/worker run against this change, at
`<store>/.orchestration/state/<change>.sessions.log` (see **Session log**
in CONTEXT.md) — `role: orchestrator|worker|advisor|resume`, `phase`, `gates_hit`,
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
   worktree checked out under the store's `.orchestration/workspaces/`,
   dependencies synced. A project with no repo or no commit yet (an empty
   folder the first idea landed in) is initialized first — `git init -b
   main` and an initial commit of whatever is there — by the same command
   (`ensure_project_git`), mirroring Step 0 check 4 of SKILL.md; nothing
   downstream ever sees a project without a trunk. Never dispatch work against the project's main
   checkout — and every gate (`gate run ... --name <name>`) runs in the
   worktree, never in the main checkout, which is trunk and says nothing
   about the branch.
3. **Propose** — always runs at the `deep` tier (see Model/effort routing
   below), regardless of how small the change looks: a mistake here is the
   most expensive one, because every later phase inherits it — unless the
   project mapped its own skill to `plan` (**Project-skill stage mapping**
   under Model/effort routing), in which case that skill drafts instead.
   Draft the delta spec via the normal `openspec-orchestrator` propose phase, scoped
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
   the draft on five standards. If the project mapped one or more skills to
   `critic` (**Project-skill stage mapping**), each of them is dispatched
   **concurrently** with this checker, reads the same inputs, and reports
   alongside it — not instead of it; the step waits for all of them and
   merges the reports.
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
   named more than one seam stays a single group. Groups that pass the
   check run concurrently as separate workers in the change's one worktree,
   each confined to its seam's file list (see **Isolation** below: own
   context, no git writes). When every group in the wave has returned, the
   orchestrator runs the project's *quick* gate (lint, type check,
   last-failed tests — `orchestration.gate_quick` from the store's config)
   and commits — never while a worker is still writing.
5. **Check** — run the project's *full* gate
   (`orchestration.gate_full`, parallelized if the project's test runner
   supports it) **and dispatch Verify (step 6) at the same time**: both
   only read the tree the orchestrator just committed, so neither waits
   for the other (`next` returns `check` with `also: verify` and the
   checker's `also_model`). Record both results as they land. The pass
   line is unchanged — green *and* clean — so this costs at most one
   partly wasted checker call on a red gate and saves a full checker
   latency on every change. The full gate must include the project's
   **dead-code pass** — `knip` for JS/TS, `vulture` for Python, the ecosystem's
   equivalent otherwise — reporting unused files, unused exports and
   unused dependencies as one red result. Agents leave abandoned work
   behind: an approach tried and replaced, a dependency pulled in for an
   idea then dropped, a helper refactored past. None of it fails a test,
   so a passing suite cannot see it, and Verify reads the diff against
   the proposal, not the whole graph. Only a graph tool in the gate does.
   Its red is a normal fix round, triaged to `mechanical`: delete what it
   names.
   - Red: a **fix round** (see below). If Verify has already reported, the
     fixer gets the gate failure *and* the verify report and fixes both in
     that one round; a verify result of `spec` gates immediately instead,
     and the convergence test on the verify count applies as under green.
     Out of rounds → **Gate 1**: ask the human with the failure.
   - Green: act on the Verify result below; if it is not in yet, wait for it.
6. **Verify** — dispatched together with step 5. A checker with a fresh
   context and a model distinct from
   whichever one last wrote code for the change (`scripts/run-change model
   verify --store <slug> --name <name>` — see the generator/checker split
   under Model/effort routing) reads the proposal and the branch diff and
   judges whether the code satisfies the proposal. It never sees the
   implementer's transcript. If the project mapped one or more skills to
   `test` (**Project-skill stage mapping**), each of them is dispatched
   **concurrently** with this checker, reads the proposal and diff, and
   reports alongside it — not instead of it; the step waits for all of
   them and merges the reports. It writes a **verify report** to
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
   merge lock, merge current trunk into the branch (`origin/<trunk>` when
   the project has a remote, the local trunk when it has none; trunk is
   `origin/HEAD`, else local `main`, else `master`), then rerun the full
   gate — **unless the merged tree is identical to the one the last
   passing full gate ran on** (`gate_tree` in the state file, recorded by
   `gate run --mode full` itself), in which case the rerun is skipped and
   the command says so: same tree, same deterministic result. Trunk having
   moved, or an Archive commit that touched the worktree (local mode),
   changes the tree and forces the rerun. Red → a fix round (same
   budget). Green or skipped → **Gate 2**: ask the human with a summary
   (diffstat, gate log, verify report).
9. **Merged** — on approval, squash-merge into trunk (one commit, with the
   trailers below), remove the workspace, release the slot. If the change
   belongs to an initiative, record the commit on it first:
   `scripts/run-change initiative merged --store <slug> --name
   <initiative> --child <name> --commit <sha>` — the initiative record
   outlives the child's state file.

Everything between gates is autonomous. Commits on `change/<name>` never
ask. Squash-merge produces one commit per change on the project's trunk.

## Isolation

Three layers keep concurrent agents from corrupting each other. They are
independent: each one holds even if the others are misconfigured.

- **Context.** Every worker — dispatch group, fixer, critic, Verify, triage
  — runs in its own context window. It receives exactly what the
  orchestrator hands it (proposal, its seam's file list, its task, a
  report) plus what it reads from disk itself; never another worker's
  transcript, and never the orchestrator's. A wrong guess made in one
  window cannot spread to another except through a file, and every file
  that crosses between agents (spec, seam list, state, reports) is
  something the next reader can check against the code. This is the
  default when dispatching a subagent; the rule is to never defeat it by
  pasting one worker's output into another's prompt as fact.
- **Files.** Two writers may run at once only if the file lists behind
  their seams are disjoint — the check below. A worker writes only inside
  its own seam's list; a file it needs that isn't listed is a mid-run
  seam-list finding (below), not a silent edit. **A read-only worker is
  always collision-safe**: critic, Verify, triage, and any investigation
  never write, so they never need the check and may run beside any writer
  in any worktree. The one caveat is coherence, not collision — a checker
  reading a worktree while a writer is mid-edit sees a torn tree. So
  checkers start after the wave they judge has returned and been
  committed; they may overlap freely with writers in other worktrees.
- **Git.** Every change has its own worktree on its own branch (step 2), so
  changes never share an index or a working tree. Within a change, the
  concurrent dispatch groups do share the worktree, and a shared git index
  is a shared file: two `git add`s or two commits at once corrupt it even
  when the edited files are disjoint. Hence workers never run any git
  command that writes — no add, commit, stash, checkout, reset, or branch.
  The orchestrator is the only committer: once per wave after the quick
  gate, once per phase after that. A worker that wants to "save its
  progress" returns instead.

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
  Read-only workers are outside the check entirely (see **Isolation**).
- **Across a project**, among in-flight initiative children: compare the
  `seams` field of every child not yet merged before starting a new one
  concurrently, on top of (not instead of) the `depends_on` ordering.

A file list that turns out to be wrong once real implementation starts
(a shared barrel export, config, or type file no seam sketch named) is a
mid-run finding, not a silent merge: fall back to sequential for the
groups/children involved and fix it with `state set ... seams "..."`, the
same command that wrote it.

## Driving the loop: `next` decides, the agent does

The lifecycle above is long. Do not hold it in your head and re-derive
the next step each turn; ask the engine:

```
scripts/run-change next --store <slug> --name <change>
```

prints one step — `action`, `tier`, resolved `model`, the `set_phase` to
record when the step completes, and the `reason` (which rule fired) — from
the change's state file and session log alone. On `check` it adds `also:
verify` and `also_model: <id>`: a second, read-only step to dispatch
concurrently with the first, never a replacement for it. Actions: `propose`,
`critique`, `revise`, `apply`, `check`, `fix`, `verify`, `sweep`,
`archive`, `merge-lane`, `gate1`, `gate2`, `wait`, `done`. The caps
(`FIX_CAP`, `PROPOSE_CAP`), the fix-round tier ladder, the pass line, and
the distinct-model checker rules all live in `next_action`
(`scripts/lib.sh`), so the orchestration is deterministic code and the
agent's job is the step itself: dispatch the worker `next` names, then
record what happened (`state set ... last_gate_result green|red`,
`last_verify_result ...`, `fix_attempts`, `propose_rounds`, `phase`) and
ask `next` again. `last_gate_result` is `green` or `red`; nothing else.

`next` is read-only and never dispatches — the orchestrator still owns
gates and workers. What it removes is the decision. If the prose in this
document and `next_action` ever disagree, fix the prose: `next_action` is
what runs, and `tests/run.sh` walks a change through every branch of it.

## Resumability

`scripts/run-change status --store <slug>` discovers state from
`<store>/.orchestration/`, not chat memory, and `next` resumes any change
from its recorded fields. Commit on the branch after every
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
and `last_critique_result` for its critique loop, and `merged` — a
`child=sha` map filled in by `initiative merged` as each child lands)
instead of inferring the split later. `children` is ordered: it is the
intended merge order, and a child may only precede another it does not
depend on. Per-child `depends_on` lives on each child's own state file;
the initiative's order must be consistent with those edges, which the
critique checks.

- A child starts only when its dependencies are merged, up to the
  concurrency cap, and only after the disjoint-files check below clears it
  against every other in-flight child for that project.
- Gate 2 is per child by default. The first Gate 2 of an initiative may
  offer "approve this merge and let remaining green children merge
  autonomously." Gate 1 always asks.
- `scripts/run-change status` shows the initiative tree — critique rounds
  and result, then each child in merge order with its phase and blocker,
  `not-started` if it has no state file yet, or `merged <sha>` once its
  commit is on the record.
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
  the same thing. The count half is mechanical: `next` compares
  `last_*_result` with `prev_*_result` and returns `gate1` when a
  `blocking` count fails to fall. The reopened-finding half needs
  finding ids the reports don't carry, so the checker states it in the
  report and the orchestrator acts on it.
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
  `depends_on` is acyclic, every edge is real (the child cannot start
  without it), and the `children` order respects every edge; no two children that could run concurrently share a file
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
- `mechanical`: lint/format fixes, type-annotation-only fixes, deleting
  dead code and unused dependencies the gate's dead-code pass names,
  commit message drafting, first-round red-gate triage (flake vs lint vs
  type vs dead code vs logic).
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

### Project-skill stage mapping (Propose / critique / Verify)

Before dispatching Propose, the critique step, or Verify at the tier/model above, check
whether the project has named one of its own skills for that stage:
`scripts/run-change stage-skills get --store <slug> --stage plan|critic|test`. Output is
one skill name per line, empty if the project set nothing — see
[`docs/proposals/skill-stage-mapping.md`](docs/proposals/skill-stage-mapping.md) for the
full design and why the mapping lives only in the resolved root's `openspec/config.yaml`
(`orchestration.stage_skills`), never in a skill's own frontmatter, and never behind any
other switch:

- **`plan`** — at most one name. If set, dispatch that skill (via the `Skill` tool, not a
  bare model call) to draft the delta spec and seam list **instead of** the deep-tier
  model — this *replaces* the default drafter, it does not add to it. If unset, Propose
  runs exactly as described in Phases step 3: deep tier, no skill involved.
- **`critic`** — zero or more names. If non-empty, dispatch every listed skill **in
  addition to** the tier/model critic already described in Phases step 3 — never instead
  of it. The critique step only passes if *none* of them — built-in or mapped — reports a
  blocking finding; merge every mapped skill's findings into the one critique report,
  each tagged with which skill produced it, same file, same `last_critique_result`
  handling as today.
- **`test`** — zero or more names. Same rule as `critic`, stacked on top of the tier/model
  Verify checker described in Phases step 6, merged into the one verify report the same
  way.

Two things this mapping does not do, on purpose: it never disables the built-in
checker for `critic`/`test` (a mapped skill is additional signal, not a replacement for
the one check this engine can vouch for itself), and it never checks whether a mapped
skill is safe to run unattended — if a project maps a skill that stops to interview a
human, the change simply stalls in that phase, visible the same way any other broken step
is, not something this engine detects in advance.

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
up before it counts as a fix round — but before failing, it may ask an
advisor (below). Record
`model` and `tier` on every session-history entry — resolve the model with
`model get` first, then `scripts/run-change session append --store <slug>
--name <change> role worker phase applying tier mechanical model
<model-id> transcript_id <id>` — so `session list` gives the full history
and `status` surfaces each change's most recent tier in a `LAST_TIER`
column, to catch when a change burned expensive calls on mechanical work.

### Advisor: the deep tier for one question, not the whole task

Most of a `standard` or `mechanical` task is routine; the hard part, when
there is one, is a slice — a design fork, a subtle bug, a piece of logic
the worker keeps getting wrong. Re-running the whole task at `deep` pays
top-tier prices for the routine part too. Instead a stuck worker packages
the one question and hands it to an **advisor**: a subagent at the `deep`
tier, fresh context, given the question, the proposal, and the file paths
it needs — never the worker's transcript. The advisor is read-only. It
returns an answer (a decision and why, or a diagnosis and the fix to make);
the worker applies it and carries on. The call is obtained, never
assumed: `scripts/run-change advisor request --store <slug> --name
<change> --worker <transcript-id>` checks both caps below, logs the entry
(`role advisor tier deep for=<worker>`) and prints the model to dispatch.
A direct `session append` with `role advisor` is refused, so the log
cannot show a call the engine did not grant.

Bounds, enforced by `advisor request`, because two agents cost more than
one when the hard part isn't rare:

- **One advisor call per worker task.** A second request from the same
  worker is refused: the task is not routine — return, and the
  orchestrator re-dispatches the whole task one tier up, as with a failed
  self-check.
- **Two advisor calls per change** across all its workers — `status` shows
  the count against the cap in its `ADVISOR` column, read from the
  session log. A third request is refused: the change was mis-tiered at
  Propose; note it in the verify report so the next Propose for that area
  starts at `standard` or `deep` outright.
- **Never from `deep`**, and never from a checker: Verify and the critic
  are already the strong read of the work, and an advisor that advises
  the checker collapses the generator/checker split.
- **Ask before failing, not instead of checking.** The self-check and the
  gate still run on the advised code; the advisor's answer is one more
  input a fresh reader can verify, not an approval.

### Coordination: blackboard only, no messaging

Workers report to the orchestrator and never to each other. Everything an
agent needs from another agent it reads from a file the orchestrator owns
— the proposal, the seam list, the change's state, the verify or critique
report. Those files are the blackboard, and they are enough because
concurrent workers are on disjoint seams by construction: a cross-seam
need that surfaces mid-run is a seam-list finding for the orchestrator,
not a note for a sibling. There is no worker-to-worker messaging and no
shared scratch file between concurrent workers. Both would let a wrong
guess in one context spread to another without passing through a
checkable artifact, which is exactly what **Isolation** exists to prevent.

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
- Leave nothing abandoned: a replaced approach, a helper refactored past,
  a dependency pulled in for a dropped idea — delete it in the same
  change. The full gate's dead-code pass is what enforces this; a worker
  that "might need it later" is wrong, because a later change can add it
  back from git history.
- Verify reports human-narrative comments and oversized artifacts as
  findings; the fix round for them runs at the mechanical tier.
