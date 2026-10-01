# Spec Delta

## Purpose

Lets any project pull this skill in through Paramount's Atlas catalog tooling instead of cloning or symlinking the repository by hand.

## ADDED Requirements

### Requirement: Repo is a valid single-skill Atlas catalog
The repository root SHALL contain an `atlas-catalog.json` that registers exactly one skill entry, whose `path` resolves to the repo's own `SKILL.md`, and whose `description` matches the description in that `SKILL.md`'s frontmatter.

#### Scenario: Catalog entry resolves to the repo's own skill
- **WHEN** an Atlas consumer adds this repository as a catalog and searches for its skill
- **THEN** exactly one skill result is returned, and installing it places a `SKILL.md` identical to the repository's own `SKILL.md`

#### Scenario: Catalog is discoverable without extra scaffolding
- **WHEN** `atlas-catalog.json` is read from the repository root
- **THEN** its `skills` map contains one entry whose `path` is `SKILL.md` (no `skills/<name>/` subdirectory is required, since the repo carries one skill at its root)

### Requirement: Skill has release metadata for versioning
The repository SHALL carry a `releases.json` recording at least an initial `1.0.0` release, associated with the catalog's skill entry, so Atlas version commands (`versions-skill`, `bump`) work against this repo without additional setup.

#### Scenario: Version history is queryable
- **WHEN** an Atlas consumer runs `atlas versions-skill` against this catalog's skill
- **THEN** at least version `1.0.0` is listed

### Requirement: Consumption is documented
The repository's README SHALL document how to add this repository as an Atlas catalog and install the skill from it, in addition to the existing non-Atlas (clone/symlink) instructions.

#### Scenario: A new consumer follows the README
- **WHEN** a reader follows the README's Atlas installation steps against this repository's URL
- **THEN** the steps result in the skill being installed with no additional undocumented steps
