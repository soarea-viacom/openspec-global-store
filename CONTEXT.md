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
  capped per project by `orchestration.concurrency`.
- **Gate**: the project's quick or full check command
  (`orchestration.gate_quick` / `gate_full` in its `openspec/config.yaml`).
- **Merge lane**: the serialized merge-trunk-then-full-gate step behind
  `<store>/.orchestration/merge.lock`.
- **Initiative**: complex work decomposed into dependency-ordered changes.

The engine's own gate is `tests/run.sh` — black-box through the
`scripts/run-change` CLI, both seams substituted (temp registry, temp
project repo).
