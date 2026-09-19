---
name: openspec-orchestrator
description: Spec-driven development workflow (propose a delta spec before touching code, implement against the approved proposal with tests, archive into the living spec) with all OpenSpec artifacts routed to an external store — the target project's directory and git history are never touched by OpenSpec. Always runs autonomously — the whole change end to end, asking the human only when something is wrong; there is no step-by-step mode. Use when the user wants to add/change a feature under spec control in a project without an openspec/ folder, invokes /sdd:explore for read-only discovery, or asks to orchestrate/route OpenSpec to an external store.
---

# OpenSpec Orchestrator

One skill, two halves: the **discipline** (spec-driven development — no "vibe coding", no logic drift) and the **routing** (every OpenSpec artifact lives in an external store registered outside the project). Projects initialized the traditional way (`openspec init`, with a project-local `openspec/` folder) are out of scope — they carry OpenSpec's own generated `/opsx:*` commands and instruction files; this skill refuses them and defers to those.

**Never run `openspec init` inside a target project. Never create or modify any `openspec/` or `.openspec-store/` path under the project root.**

## Core Directives

1. **Spec Alignment First:** Never write, modify, or delete application code before analyzing existing specifications or generating a delta spec proposal.
2. **Context Isolation:** Limit context gathering strictly to files relevant to the active issue. Do not pollute the prompt window with unrelated modules.
3. **Deterministic Implementation:** Prioritize maintainability, explicit type definitions, and testability over concise or clever code.

## Step 0 — Preflight (fail fast, before touching anything)

Run these checks in order, before resolving a slug or creating any store. Each check either passes, or stops the flow with a clear message. When a prerequisite is missing, **offer to install it globally** (user-level: `~/.claude/`, `npm i -g`) — never into the project repository; the no-pollution rule applies to prerequisites just as much as to artifacts.

1. **Hard refusal first:** if `./openspec/` exists in the project, stop immediately — the project has a traditional OpenSpec root; tell the user to use its own `/opsx:*` commands instead (see Guardrails). Check this before anything else so no store is ever created for a refused project.
2. **OpenSpec CLI:** verify `openspec` is on PATH and supports the commands this flow needs — `openspec store --help` and `openspec doctor --help` must both succeed. If the CLI is missing or too old, offer to install/upgrade it globally (`npm i -g openspec`); do not add it to the project's `package.json`.
3. **Sane working directory:** verify the cwd is a real target project — not a registered store itself and not under `~/openspec-stores/`. Refuse to orchestrate a store-for-a-store.
4. **Git repository:** the project must be a git repo with at least one commit on a trunk branch — the store's slug falls back to the directory name without a remote (Step 1), but every change branch, worktree, gate and merge in this skill hangs off the project's own git history and cannot exist without it. If `git -C . rev-parse --git-dir` fails, run `git init -b main` in the project; if the repo then has no commit (fresh init, or an empty folder holding a first idea), stage whatever is there and make the initial commit (`git add -A && git commit --allow-empty -m "Initial commit"`). Do this **before any work** — before the store is resolved, before a proposal is drafted — so the first idea a user brings to an empty folder lands in a repo that can carry a `change/<name>` branch. This is the one write under the project root this skill makes: `.git/` is the project's own infrastructure, not an OpenSpec artifact, and the no-pollution rule is about artifacts. `scripts/run-change workspace create` performs the same init deterministically (`ensure_project_git` in `scripts/lib.sh`) so the engine never fails on a missing repo either.

Only when all four pass, continue to Step 1.

## Step 1 — Resolve project identity (deterministic, no state file)

No mapping file is kept anywhere — the store id is recomputed the same way every time:

1. From the project directory, run `git remote get-url origin`.
2. Normalize the URL into a slug: strip the protocol and trailing `.git`, replace every run of non `[a-z0-9]` characters with a single `-`, lowercase the result, and trim leading/trailing hyphens.
   Example: `git@github.com:acme/widgets.git` → `github-com-acme-widgets`.
3. If there's no git remote (or it's not a git repo), fall back to the current directory's basename, normalized the same way.
4. **Store ids must be strict kebab-case** — lowercase letters, numbers, and single hyphen separators only (verified against `openspec store setup`, which rejects anything else with `invalid_store_id`). The normalization in step 2/3 must produce a string matching that rule before it's ever passed to `--store` or `store setup`.

## Step 2 — Ensure the store exists

1. `openspec store list --json` — check whether a store with the resolved slug is already registered.
2. If missing, create it: `openspec store setup <slug> --path ~/openspec-stores/<slug>`.
   Leave Git init on (the default) — the store gets its own commit history, independent of the project's repo.
3. `openspec doctor --store <slug>` — confirm the root is healthy before doing anything else.

## Step 3 — Execution workflow (OpenSpec 3-Phase Engine, routed to the store)

These three phases are the shape of every change. They are never run one at a time with a review stop in between — see **Autonomous only** below for how they are driven.

Every OpenSpec CLI call below gets `--store <slug>` appended — e.g. `openspec instructions --store <slug>`, `openspec new change <name> --store <slug>`, `openspec status/validate/show/list --store <slug>`, `openspec archive <name> --store <slug>`. The "apply" phase's actual code edits still happen in the project directory as normal (Read/Edit/Write on project files) — only the OpenSpec artifacts themselves (proposals, deltas, specs, tasks) are written under `~/openspec-stores/<slug>/`, never under the project.

- **Phase 1: Explore & Propose**
  - Read active code boundaries and structural modules.
  - Draft explicit architectural intent into a temporary delta spec.
  - Predict potential side effects or breaking changes in downstream dependencies.
- **Phase 2: Active Implementation**
  - Write modular, self-documenting code that maps 1:1 with the finalized proposal.
  - Implement accompanying integration or unit tests simultaneously.
- **Phase 3: Final Consolidation**
  - Verify syntax execution and run the testing suite locally, plus the project's dead-code pass (`knip` for JS/TS, `vulture` for Python, or equivalent) — a passing suite cannot see an abandoned helper or an unused dependency this change left behind; delete what the pass names before archiving.
  - Cleanly merge finalized changes back into the store's living specs.

## Autonomous only

This skill has exactly one execution mode. Invoking it on a change means:
run all three phases end to end, with gates, the auto-fix loop and the
merge lane, and ask the human only if something is wrong. Follow
[AUTONOMOUS-ORCHESTRATION.md](AUTONOMOUS-ORCHESTRATION.md) for the exact
procedure; it asks the human at most twice per change, and only when
something is blocked or failing — never for routine approval between
phases.

There is no step-by-step or "review after each phase" mode, and none may be
improvised: do not stop after a proposal, an implementation or an archive
to wait for a go-ahead, even if the request is phrased as a single phase
("just draft the proposal", "only apply"). Treat such a request as the
whole change and run it; if the human genuinely wants to stop early, they
say so and the change is left `blocked` per the orchestration doc. The
only command that is not a full run is `/sdd:explore`, which is read-only
discovery and writes nothing — it precedes a change, it is not a phase of
one.

## Optional convenience

`openspec workset create <slug> --member project=<project-path> --member spec=~/openspec-stores/<slug>` saves a purely-local, two-folder view for opening the project and its spec store together in an editor. This only writes to the workset's own local record — nothing changes in the project or the store. Mention it as an option; it isn't required for the workflow to function.

## Guardrails

- Never run `openspec init` in a project.
- Missing prerequisites are installed globally (user-level) only — never as project dependencies, project `.claude/` entries, or any other file in the target repository.
- Never write to any path under the project root for OpenSpec purposes. The sole exception is `git init` plus an initial commit when the project has no repo or no commit yet (Step 0, check 4) — that is project infrastructure the branch/worktree model requires, not an artifact.
- Never omit `--store <slug>` on an OpenSpec CLI call once a store is resolved — a bare command silently falls back to the current directory as root, which would put artifacts in the wrong place.
- **Hard refusal:** if the project contains an `openspec/` folder (previously `init`ed the traditional way), this skill must not run at all — checked first thing in Step 0. Tell the user the project has a traditional OpenSpec root with its own generated `/opsx:*` commands, and to use those; do not proceed, do not work around it. `scripts/run-change` in the engine enforces the same rule deterministically.
- Autonomous-orchestration config (`orchestration.concurrency`, `gate_quick`, `gate_full` — which must include the project's dead-code pass, e.g. `npm test && npx knip` — `model_mechanical`, `model_standard`, `model_deep`) goes in the **store's** `openspec/config.yaml` (`~/openspec-stores/<slug>/openspec/config.yaml`) — never in the project. This is the single location the engine reads. The `model_*` keys are optional overrides; `scripts/run-change model get` falls back to the engine's default tier→model table when a store doesn't set them.
