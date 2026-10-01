# Design

## Context

See [proposal.md](proposal.md) - Why. This repo currently distributes its single skill by symlinking/cloning the repo root directly into `~/.claude/skills/<name>`, because `SKILL.md` lives at the repo root rather than under a `skills/<name>/` subdirectory.

## Goals / Non-Goals

**Goals:**
- Make this repo installable through the Atlas CLI the same way `architectural-agentic-skills` is.
- Verify the catalog actually works using the globally installed `atlas` CLI, not just by eyeballing the JSON.

**Non-Goals:**
- Restructuring the repo into a multi-resource catalog layout (`skills/`, `agents/`, `mcp-servers/`, `hooks/`). This repo ships exactly one resource - itself.
- Publishing to the shared `paramount-streaming/atlas` or `architectural-agentic-skills` repositories. This change only makes *this* repo a valid, independently addable catalog.
- Changing how the skill is invoked or what it does.

## Decisions

**Root-level `atlas-catalog.json` with `path: "SKILL.md"`, no `skills/` subdirectory.**
Atlas's catalog format only requires the `path` field to resolve to a `SKILL.md`/`AGENT.md` file relative to the catalog root - it does not require the conventional `skills/<name>/` layout (confirmed against the Atlas CLI's own `catalog-format.md` reference and the "adding a skill manually" example). Moving `SKILL.md` into `skills/openspec-orchestrator/SKILL.md` was considered and rejected: it would break the existing symlink-based install path (`~/.claude/skills/openspec-orchestrator -> <repo>`) and every doc/example in this repo that assumes `SKILL.md` is at the root, for no functional gain - Atlas does not need it.

**Hand-write `atlas-catalog.json` and `releases.json` instead of running `atlas init author` / `atlas add-skill`.**
`atlas init author` scaffolds empty `skills/`, `agents/`, `mcp-servers/`, `hooks/` directories this repo will never use, and `atlas add-skill` assumes the skill doesn't exist yet and will create a new `SKILL.md` rather than pointing at the existing one. Hand-writing both files (matching the documented manual-registration example) avoids that scaffolding and keeps `SKILL.md` untouched.

**Validate with a scratch consumer directory outside the repo.**
`atlas add-catalog` and `atlas install-skill` both write to whichever project's `.atlas.json` / `.claude/skills/` is current. Running them from a throwaway directory (not this repo, not any other real project) proves the catalog resolves and installs correctly without mutating any real consumer config or the global `~/.atlas/.atlas.json`.

## Risks / Trade-offs

- [The `description` in `atlas-catalog.json` can drift from `SKILL.md`'s frontmatter description over time] → Mitigation: the spec requirement calls this out explicitly; keep them in sync by hand until/unless Atlas adds a lint for it.
- [`releases.json` requires manual bumps going forward (`atlas bump skill openspec-orchestrator ...`) for consumers to see new versions] → Mitigation: out of scope here; noted in README so future changes to this skill remember to bump.
