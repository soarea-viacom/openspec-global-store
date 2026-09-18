---
name: openspec-development
description: Spec-driven development workflow using the OpenSpec CLI — propose a delta spec before touching code, implement against the approved proposal with tests, then archive into the living spec. Use when the user wants to add/change a feature under spec control, or explicitly invokes /opsx:propose, /opsx:apply, or /opsx:archive.
---

# Global Spec-Driven Development (SDD) Skill
This profile enforces strict architectural integrity, preventing "vibe coding" and minimizing logic drift across projects.

## Core Directives
1. **Spec Alignment First:** Never write, modify, or delete application code before analyzing existing specifications or generating a delta spec proposal.
2. **Context Isolation:** Limit context gathering strictly to files relevant to the active issue. Do not pollute the prompt window with unrelated modules.
3. **Deterministic Implementation:** Prioritize maintainability, explicit type definitions, and testability over concise or clever code.

## Execution Workflow (OpenSpec 3-Phase Engine)
- **Phase 1: Explore & Propose (`/opsx:propose`)**
  - Read active code boundaries and structural modules.
  - Draft explicit architectural intent into a temporary delta spec.
  - Predict potential side effects or breaking changes in downstream dependencies.
- **Phase 2: Active Implementation (`/opsx:apply`)**
  - Write modular, self-documenting code that maps 1:1 with the finalized proposal.
  - Implement accompanying integration or unit tests simultaneously.
- **Phase 3: Final Consolidation (`/opsx:archive`)**
  - Verify syntax execution and run the testing suite locally.
  - Cleanly merge finalized changes back into the project's living documentation profile.

## Autonomous mode

The three phases above are the manual mode: a human triggers each command
and reviews between them. When the human asks for autonomous execution
("just get this done end to end", "run it and only ask me if something's
wrong") instead of step-by-step review, follow
[AUTONOMOUS-ORCHESTRATION.md](AUTONOMOUS-ORCHESTRATION.md) instead — it
runs the same three phases plus gates, an auto-fix loop, and a merge lane,
asking the human at most twice per change. Manual mode stays the default
whenever the human wants to review after each phase.

