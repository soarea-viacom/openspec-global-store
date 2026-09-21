---
name: openspec-orchestrator
description: Spec-driven development workflow (propose a delta spec before touching code, implement against the approved proposal with tests, archive into the living spec). Routes OpenSpec artifacts to whichever root fits the project — an already-existing local openspec/ folder (used as-is, always takes priority), or an external store when there is no local folder, asking the user which to use for a project that has neither. When routed externally, the target project's directory and git history are otherwise untouched by OpenSpec. Always runs autonomously — the whole change end to end, asking the human only when something is wrong; there is no step-by-step mode. Use when the user wants to add/change a feature under spec control, invokes /sdd:explore for read-only discovery, or asks to orchestrate/route OpenSpec locally or to an external store.
---

# OpenSpec Orchestrator

One skill, two halves: the **discipline** (spec-driven development — no "vibe coding", no logic drift) and the **routing** (deciding whether a project's OpenSpec artifacts live locally in its own `openspec/` folder or in an external store). The default is external — a project with no `openspec/` folder and no registered store gets an external store, keeping the project's directory and git history untouched by OpenSpec. But routing is per-project, not fixed: a project that already has a local `openspec/` folder keeps using it, even if an external store also exists for that project.

**Never run `openspec init` inside a target project.** (A local `openspec/` folder the project already has is a different thing — see Step 1 — and is used as-is, never created by this skill.)

## Core Directives

1. **Spec Alignment First:** Never write, modify, or delete application code before analyzing existing specifications or generating a delta spec proposal.
2. **Context Isolation:** Limit context gathering strictly to files relevant to the active issue. Do not pollute the prompt window with unrelated modules.
3. **Deterministic Implementation:** Prioritize maintainability, explicit type definitions, and testability over concise or clever code.

## Step 0 — Preflight (fail fast, before touching anything)

Run these checks in order, before resolving a slug or creating any store. Each check either passes, or stops the flow with a clear message. When a prerequisite is missing, **offer to install it globally** (user-level: `~/.claude/`, `npm i -g`) — never into the project repository; the no-pollution rule applies to prerequisites just as much as to artifacts.

1. **OpenSpec CLI:** verify `openspec` is on PATH and supports the commands this flow needs — `openspec store --help` and `openspec doctor --help` must both succeed. If the CLI is missing or too old, offer to install/upgrade it globally (`npm i -g openspec`); do not add it to the project's `package.json`.
2. **Sane working directory:** verify the cwd is a real target project — not a store's own root registered under a *different* project (Step 1 below covers a store that legitimately points back at this same project) and not a bare `~/openspec-stores/<slug>` checkout opened on its own. Refuse to orchestrate a store-for-a-store.
3. **Git repository:** the project must be a git repo with at least one commit on a trunk branch — the store's slug falls back to the directory name without a remote (Step 1), but every change branch, worktree, gate and merge in this skill hangs off the project's own git history and cannot exist without it. If `git -C . rev-parse --git-dir` fails, run `git init -b main` in the project; if the repo then has no commit (fresh init, or an empty folder holding a first idea), stage whatever is there and make the initial commit (`git add -A && git commit --allow-empty -m "Initial commit"`). Do this **before any work** — before the store is resolved, before a proposal is drafted — so the first idea a user brings to an empty folder lands in a repo that can carry a `change/<name>` branch. This is the one write under the project root this skill makes in external-store mode; local mode (Step 1) makes one more (`.openspec-store/store.yaml`). `scripts/run-change workspace create` performs the same init deterministically (`ensure_project_git` in `scripts/lib.sh`) so the engine never fails on a missing repo either.

Only when all three pass, continue to Step 1.

## Step 1 — Resolve the artifact root: local, store, or ask

Two things can exist independently for a given project: a local `openspec/` folder committed in the project itself, and an external store registered for it (identified by the slug below). Resolve in this order:

1. **Check for a local root:** does `./openspec/` already exist in the project?
2. **Compute the slug regardless** (needed either way — to check for an existing store, and because local mode registers the project *as* a store under this same slug):
   1. From the project directory, run `git remote get-url origin`.
   2. Normalize the URL into a slug: strip the protocol and trailing `.git`, replace every run of non `[a-z0-9]` characters with a single `-`, lowercase the result, and trim leading/trailing hyphens.
      Example: `git@github.com:acme/widgets.git` → `github-com-acme-widgets`.
   3. If there's no git remote (or it's not a git repo — shouldn't happen after Step 0.3), fall back to the current directory's basename, normalized the same way.
   4. **Store ids must be strict kebab-case** — lowercase letters, numbers, and single hyphen separators only (verified against `openspec store setup`, which rejects anything else with `invalid_store_id`). The normalization above must produce a string matching that rule before it's ever passed to `--store` or `store setup`.
3. **Check for an existing store:** `openspec store list --json` — is a store with this slug already registered, and does its `local_path` point somewhere *other than* this project (i.e. a genuine external store, not this project already running in local mode)?
4. **Decide:**
   - **Local exists** (regardless of whether an external store also exists) → **use local.** Local always wins. If an external store for this slug also exists, mention it to the user once and note it is being bypassed for this project — do not delete or otherwise touch that store.
   - **No local, store exists** → **use the store.**
   - **Neither exists** → **ask the user** (do not guess): "This project has no local OpenSpec artifacts and no registered store yet — save OpenSpec artifacts locally in this project's `openspec/` folder, or in an external store?" Proceed per their answer. If they pick local, the folder is created as part of Step 2's `store setup` below (which lays down `openspec/specs`, `openspec/changes`, `openspec/config.yaml`) — this skill still never runs `openspec init`.

This decision is made **once per invocation**, from repo state — no mapping file is kept. Re-running this skill later against the same project recomputes it the same way, so if the user later adds or removes the local `openspec/` folder, routing follows.

## Step 2 — Ensure the resolved root exists as a store

Every root this skill operates on — local or external — is a registered OpenSpec store; the CLI's `--store <slug>` flag is what makes every later command point at the right root. The only difference between local and external is the `--path` and whether Git is touched:

- **Local mode:** `openspec store setup <slug> --path <project-path> --no-init-git`. `--no-init-git` is required — the project already owns its git history (Step 0.3); this must never become a second, nested repo. This is safe to run even when `openspec/` already has content: `store setup` only adds `.openspec-store/store.yaml` and registers the slug, it does not overwrite existing `specs/`, `changes/`, or `config.yaml`. **Never run `openspec store remove` on a local-mode store** — its `local_path` *is* the project root, and `store remove --yes` deletes the local folder; removing a local-mode store would delete the project's own `openspec/` and untracked project files. There is no supported "unregister only" flag, so a local-mode store, once created, is simply left registered for the life of the project.
- **External mode:** if missing, create it: `openspec store setup <slug> --path ~/openspec-stores/<slug>`. Leave Git init on (the default) — the store gets its own commit history, independent of the project's repo.
- Either way: `openspec doctor --store <slug>` — confirm the root is healthy before doing anything else.

## Step 3 — Execution workflow (OpenSpec 3-Phase Engine, routed to the resolved root)

These three phases are the shape of every change. They are never run one at a time with a review stop in between — see **Autonomous only** below for how they are driven.

Every OpenSpec CLI call below gets `--store <slug>` appended — e.g. `openspec instructions --store <slug>`, `openspec new change <name> --store <slug>`, `openspec status/validate/show/list --store <slug>`, `openspec archive <name> --store <slug>`. This is unchanged by local vs. external mode — `--store <slug>` always resolves to whichever root Step 1 picked, since local mode registers the project itself under that slug. What differs is only where that root physically is: in external mode the OpenSpec artifacts (proposals, deltas, specs, tasks) land under `~/openspec-stores/<slug>/`, never under the project; in local mode they land under the project's own `openspec/`, by the user's choice recorded in Step 1. The "apply" phase's actual code edits always happen in the project directory as normal (Read/Edit/Write on project files), independent of which mode is active.

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

Before drafting the proposal or dispatching the critique/verify checkers, check
`scripts/run-change stage-skills get --store <slug> --stage plan|critic|test` — the
resolved root's `openspec/config.yaml` may name one of the *project's own* skills for
that stage (`orchestration.stage_skills`). A mapped `plan` skill drafts instead of the
default deep-tier model; a mapped `critic`/`test` skill runs *in addition to* the default
checker, never instead of it. See **Project-skill stage mapping** in
[AUTONOMOUS-ORCHESTRATION.md](AUTONOMOUS-ORCHESTRATION.md) for the exact rule and
[`docs/proposals/skill-stage-mapping.md`](docs/proposals/skill-stage-mapping.md) for the
design rationale. Unset (the common case) → the three phases run exactly as described
above, no project skill involved.

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

In **external mode**, `openspec workset create <slug> --member project=<project-path> --member spec=~/openspec-stores/<slug>` saves a purely-local, two-folder view for opening the project and its spec store together in an editor. This only writes to the workset's own local record — nothing changes in the project or the store. Mention it as an option; it isn't required for the workflow to function. It doesn't apply in **local mode** — project and spec root are already the same folder.

## Guardrails

- Never run `openspec init` in a project, in either mode. A local root this skill uses is either one the project already had, or one laid down by `openspec store setup --path <project> --no-init-git` (Step 2) — never by `openspec init`.
- Missing prerequisites are installed globally (user-level) only — never as project dependencies, project `.claude/` entries, or any other file in the target repository.
- **External mode only:** never write to any path under the project root for OpenSpec purposes. The sole exception is `git init` plus an initial commit when the project has no repo or no commit yet (Step 0, check 3) — that is project infrastructure the branch/worktree model requires, not an artifact. In local mode this restriction does not apply by design — the user chose to keep artifacts in the project — but the only files this skill itself adds under the project root are `.openspec-store/store.yaml` (Step 2) and whatever the three phases legitimately write under `openspec/` (proposals, deltas, specs, tasks) and, per the branch/worktree model, `.git/`.
- Never omit `--store <slug>` on an OpenSpec CLI call once a root is resolved — a bare command silently falls back to the current directory as root, which would put artifacts in the wrong place. This applies in both modes.
- **Local takes priority, never silently:** if a project has a local `openspec/` folder, use it — do not refuse, and do not fall back to an external store instead, even if one is already registered for this project's slug (Step 1). If both exist, say so once to the user and explain local is being used; never delete or modify the bypassed external store.
- **Never run `openspec store remove` on a local-mode store.** Its `local_path` is the project root, so `--yes` deletes the project's `openspec/` and any other untracked project files. A local-mode store, once registered, stays registered for the project's life; there is no supported unregister-only path.
- Autonomous-orchestration config (`orchestration.concurrency`, `gate_quick`, `gate_full` — which must include the project's dead-code pass, e.g. `npm test && npx knip` — `model_mechanical`, `model_standard`, `model_deep`, `stage_skills`) goes in the **resolved root's** `openspec/config.yaml` — `~/openspec-stores/<slug>/openspec/config.yaml` in external mode, `<project>/openspec/config.yaml` in local mode. This is the single location the engine reads per mode. The `model_*` keys are optional overrides; `scripts/run-change model get` falls back to the engine's default tier→model table when a store doesn't set them. `stage_skills` is likewise optional; unset means no project skill is involved in Propose, critique, or Verify — see Step 3 above.
