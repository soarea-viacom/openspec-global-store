# Spec Delta

## Purpose

Pins down where this skill creates and expects external-mode OpenSpec store content on disk, so it doesn't clutter the user's home directory or drift from where the OpenSpec CLI already keeps its own registry.

## ADDED Requirements

### Requirement: External stores live under the XDG data directory
When Step 1 routes a project to external mode and the store does not yet exist, the skill SHALL create it at `~/.local/share/openspec/stores/<slug>` (or `$XDG_DATA_HOME/openspec/stores/<slug>` when `XDG_DATA_HOME` is set), matching the directory the OpenSpec CLI already uses for its own `registry.yaml`. The skill SHALL NOT create new external-mode store content directly under `$HOME`.

#### Scenario: New external store is created
- **WHEN** a project has no local `openspec/` folder and no store already registered for its slug
- **THEN** `openspec store setup <slug> --path ~/.local/share/openspec/stores/<slug>` is run, and the resulting store is registered with that path

#### Scenario: Existing external store keeps working regardless of its location
- **WHEN** a store is already registered for a project's slug, at any path
- **THEN** the skill uses the registered path as-is (from `openspec store list`) and does not attempt to move it

### Requirement: Workset convenience reflects the new location
The optional `openspec workset create` convenience (external mode only) SHALL reference the spec member at the store's actual registered path, not a hardcoded `~/openspec-stores/<slug>` guess.

#### Scenario: Workset is created for a project in external mode
- **WHEN** the user accepts the optional workset convenience for a project routed to an external store
- **THEN** the `spec=` member path passed to `openspec workset create` matches that store's path as returned by `openspec store list`
