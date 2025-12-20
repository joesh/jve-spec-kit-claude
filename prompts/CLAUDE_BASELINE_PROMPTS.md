# Claude Web: Baseline implementation review prompts (ordered)

These prompts are designed for Claude Web where long runs can reset context. Use a **new chat**. Re-upload the repo snapshot and (when applicable) the already-produced baseline files.

Authoritative baseline output folder:
- docs/implementation-review-baseline/

Authoritative delta folder:
- docs/implementation-review-deltas/
  - REVIEW_CACHE.md (rolling, bullets, ≤50 lines)
  - YYYY-MM-DD-<topic>.md (dated notes)

---

## Pass 1 (Baseline: structure + invariants)

Upload:
- repo snapshot (zip)
- nothing else

Prompt (paste verbatim):

Pass 1 only.

Using the repository snapshot attached to this message, produce ONLY the following files under:
docs/implementation-review-baseline/

01-REPO-OVERVIEW.md
02-ARCHITECTURE-MAP.md
03-CORE-INVARIANTS.md

Rules:
- Observed behavior and enforcement only (no intended design).
- Every claim must cite evidence (file paths + symbols + tests when applicable).
- Prefer lists/tables/bullets over prose.
- No prose outside these files.
- Emit ONE FILE AT A TIME and STOP after each file.

---

## Pass 2 (Baseline: behavioral flows + structural debt)

Upload:
- repo snapshot (zip)
- docs/implementation-review-baseline/01-REPO-OVERVIEW.md
- docs/implementation-review-baseline/02-ARCHITECTURE-MAP.md
- docs/implementation-review-baseline/03-CORE-INVARIANTS.md

Prompt (paste verbatim):

Pass 2 only.

Using the repository snapshot and the attached baseline files as authoritative, produce ONLY:

docs/implementation-review-baseline/04-BEHAVIORAL-FLOWS.md
- Actual execution paths and runtime flows (what code does, not intended design)
- Trace through functions, call chains, state transitions
- Cite file paths and symbols for every flow

docs/implementation-review-baseline/05-STRUCTURAL-DEBT.md
Structural debt must include:
- Duplicate implementations
- Dead or orphaned code
- Missed unification opportunities
Evidence for each claim (paths + symbols)

Constraints:
- Do not restate architecture/overview/invariants; reference them by file + heading.
- No prose outside these files.
- Emit ONE FILE AT A TIME and STOP after each file.

---

## Pass 3 (Baseline: test gaps + risk register)

Upload:
- repo snapshot (zip)
- docs/implementation-review-baseline/01-REPO-OVERVIEW.md
- docs/implementation-review-baseline/02-ARCHITECTURE-MAP.md
- docs/implementation-review-baseline/03-CORE-INVARIANTS.md
- docs/implementation-review-baseline/04-BEHAVIORAL-FLOWS.md
- docs/implementation-review-baseline/05-STRUCTURAL-DEBT.md

Prompt (paste verbatim):

Pass 3 only.

Using the repository snapshot and the attached baseline files as authoritative, produce ONLY:

docs/implementation-review-baseline/06-TEST-GAPS.md
- Missing or weak test coverage
- Tie each gap to specific flows/invariants
- Cite existing tests where partial coverage exists

docs/implementation-review-baseline/07-RISK-REGISTER.md
- Ranked concrete failure modes
- Focus on correctness, undo/state integrity, performance cliffs
- Every risk must cite files/symbols/flows already documented

Constraints:
- No architecture restatement.
- No prose outside these files.
- Emit ONE FILE AT A TIME and STOP after each file.

---

## Incremental review (post-baseline)

Use INCREMENTAL_REVIEW.md in this repo (updated) as the authoritative incremental prompt.
