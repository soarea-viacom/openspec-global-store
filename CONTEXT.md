# Domain glossary

- **Store**: a directory holding OpenSpec artifacts and orchestration state
  for one target project, resolved by slug via the CLI registry
  (`OPENSPEC_STORE_REGISTRY`).
- **Change**: the unit of branch, workspace, gate and merge
  (`change/<name>` branch in the target project's repo, worktree checked
  out at `<store>/.orchestration/workspaces/<name>` — `workspace_path` in
  `scripts/lib.sh` is the only place that path is built). Gates run in the
  worktree, never the project's main checkout.
- **State module**: `scripts/lib.sh` (`state_root`, `state_field`,
  `state_write`) — sole owner of the state-file YAML dialect under
  `<store>/.orchestration/state/`. Nothing else parses those files. All
  upserts from the CLI — change state and initiative records alike — go
  through one helper, `set_record` in `scripts/run-change`, which is also
  where the `prev_*_result` shift lives.
- **Worker**: one agent dispatched by the orchestrator into its own context
  window for one task — a dispatch group, a fixer, a critic, a Verify
  checker, a triage read. Receives only what the orchestrator hands it plus
  what it reads from disk; never another agent's transcript. Writers stay
  inside their seam's file list and never run a git command that writes;
  read-only workers are exempt from the disjoint-files check.
- **Advisor**: a read-only `deep`-tier subagent a stuck `standard` or
  `mechanical` worker asks one packaged question, fresh context, answer
  only. Obtained only via `scripts/run-change advisor request --worker
  <transcript-id>`, which enforces the caps (one per worker task, two per
  change — `ADVISOR_CAP` in `scripts/lib.sh`) and writes the `role advisor
  tier deep for=<worker>` session entry itself; `session append` refuses
  that role. Never from `deep` and never from a checker. Distinct from tier escalation, which re-runs the
  whole task at the higher tier.
- **Blackboard**: the orchestrator-owned files agents share through —
  proposal, seam list, state, reports. The only channel between agents;
  there is no worker-to-worker messaging.
- **Dispatch group**: the unit of concurrent implementation within a
  change — one writer worker per seam from the seam list, all sharing the
  change's worktree. The orchestrator commits once per wave after the
  quick gate; workers never commit.
- **Slot**: a concurrency token under `<store>/.orchestration/slots/`,
  capped by `orchestration.concurrency` in the store's config.
- **Seam list**: the `seams` field in a change's state file, written during
  Propose via `scripts/run-change state set --store <slug> --name <change>
  seams "<seam>=<file>,<file>;<seam>=<file>"` — one `name=file,file,...`
  group per seam, groups separated by `;`. The sole source the
  disjoint-files check reads from; nothing infers seams from the delta spec
  prose or from the code after the fact.
- **Session log**: `<store>/.orchestration/state/<change>.sessions.log` —
  an append-only, one-line-per-run history, written via `scripts/run-change
  session append --store <slug> --name <change> key value [key value ...]`
  and read via `session list`. Distinct from the per-change state file: the
  state file holds the *current* record for a change (one value per key,
  upserted in place); the session log holds *every* run's record (`role`,
  `phase`, `gates_hit`, `transcript_id`, `model`, `tier`), appended, never
  rewritten.
- **Tier→model table**: the mapping from an effort tier (`mechanical`,
  `standard`, `deep` — the `none` tier runs no model) to a concrete model
  id, read via `scripts/run-change model get --store <slug> --tier
  <tier>`. Resolved from the store's `openspec/config.yaml`
  (`orchestration.model_<tier>`) if set, else the default table in
  `model_for_tier` (`scripts/lib.sh`) — the only place a specific model id
  is hardcoded in the engine.
- **Generator/checker split**: the rule that a checker's model must
  differ from the generator whose output it judges. Two instances:
  Verify's checker vs. the implementer (`implementer_model` reads the last
  `applying`/`checking` session entry) and Propose's critic vs. the
  proposer (`proposer_model` reads the last `proposed` entry). Both go
  through `checker_model` (`scripts/lib.sh`): resolve `standard`'s model,
  escalate to `deep`'s on collision, error if both collapse to the
  generator's id; `mechanical` is never a candidate. Exposed as
  `scripts/run-change model verify|critic --store <slug> --name <change>`.
- **Critique report**: `<store>/.orchestration/state/<change>.critique.md`,
  written by the Propose critic, overwritten each round. Each finding
  names the spec section or seam, the defect, and what would satisfy it.
  Summarized in `last_critique_result` as `clean`, `warnings:<m>`,
  `blocking:<n>`, or `request`; only `blocking` starts a round. Rounds counted in `propose_rounds`, cap 2, independent of
  `fix_attempts`.
- **Verify report**: `<store>/.orchestration/state/<change>.verify.md`,
  written by the Verify checker and overwritten each round (current
  record, like the state file). Each finding carries the proposal
  requirement, `file:line`, the defect, and what would satisfy it.
  Summarized in the state field `last_verify_result` as `clean`,
  `warnings:<m>`, `blocking:<n>`, or `spec`; only `blocking` starts a
  fix round. The sole input a fix round receives from
  Verify — the fixer never sees the checker's transcript.
- **Fix round**: one bounded correction pass, triggered by either a red
  full gate or a `blocking` verify report. Both draw on the same
  `fix_attempts` counter, capped at 3 per change; tier escalates by round
  number, then Gate 1.
- **Convergence test**: a checker round converges only if no finding the
  prior report marked closed reappears and the blocking count strictly
  falls. A round that fails it gates to the human immediately, ignoring
  remaining budget. Applies to fix rounds and critique rounds alike (see
  **Checker loops** in AUTONOMOUS-ORCHESTRATION.md). The count half is
  enforced by `next` from `prev_verify_result` / `prev_critique_result`,
  which `state set` shifts automatically whenever a real result is
  overwritten (including by the clear before a recheck); the
  reopened-finding half remains the checker's judgement.
- **Pass line**: Verify passes on full gate green plus zero `blocking`
  findings; critique passes on zero `blocking` findings. `warning`
  findings get one mechanical sweep and never start a round.
- **Next action**: `scripts/run-change next --store <slug> --name <change>`
  — the orchestration policy as one read-only function (`next_action` in
  `scripts/lib.sh`) that maps a change's state file + session log to the
  single next step (`action`, `tier`, `model`, `set_phase`, `reason`). The
  agent does the step and records results; it never re-derives the
  lifecycle from prose. Caps live beside it: `FIX_CAP`, `PROPOSE_CAP`,
  `ADVISOR_CAP`.
- **Gate**: the project's quick or full check command
  (`orchestration.gate_quick` / `gate_full` in the *store's*
  `openspec/config.yaml` — single rule: a target project must not contain
  an `openspec/` folder; the engine refuses one that does).
- **Merge lane**: the serialized merge-trunk-then-full-gate step behind
  `<store>/.orchestration/merge.lock`.
- **Initiative**: complex work decomposed into dependency-ordered changes.
  Its record, `<store>/.orchestration/initiatives/<name>.yaml` (`title`,
  `request`, `children` in merge order, `critique_rounds`,
  `last_critique_result`, `merged` as a `child=sha` map), is written only
  via `scripts/run-change initiative init|get|set|merged` and uses
  the state module's YAML dialect, but lives outside `state/` so `status`
  never lists it as a change.

The engine's own gate is `tests/run.sh` — black-box through the
`scripts/run-change` CLI, both seams substituted (temp registry, temp
project repo).
