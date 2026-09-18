# Autonomous change orchestration — portable notes

The phase machine, gates, backpressure, triage, initiatives, tiers and
agent-writing rule live in [AUTONOMOUS-ORCHESTRATION.md](AUTONOMOUS-ORCHESTRATION.md)
— that doc is the single home of the rules; nothing here duplicates it.
This file keeps only what a *new* repo adopting the pattern needs before
that doc applies.

## Preconditions to measure before adopting

- Current gate runtime and whether it parallelizes (test count, slow steps).
- Whether isolated workspaces (git worktrees, containers) are cheap to
  create and sync dependencies into.
- Which paths must never be touched outside a designated subdirectory
  (protected inputs, secrets, generated-and-committed files).
- Existing approval/permission policy, so gates don't duplicate it.

## One-time setup in the target project

- Parallelize the test runner after confirming no shared-state tests break;
  pin the ones that do to serial rather than dropping parallelism everywhere.
- Provide a `--quick` gate (lint, type check, last-failed tests) and a full
  gate via the *store's* `openspec/config.yaml` `orchestration.gate_quick` /
  `gate_full` — never in the project, which must not contain `openspec/`.
- Add the workspace root to version-control ignore rules; fix validation
  scripts that assume real directories rather than symlinks (`find -H`).
- Optional deterministic enforcement: a pre-execution hook that intercepts
  commit/merge/push on the main checkout's trunk and requires approval,
  while allowing everything rooted under the workspace directory — makes
  Gate 2 impossible to skip even if an agent forgets the rule.

## Adapting

Replace before reuse: specialist roles and ownership; the propose/apply/
archive workflow names; the concurrency cap and fix-round limit (set from
measured budgets, not copied); the protected-path rule (only if some input
tree must never be modified).
