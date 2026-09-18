# Domain glossary

- **Store**: a directory holding OpenSpec artifacts and orchestration state
  for one target project, resolved by slug via the CLI registry
  (`OPENSPEC_STORE_REGISTRY`).
- **Change**: the unit of branch, workspace, gate and merge
  (`change/<name>` branch + worktree in the target project).
- **State module**: `scripts/lib.sh` (`state_root`, `state_field`,
  `state_write`) — sole owner of the state-file YAML dialect under
  `<store>/.orchestration/state/`. Nothing else parses those files.
- **Slot**: a concurrency token under `<store>/.orchestration/slots/`,
  capped by `orchestration.concurrency` in the store's config.
- **Seam list**: the `seams` field in a change's state file, written during
  Propose via `scripts/run-change state set --store <slug> --name <change>
  seams "<seam>=<file>,<file>;<seam>=<file>"` — one `name=file,file,...`
  group per seam, groups separated by `;`. The sole source the
  disjoint-files check reads from; nothing infers seams from the delta spec
  prose or from the code after the fact.
- **Session log**: `<store>/.orchestration/state/<change>.sessions.log` —
  an append-only, one-line-per-run history, written via `scripts/run-change
  session append --store <slug> --name <change> key value [key value ...]`
  and read via `session list`. Distinct from the per-change state file: the
  state file holds the *current* record for a change (one value per key,
  upserted in place); the session log holds *every* run's record (`role`,
  `phase`, `gates_hit`, `transcript_id`, `model`, `tier`), appended, never
  rewritten.
- **Gate**: the project's quick or full check command
  (`orchestration.gate_quick` / `gate_full` in the *store's*
  `openspec/config.yaml` — single rule: a target project must not contain
  an `openspec/` folder; the engine refuses one that does).
- **Merge lane**: the serialized merge-trunk-then-full-gate step behind
  `<store>/.orchestration/merge.lock`.
- **Initiative**: complex work decomposed into dependency-ordered changes.

The engine's own gate is `tests/run.sh` — black-box through the
`scripts/run-change` CLI, both seams substituted (temp registry, temp
project repo).
