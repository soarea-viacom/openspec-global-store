# Design

## Context

See [proposal.md](proposal.md) - Why. `scripts/lib.sh`'s `store_path()` already resolves purely from the registry's `local_path` field (confirmed by reading the function - it does not hardcode any path), so this is a documentation-and-data-migration change, not a code change to the engine.

## Goals / Non-Goals

**Goals:**
- Stop creating new external stores directly under `$HOME`.
- Move the six stores that already exist there, without losing their git history or breaking their registration.

**Non-Goals:**
- Changing `scripts/lib.sh` logic - it's already path-convention-agnostic.
- Touching local-mode stores (their `local_path` *is* the project root; this change only affects external mode).
- Changing the OpenSpec CLI's own `registry.yaml` location - that's already correct and untouched.

## Decisions

**Target path: `~/.local/share/openspec/stores/<slug>/` (or `$XDG_DATA_HOME/openspec/stores/<slug>` when set), matching the CLI's own data dir exactly.**
Alternative considered: a simpler hidden dir like `~/.openspec-stores/`. Rejected because it introduces a *second* XDG-adjacent convention instead of reusing the one the CLI already established for `registry.yaml` - one hidden location to know about beats two.

**Migration via `unregister` (keeps files) → `mv` → `register --id <id> <new-path> --yes`, one store at a time.**
`openspec store` has no "move" or "relocate" command. `unregister` explicitly only forgets the registration without touching files (per its own `--help` text), which makes the sequence safe to interrupt: a store that's been unregistered but not yet moved is still fully intact on disk at its old path, and can be re-registered there if something goes wrong before the `mv`.

**Do a dry inventory pass before touching anything.**
Before migrating, confirm (already done during proposal research): no `openspec workset` entries exist, and no other project's config references these stores by absolute path rather than by id. This means the only thing that needs updating after the move is the registry itself - nothing external depends on the old paths. If that inventory had found a reference, this proposal would need to list updating it as a task.

## Risks / Trade-offs

- [`mv` across filesystems/volumes could be a copy+delete instead of a rename, leaving a window where a crash loses data] → Mitigation: `~/.local/share` and `~/openspec-stores`/`~/openspec-global-store` are on the same home volume for a normal macOS user account; verify each store's new location has the expected git history (`git log` works) before deleting anything at the old path, and only remove the old path after that check passes.
- [A store's own committed `.openspec-store/store.yaml` doesn't encode a path (only `id`), so nothing inside the moved repo itself needs editing - but this is worth stating explicitly so a future reader doesn't assume otherwise] → Not a risk once stated; no mitigation needed.
