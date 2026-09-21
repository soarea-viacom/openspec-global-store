# Proposal: project-skill stage mapping (Propose / critique / Verify)

**Status:** sketch — not adopted, not wired into `SKILL.md`, `AUTONOMOUS-ORCHESTRATION.md`,
or any script. Supersedes and fully replaces the earlier
`docs/proposals/skill-executor-routing.md` (deleted) — see **History** at the end for what
changed and why.

## Problem

The orchestrator dispatches Propose (drafting the delta spec), Propose's critique, and
Verify through exactly one axis: an effort tier (`mechanical` / `standard` / `deep`)
resolved to a model id via `model_for_tier` in [`scripts/lib.sh`](../../scripts/lib.sh). It
has no awareness of project-local Claude Code skills under `.claude/skills/` — a project's
own `code-review` skill, a domain-specific spec drafter, a project's own test-authoring
skill — even when one of those is obviously the right tool for one of these three phases.

## Goal

Let a project name, per stage, which of its own skills should be used there — with the
mapping living entirely in the project's own OpenSpec config, no changes to the skills
themselves, and no new trust machinery beyond "it's in the project's config."

## Non-goals

- **Not `subagent_type` coverage.** Only project skills (`.claude/skills/<name>`). Custom
  Agent-tool subagent types are out of scope for this doc; if wanted later, they need their
  own pass, since their trust story isn't identical to a skill's.
- **Not Apply or Fix rounds.** Scoped to exactly the three phases named above (`plan` /
  `critic` / `test`, matching the drafting → critique → verify shape). Apply and Fix rounds
  are untouched by this proposal.
- **Not a change to any structural rule.** The disjoint-files check, the
  no-git-writes-except-orchestrator rule, fresh-context isolation, and the quick/full gates
  are mechanical and apply regardless of what drafts, critiques, or verifies a change —
  nothing here touches them.

## Design

### Config shape

```yaml
# openspec/config.yaml (resolved root — local or external, per SKILL.md Step 1)
orchestration:
  stage_skills:
    plan: project-spec-drafter                       # at most one — see below
    critic: [project-code-review]
    test: [project-test-skill, project-contract-checker]
```

- `plan` — at most **one** skill name (a bare string, not a list). Drafting isn't a
  pass/fail check; "run two drafters and require both to pass" has no coherent meaning the
  way it does for a checker. Omitted → Propose runs exactly as today (deep-tier model
  drafts).
- `critic` / `test` — a **list** of zero or more skill names. Omitted or empty → that
  stage's built-in checker runs exactly as today, nothing changes.

Nothing is written into any skill's own frontmatter, ever. A skill is used for a stage
purely because its name appears in this map — no tag on the skill, no separate trust
field, no project-wide on/off switch. Being listed in the project's own
`openspec/config.yaml` **is** the opt-in; there is nothing else to configure.

### Why config-only is enough — no separate trust step

An earlier version of this idea put the declaration on the *skill* — a self-declared
frontmatter tag (`orchestrator_stage: critic`), gated by an additional self-declared
`checker_independent: true`, itself gated by a project-wide switch before any of it took
effect. All three layers existed to answer the same question: who is vouching for this
skill being used here? Moving the mapping into the project's own config answers that
directly — whoever edited `openspec/config.yaml` is the one vouching, the same way editing
`gate_full` or `model_deep` already is an unaudited, fully-trusted project decision. There
is no longer a separate party (a skill's own author, who has no idea their skill might be
used this way) whose self-declaration needs a second gate. See **History** below for the
layers this replaced.

### Multiple skills per checker stage

For `critic` and `test`, every skill named in that stage's list runs. The stage is only
clean if **none** of them report a blocking finding — findings from every mapped skill
feed into the existing single critique/verify report, each finding tagged with which skill
produced it. One mapped skill returning `blocking` is enough to fail the stage, the same
as today's single built-in checker returning `blocking`.

### Mapped skills stack; they never replace the built-in checker (`critic` / `test`)

For `critic` and `test`, a `stage_skills` entry adds an *additional* check; it does not
turn off the built-in one (`model critic` / `model verify` in `scripts/lib.sh` — the
tier/model checker already guaranteed distinct from the generator's model). That guarantee
is the one thing the engine can vouch for on its own; a mapped skill is extra signal on top
of it, not a substitute for it. A stage with zero mapped skills gets the built-in check
only; a stage with one or more mapped skills gets the built-in check *and* all of them —
never fewer checks than the default.

`plan` is the exception, structurally: there's no "built-in checker" for drafting to stack
against — drafting is the generator step itself. Mapping a skill to `plan` replaces the
deep-tier model as who drafts. The draft is still checked afterward exactly as always,
by the (stacked) `critic` stage.

### No guard against an interactive mapped skill

Nothing in this design checks whether a mapped skill is safe to run unattended. If a
project maps a skill that stops to interview a human mid-run (plenty of skills are built
exactly that way, on purpose, for other uses), the change simply stalls in whichever phase
called it — visible the same way any other broken step is visible, not something the
engine detects in advance. There's no reliable static way to tell "will this skill try to
talk to someone" without running it, so a guard here would be theater. This is the
project's own mistake to notice and fix, the same category of risk as a broken
`gate_full` command.

### Resolution, per stage

```
plan:   stage_skills.plan set   -> that skill drafts, instead of the deep-tier model
        stage_skills.plan unset -> Propose runs exactly as today

critic: stage_skills.critic non-empty -> built-in critic AND every listed skill run;
                                          any one reporting blocking fails the stage
        stage_skills.critic empty/unset -> built-in critic only, exactly as today

test:   stage_skills.test non-empty -> built-in Verify AND every listed skill run;
                                        any one reporting blocking fails the stage
        stage_skills.test empty/unset -> built-in Verify only, exactly as today
```

A read-only helper, analogous to `model_for_tier`, would do the lookup:

```
stage_skills <store-slug> <stage>   # -> newline-separated skill names, empty if unset
```

mirroring the existing `awk`-over-`orchestration:` block pattern already used by
`model_for_tier` / `gate_command` in `scripts/lib.sh` — same file, same config section, no
new state or registry.

## History

The first pass at this idea (`skill-executor-routing.md`, now deleted) put the mapping on
the skill itself via a self-declared frontmatter tag, required a second self-declared field
(`checker_independent: true`) before a tagged skill could be used for a checker stage, and
gated the whole mechanism behind a project-wide switch (`orchestration.allow_tagged_skills`)
before any of it took effect. Each layer was solving the same underlying question — who is
vouching for this skill being used here — with the skill author as the only candidate
answer at every layer, which is why each one kept feeling insufficient on its own.

Moving the mapping into the project's own `openspec/config.yaml` answers that question
directly (the project itself vouches for it, no self-declaration involved) and made all
three layers redundant at once: the frontmatter tag (replaced by the config map), the
`checker_independent` field (a config entry already implies the project trusts it, full
stop), and the switch (the config entry *is* the switch). What survived unchanged from the
first pass: the underlying phases in scope, and the "stack, don't silently replace, the
one check the engine can vouch for" principle for `critic`/`test`.

## Relationship to existing docs

If adopted, this would extend, not replace, the **Model/effort routing** section of
`AUTONOMOUS-ORCHESTRATION.md` and the `model_for_tier`/`checker_model` functions in
`scripts/lib.sh`. No change is proposed here to `SKILL.md`'s Step 0–3 (preflight, root
resolution, the 3-phase engine) or to the phase diagram in `README.md` — this sketch only
touches *how* Propose's draft and the critic/Verify checks are produced, never *which*
phases exist or *when* a human gate fires.
