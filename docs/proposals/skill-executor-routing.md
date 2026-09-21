# Proposal: per-phase executor overrides (project skills & subagent types)

**Status:** sketch — not adopted, not wired into `SKILL.md`, `AUTONOMOUS-ORCHESTRATION.md`,
or any script. Nothing in this doc changes current orchestrator behavior; it exists to
record the shape of a possible extension for later discussion. It remains anticipatory —
no project has surfaced a concrete case for it yet — so it's parked here rather than
pushed toward implementation.

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
  executor_propose: "skill:project-spec-drafter"   # generator-side, same rules as Apply
  executor_apply: "subagent:general-purpose"       # applies uniformly to every dispatch
                                                    # group in the phase — no per-seam override
  executor_fix: "skill:project-lint-fixer"
  executor_critique: null     # checker-side — requires trust below
  executor_verify: null       # checker-side — requires trust below

  # Per-property trust, keyed by the exact executor reference used above.
  # An executor must be listed here, with the relevant property true, before
  # the engine will dispatch it — this is what makes an executor_* override
  # actually take effect, not just naming it.
  trusted_executors:
    "skill:project-spec-drafter":
      autonomous_safe: true
    "subagent:general-purpose":
      autonomous_safe: true
    "skill:project-lint-fixer":
      autonomous_safe: true
    "skill:project-code-review":
      autonomous_safe: true
      checker_safe: true       # only this one may run executor_critique / executor_verify
```

Two executor kinds, distinguished by a prefix (kept distinct rather than unified into one
namespace — a skill and an agent type sharing a name, e.g. both called `review`, would
otherwise be a silent collision):

- `subagent:<type>` — dispatch via the Agent tool's `subagent_type`: a built-in type
  (`Explore`, `Plan`, `general-purpose`, …) or a custom one the project defines under
  `.claude/agents/*.md`.
- `skill:<name>` — invoke a project-local Claude Code skill (`.claude/skills/<name>`) as
  the phase's dispatch mechanism instead of a bare model call.

### Resolution order

For a given phase, the calling agent resolves the executor before dispatching:

1. `orchestration.executor_<phase>` set in the resolved root's config → look it up in
   `orchestration.trusted_executors`.
   - Not present in `trusted_executors` at all, or the skill/agent it names doesn't
     actually exist in the target project → **hard error to Gate 1** (see failure mode,
     below) — never a silent fallback.
   - Present but missing `autonomous_safe: true` → same hard error: an executor without
     that property could be an interactive skill (see restriction below) and stall an
     autonomous run indefinitely.
   - `executor_critique` / `executor_verify` additionally require `checker_safe: true` on
     the same entry.
   - All required properties present → dispatch through it, in place of a bare model call.
2. `orchestration.executor_<phase>` unset → fall back to today's path exactly: tier for
   the phase (per the existing Model/effort routing table) → `model_for_tier` → model id
   → bare model call.

Step 2 is load-bearing for backward compatibility: a project that never sets an
`executor_*` key sees byte-for-byte the same dispatch behavior this engine has today.

Two new read-only helpers, analogous to `model_for_tier`, would do the lookups:

```
executor_for_phase <store-slug> <phase>            # -> "subagent:<type>" | "skill:<name>" | "" (unset)
executor_trust <store-slug> <executor-ref> <prop>  # -> "true" | "" (checks trusted_executors)
```

mirroring the existing `awk`-over-`orchestration:` block pattern already used by
`model_for_tier` / `gate_command` in `scripts/lib.sh` — same file, same config section,
no new state or registry.

### Why trust is a project-level allowlist, not skill frontmatter

Two properties gate an override, and both are about trust the *project* extends, not
something a third-party skill can credibly claim about itself:

- **`autonomous_safe`** — the engine is autonomous-only: it stops for a human only at
  Gate 1 and Gate 2, never mid-phase. Plenty of skills are designed to interview a human
  interactively (the `grilling` skill driving this very design session is a working
  example) — dispatching one of those as an `executor_<phase>` would silently stall a
  change with no gate to catch it. This property has to hold for *every* override,
  generator-side or checker-side.
- **`checker_safe`** — required in addition, only for `executor_critique` /
  `executor_verify`. The checker-loop design exists because a model is a weak reviewer of
  its own output; `checker_model` in `scripts/lib.sh` already refuses to let Verify or the
  critic collide with the generator's model, escalating tier instead. A named skill or
  subagent type has no equivalent guarantee — nothing about a skill's own frontmatter
  could prove it doesn't share state, transcript, or authorship with whatever generated
  the artifact it would be checking.

A skill's own frontmatter is written by that skill's author, who in general has no idea
it might later be dispatched as an autonomous checker inside someone else's engine —
trusting a self-declared field there is trusting the wrong party. `trusted_executors`
puts the declaration in the hands of whoever configured *this* project's orchestration,
who is the only one actually positioned to vouch for either property, and keeps both
properties auditable in one place per project.

### Generator-side vs. checker-side scope

- **Generator-side phases** — Propose, Apply, Fix rounds, the mechanical dead-code sweep —
  only need `autonomous_safe`. Propose is included here even though it drafts the artifact
  everything else depends on: the critic checks it immediately afterward the same way it
  would check a bare-model draft, so a bad Propose executor is caught by the existing
  critique loop, not by restricting who may run Propose. Whatever runs still can't write
  git directly and still must stay inside the disjoint-files check for its seam; those are
  structural, not tied to model or executor choice.
- **Checker-side phases** — Propose's critique, Verify — need `autonomous_safe` *and*
  `checker_safe`. Missing either → the engine refuses the override and falls back to
  tier/model, the same way a model collision falls back to a higher tier today.

This keeps the independence property enforced at the same strength it has now; it does
not add a new way to defeat it.

### Apply-phase granularity

Apply already fans out into multiple concurrent dispatch groups, one per seam (existing
engine behavior, unrelated to this proposal). `executor_apply` applies uniformly to every
dispatch group in the phase — there is no per-seam override in this design. Per-seam
granularity (some seams on a project skill, others on tier/model) is a real possible future
need, but it's explicitly deferred rather than half-solved here: it would multiply the
config schema (and the trust-lookup surface) for a feature that's still speculative.

### Model/tier interaction per executor kind

The two executor kinds sit differently relative to `model_*`/tier, because the two
dispatch tools they go through are shaped differently — this is a fact about the `Skill`
and `Agent` tools, not a design choice:

- **`skill:<name>` cannot be pinned to a tier's model at all.** The `Skill` tool's own
  interface takes a skill name and args, nothing else — there is no caller-side model
  parameter. Whatever model a skill runs at is fixed by its own definition/session, and
  this proposal does not try to compose with that. Cost control for a skill-routed phase
  is out of this engine's hands, by construction, not by omission.

  This creates a real gap, though: `checker_model` (in `scripts/lib.sh`) escalates tier
  when Verify's or the critic's resolved model would otherwise collide with the
  generator's — a collision check needs *some* string to compare, and a skill-routed
  phase has no real model id to offer it. The engine records a synthetic value instead of
  leaving the field empty or stale: `session append ... model "skill:<name>"` for a
  skill-routed phase, so `last_model_for_phases` still returns something, and it can never
  collide with a genuine model id (real ids don't carry a `skill:` prefix) — an empty
  string risks two unrelated empty entries reading as "the same model" to a naive
  comparison, which a synthetic string rules out structurally.

- **`subagent:<type>` *can* be pinned — the `Agent` tool takes a `model` override — but
  the resolved tier model is only a default, never a clobber.** The Agent tool's own
  override precedence already lets a caller's `model` param beat an agent definition's own
  frontmatter; this proposal deliberately does not exercise that when the agent defines
  its own model. If a project named a specific `subagent_type` for a phase, it chose that
  agent's tuned behavior on purpose — a config value two layers away (the store's
  `orchestration.model_<tier>`) silently overriding it would surprise whoever wired it in.
  So: agent definition specifies a model → that wins, tier is not passed. Agent definition
  leaves `model` unset → the phase's resolved tier model is passed through as the
  `Agent` call's `model` param, so `orchestration.model_deep` etc. still governs cost for
  agents that don't care enough to pin one themselves.

## Open questions

None remain from the design-review sessions — every question raised has a decision
recorded in the **Design** section above (trust allowlist location, the generator/checker
split for Propose, Apply's granularity, the missing-executor failure mode, the
`subagent:`/`skill:` prefixes, and the model/tier interaction per executor kind). This
stays sketch-status until a project surfaces a concrete case to build it against.

## Relationship to existing docs

If adopted, this would extend, not replace, the **Model/effort routing** section of
`AUTONOMOUS-ORCHESTRATION.md` and the `model_for_tier` function in `scripts/lib.sh`. No
change is proposed here to `SKILL.md`'s Step 0–3 (preflight, root resolution, the 3-phase
engine) or to the phase diagram in `README.md` — this sketch only touches *how* a phase's
worker is dispatched, never *which* phases exist or *when* a human gate fires.
