# Tasks

## 1. Documentation

- [x] 1.1 Update `SKILL.md` (Step 0.2, Step 2, Step 3's `--store` paragraph, "Optional convenience", Guardrails) to reference `~/.local/share/openspec/stores/<slug>` instead of `~/openspec-stores/<slug>`, and verify no remaining `openspec-stores` reference is left with `grep -n openspec-stores SKILL.md`
- [x] 1.2 Update `AUTONOMOUS-ORCHESTRATION.md`'s reference to the old path, and verify with `grep -n openspec-stores AUTONOMOUS-ORCHESTRATION.md`
- [x] 1.3 Update `README.md` (architecture diagram, mode comparison table, prose) and verify with `grep -n openspec-stores README.md`
- [x] 1.4 Update the doc comment in `scripts/lib.sh` and verify with `grep -n openspec-stores scripts/lib.sh`

## 2. Migrate existing stores

- [x] 2.1 For each of `chess-game`, `sail-game`, `tetris-game`, `github-com-paramount-streaming-ctv-lite-monorepo`, `github-com-paramount-streaming-salescopymgr-tool-monorepo`, `global-store`: record its current `local_path` from `openspec store list --json`, run `openspec store unregister <id>`, `mv` the directory to `~/.local/share/openspec/stores/<id>`, verify `git -C ~/.local/share/openspec/stores/<id> log -1` succeeds (history intact), then `openspec store register --id <id> ~/.local/share/openspec/stores/<id> --yes`. **Deviation found during execution:** `global-store`'s registered path (`/Users/827006/openspec-global-store`) did not exist on disk — a pre-existing phantom registry entry (the same stale state that caused this repo's own `.openspec-store/store.yaml` id bug fixed in a prior change). Confirmed with the user there was nothing to recover; left it unregistered rather than inventing a fresh empty store. The other five stores migrated and re-registered successfully.
- [x] 2.2 Run `openspec store list --json` and verify all remaining ids now resolve to paths under `~/.local/share/openspec/stores/`, and `openspec doctor --store <id>` reports healthy for each (five migrated stores; `global-store` intentionally absent per the deviation above)
- [x] 2.3 Remove the now-empty `~/openspec-stores/` directory (after clearing a stray `.DS_Store`) and confirm `~/openspec-global-store` is gone; verified with `ls ~` that neither remains

## 3. Verification

- [x] 3.1 Run `./tests/run.sh` (this project's `gate_full`) and verify it still passes
