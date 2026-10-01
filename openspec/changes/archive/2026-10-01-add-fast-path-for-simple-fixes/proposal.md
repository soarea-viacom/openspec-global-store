# Proposal

## Why

Every change today pays for full Propose exploration and the standard round-trip even when the request is a small, clearly non-breaking fix (typo, localized bug, no API/schema/behavior-contract change). The user wants small fixes to reach critique faster, while anything that turns out to touch a public contract still gets the full process. Gate 0 (mandatory human acceptance before Apply) must stay in force either way — this only shortens how much drafting happens before critique, not the gates.

## What Changes

- Document a **fast path** in SKILL.md Step 3: for a request the agent judges to be a simple, non-breaking fix, skip the extended Phase 1 exploration and draft the smallest delta spec that captures the fix, then send it straight to critique.
- If, once the code is examined, the fix turns out to touch a public API, change behavior other code depends on, require a migration, or otherwise ripple outside the local fix, fall back to the normal full Phase 1 process — reclassification is expected and not a failure of the fast path.
- Document the same exception in AUTONOMOUS-ORCHESTRATION.md's Propose step (step 3 of Phases): the `deep`-tier Propose step may skip extended exploration for a fix meeting the same non-breaking criteria, but still produces a delta spec and seam list, and still goes through Critique and Gate 0 unchanged.
- No change to Gate 0, Gate 1, Gate 2, the critique standards, the checker-loop budgets, or any script (`scripts/run-change`, `scripts/lib.sh`). This is additive documentation of an existing judgment call (how much to explore before drafting), not a new phase, state field, or CLI command.
- Document that a gate's accept/revise (or other fixed-choice) question must be asked as a structured choice when the host interface supports one (e.g. buttons), not only as free text — applies to Gate 0's accept-or-revise and any other gate whose answer is one of a small fixed set. This does not change what the gates ask or what answers are valid, only how the choice is presented to the human.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
(none — this documents process/orchestration guidance for the agents running the engine, not a tracked spec capability; no spec-level behavior changes. Precedent: Gate 0 itself (commit f5fb5d0) was documented directly in SKILL.md/AUTONOMOUS-ORCHESTRATION.md with `skip_specs: true`, no capability spec.)

## Impact

- Files: `SKILL.md`, `AUTONOMOUS-ORCHESTRATION.md`. No script, test, or config changes.
- Behavior: purely advisory — it changes how much an agent explores before drafting a proposal for a simple fix. It does not remove or weaken any gate, checker, or invariant.
