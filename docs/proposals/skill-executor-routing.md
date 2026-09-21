# Proposal: per-phase executor overrides (project skills & subagent types)

**Status:** sketch — not adopted, not wired into `SKILL.md`, `AUTONOMOUS-ORCHESTRATION.md`,
or any script. Nothing in this doc changes current orchestrator behavior; it exists to
record the shape of a possible extension for later discussion.

## Problem

The orchestrator dispatches every worker — Propose, Apply's dispatch groups, Fix rounds,
the Propose critic, Verify — through exactly one axis: an effort **tier**
(`mechanical` / `standard` / `deep`) resolved to a model id via `model_for_tier` in
[`scripts/lib.sh`](../../scripts/lib.sh). It has no awareness of anything else the target
project might already have:

- project-local Claude Code skills under `.claude/skills/` (a lint-fix pipeline, a
  domain-specific code generator, a project's own review skill),
- named `subagent_type`s the project or the calling session already defines
  (`Explore`, `Plan`, `general-purpose`, or custom agents under `.claude/agents/*.md`).

A project can end up with a skill that is obviously the right tool for a phase — e.g. a
`fix-flaky-test` skill for the mechanical-tier triage step, or a project's own
`code-review` skill as an extra Verify-time read — and the orchestrator today has no path
to reach for it. Everything runs through a bare model call at whatever tier the phase
calls for.

## Goal

Let a project opt in, per phase, to a specific execution mechanism instead of a bare
model call — without changing anything for a project that doesn't opt in, and without
weakening the generator/checker independence the checker-loop design (Propose's critic,
Verify) depends on.

## Non-goals

- Not a general "use any skill for anything" mechanism. Scope is the fixed set of phases
  the engine already dispatches (see the phase list in `AUTONOMOUS-ORCHESTRATION.md`).
- Not a replacement for the tier/model table. Tiers still exist and still gate cost; this
  is an *additional* axis, resolved first, falling back to tier/model when unset.
- Not a way to skip the disjoint-files check, the no-git-writes-except-orchestrator rule,
  or fresh-context isolation. Whatever executor runs a phase still obeys those
  structurally, the same as a bare model call does today.

## Design

### Config shape (additive, all keys optional)

```yaml
# openspec/config.yaml (resolved root — local or external, per SKILL.md Step 1)
orchestration:
  model_mechanical: claude-haiku-4-5-20251001   # unchanged, existing keys
  model_standard: claude-sonnet-5
  model_deep: claude-opus-5

  # new, all optional — omit any/all of these and behavior is identical to today
  executor_apply: "subagent:general-purpose"
  executor_fix: "skill:project-lint-fixer"
  executor_propose: null      # see restriction below — generator-side only by default
  executor_critique: null     # checker-side — requires the declaration below
  executor_verify: null       # checker-side — requires the declaration below
```

Two executor kinds, distinguished by a prefix:

- `subagent:<type>` — dispatch via the Agent tool's `subagent_type`: a built-in type
  (`Explore`, `Plan`, `general-purpose`, …) or a custom one the project defines under
  `.claude/agents/*.md`.
- `skill:<name>` — invoke a project-local Claude Code skill (`.claude/skills/<name>`) as
  the phase's dispatch mechanism instead of a bare model call.

### Resolution order

For a given phase, the calling agent resolves the executor before dispatching:

1. `orchestration.executor_<phase>` set in the resolved root's config → use it.
2. Unset → fall back to today's path exactly: tier for the phase (per the existing
   Model/effort routing table) → `model_for_tier` → model id → bare model call.

Step 2 is load-bearing for backward compatibility: a project that never sets an
`executor_*` key sees byte-for-byte the same dispatch behavior this engine has today.

A new read-only helper, analogous to `model_for_tier`, would do the lookup:

```
executor_for_phase <store-slug> <phase>   # -> "subagent:<type>" | "skill:<name>" | "" (unset)
```

mirroring the existing `awk`-over-`orchestration:` block pattern already used by
`model_for_tier` / `gate_command` in `scripts/lib.sh` — same file, same config section,
no new state or registry.

### The generator/checker restriction

The checker-loop design exists because a model is a weak reviewer of its own output —
`checker_model` in `scripts/lib.sh` already refuses to let Verify or the critic collide
with the generator's model, escalating tier instead. A named skill or subagent type has
no equivalent guarantee: nothing today tells the engine whether `skill:foo` is
independent of whatever produced the artifact it would be checking.

So the restriction is asymmetric:

- **Generator-side phases** (Apply, Fix rounds, the mechanical dead-code sweep) — free to
  override. Whatever runs still can't write git directly and still must stay inside the
  disjoint-files check for its seam; those are structural, not tied to model choice.
- **Checker-side phases** (Propose's critique, Verify) — override allowed only if the
  named skill/agent explicitly declares itself checker-safe: a new field the skill's own
  frontmatter would need to carry (e.g. `checker_safe: true`), asserting it does not share
  state, transcript, or authorship with whatever generated the thing it's checking. No
  declaration → the engine refuses the override and falls back to tier/model, the same
  way a model collision falls back to a higher tier today.

This keeps the independence property enforced at the same strength it has now; it does
not add a new way to defeat it.

## Open questions

- Where does a `checker_safe` declaration actually live — new skill-frontmatter
  convention, or a project-level allowlist in `orchestration.config.yaml` naming which
  skills/agents are trusted as checkers? The former scales better across projects; the
  latter is easier to audit per-project.
- Does a `skill:<name>` executor get a model tier at all, or does the skill own its own
  model choice entirely? If the former, `executor_*` and `model_*` need to compose (skill
  runs, but constrained to the phase's tier's model); if the latter, cost control for that
  phase moves out of this engine's hands.
- Should `subagent:<type>` support passing the phase's resolved tier/model through as a
  parameter (so a custom agent still respects `orchestration.model_deep` etc.), or treat
  the two as fully separate knobs?
- Failure mode when a named skill/agent doesn't exist in the target project at dispatch
  time — hard error (change goes to Gate 1) or silent fallback to tier/model? Silent
  fallback is more forgiving but could mask a config typo for a long time.

## Relationship to existing docs

If adopted, this would extend, not replace, the **Model/effort routing** section of
`AUTONOMOUS-ORCHESTRATION.md` and the `model_for_tier` function in `scripts/lib.sh`. No
change is proposed here to `SKILL.md`'s Step 0–3 (preflight, root resolution, the 3-phase
engine) or to the phase diagram in `README.md` — this sketch only touches *how* a phase's
worker is dispatched, never *which* phases exist or *when* a human gate fires.
