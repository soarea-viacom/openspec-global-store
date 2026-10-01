# Proposal

## Why

This repository is a single Claude Code skill (`SKILL.md` at the root) that today can only be adopted by cloning the repo or symlinking it into `~/.claude/skills/`. Paramount Streaming's `architectural-agentic-skills` catalog shows the preferred distribution path for internal skills: register as an [Atlas](https://atlas.docs.paramount.tech/) catalog so any project can pull it in with `atlas add-catalog` + `atlas install-skill`, get update notifications via `atlas update-skill`, and track versions through Atlas's `releases.json` convention. Atlas is already installed globally on this machine, so the integration can be built and verified end-to-end without any new setup.

## What Changes

- Add `atlas-catalog.json` at the repo root registering this repo's own `SKILL.md` as a single catalog skill entry named `openspec-orchestrator`, following the manual-registration pattern documented by Atlas (no `skills/agents/mcp-servers/hooks` scaffold directories, since this repo carries exactly one skill at its root rather than a multi-resource catalog layout).
- Add `releases.json` next to the catalog entry recording the initial `1.0.0` release, so `atlas versions-skill` and future `atlas bump` calls work.
- Document consumption in [README.md](../../../README.md): an "Install via Atlas" section with the `add-catalog` snippet, mirroring the pattern in `architectural-agentic-skills`'s README, plus a note that non-Atlas installation (symlink/clone) remains supported.
- Validate the catalog end-to-end using the globally installed `atlas` CLI against a scratch consumer directory: `atlas add-catalog` pointed at this local repo, `atlas search-skills openspec-orchestrator`, and `atlas install-skill openspec-orchestrator`, confirming the installed `SKILL.md` matches this repo's.

## Capabilities

### New Capabilities
- `atlas-catalog-integration`: this repo is installable as an Atlas skill catalog — it exposes a valid `atlas-catalog.json` entry for its own `SKILL.md`, with release metadata, that a consumer project can add via `atlas add-catalog` and install via `atlas install-skill`.

### Modified Capabilities
(none — no existing specs are affected)

## Impact

- New files: `atlas-catalog.json`, `releases.json` at repo root.
- `README.md`: new documentation section, no change to existing sections' meaning.
- No changes to `SKILL.md` behavior, `scripts/`, or the orchestration engine itself — this is a packaging/distribution addition only.
- Verification uses a scratch directory outside the repo (via the Atlas CLI's own consumer flow) and does not touch any other registered Atlas catalog or consumer config.
