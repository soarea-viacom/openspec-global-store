# Proposal

## Why

External-mode stores currently live at `~/openspec-stores/<slug>` and the bootstrap/demo store at `~/openspec-global-store` — both directly under `$HOME`, cluttering it alongside Desktop/Documents/Downloads. The OpenSpec CLI itself already keeps its own bookkeeping (`registry.yaml`) under the XDG data directory (`~/.local/share/openspec/stores/`); external store content should live in that same directory tree instead of introducing a second, home-root convention.

## What Changes

- **BREAKING** (for this skill's own convention, not for the OpenSpec CLI): new external stores are created under `~/.local/share/openspec/stores/<slug>/` instead of `~/openspec-stores/<slug>/`.
- Update [SKILL.md](../../../SKILL.md) (Step 0.2, Step 2, Step 3, "Optional convenience", Guardrails) and [AUTONOMOUS-ORCHESTRATION.md](../../../AUTONOMOUS-ORCHESTRATION.md) to reference the new path.
- Update [README.md](../../../README.md) (architecture diagram, mode comparison table, prose) to match.
- Update the doc comment in [scripts/lib.sh](../../../scripts/lib.sh) (no functional change there — `store_path()` already reads `local_path` from the registry rather than hardcoding a path).
- Migrate every store currently registered under the old `~/openspec-stores/` / `~/openspec-global-store` locations (`chess-game`, `sail-game`, `tetris-game`, `github-com-paramount-streaming-ctv-lite-monorepo`, `github-com-paramount-streaming-salescopymgr-tool-monorepo`, `global-store`) to the new location, preserving each store's id, git history, and registration. (`global-store` turned out to be a phantom registry entry with no backing directory - see tasks.md 2.1 for what was found and how it was resolved.)

## Capabilities

### New Capabilities
- `external-store-location`: defines where this skill creates and expects to find external-mode store content on disk.

### Modified Capabilities
(none — no existing specs cover this; the convention was previously stated only in SKILL.md prose)

## Impact

- Documentation: `SKILL.md`, `AUTONOMOUS-ORCHESTRATION.md`, `README.md`, a comment in `scripts/lib.sh`.
- Local machine state: six existing store directories physically moved and re-registered in `~/.local/share/openspec/stores/registry.yaml`. No project outside this skill's own registry references these stores by path (confirmed: no worksets exist, no shell rc files or other project configs reference the old paths), so nothing else needs updating.
- No change to `scripts/run-change` logic or test behavior — `tests/run.sh` already exercises store resolution purely through the registry, independent of path convention.
