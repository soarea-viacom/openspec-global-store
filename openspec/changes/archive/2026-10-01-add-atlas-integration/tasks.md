# Tasks

## 1. Catalog files

- [x] 1.1 Read `SKILL.md`'s frontmatter `description` and add root-level `atlas-catalog.json` with one `skills.openspec-orchestrator` entry (`path: "SKILL.md"`, matching `description`, `teams: ["*"]`, `required: false`) and verify it is valid JSON
- [x] 1.2 Add root-level `releases.json` with an initial `"1.0.0"` entry and verify it is valid JSON

## 2. Documentation

- [x] 2.1 Add an "Install via Atlas" section to `README.md` documenting the `atlas add-catalog` snippet for this repo's URL and `atlas install-skill openspec-orchestrator`, alongside the existing clone/symlink instructions, and verify the section renders correctly as Markdown

## 3. Verification with the installed Atlas CLI

- [x] 3.1 In a scratch directory outside the repo, run `atlas init consumer`, `atlas add-catalog file://<repo-path>`, `atlas search-skills openspec-orchestrator`, and `atlas install-skill openspec-orchestrator --yes`, and verify the installed `SKILL.md` is byte-identical to this repo's `SKILL.md`
- [x] 3.2 Run `atlas versions-skill openspec-orchestrator` from the same scratch directory and verify `1.0.0` is listed
- [x] 3.3 Delete the scratch directory and verify no files were written outside it (no changes to `~/.atlas/.atlas.json` or any other project's config)
