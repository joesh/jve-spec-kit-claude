# Codex instructions for this repository

## Review guidelines

For PR reviews, output a section titled **DOC PATCHES** containing unified diffs that update the authoritative baseline docs and (when applicable) add a dated delta note.

### Authoritative docs

Baseline (authoritative, implementation-derived):
- docs/implementation-review-baseline/01-REPO-OVERVIEW.md
- docs/implementation-review-baseline/02-ARCHITECTURE-MAP.md
- docs/implementation-review-baseline/03-CORE-INVARIANTS.md
- docs/implementation-review-baseline/04-BEHAVIORAL-FLOWS.md
- docs/implementation-review-baseline/05-STRUCTURAL-DEBT.md
- docs/implementation-review-baseline/06-TEST-GAPS.md
- docs/implementation-review-baseline/07-RISK-REGISTER.md

Deltas (incremental trail + quick context):
- docs/implementation-review-deltas/REVIEW_CACHE.md
- docs/implementation-review-deltas/YYYY-MM-DD-<topic>.md

### Hard output constraints

No prose outside:
1) DOC PATCHES (unified diffs)
2) TOP RISKS (ranked)
3) RULE VIOLATIONS (with file paths + symbols + tests)
4) TEST GAPS

### Evidence requirements

Every non-trivial claim must cite evidence: file paths + symbols/functions + (if applicable) tests.

### Structural debt requirement (always)

Actively hunt STRUCTURAL DEBT: duplication, dead/abandoned code, parallel implementations, missed unification opportunities.
For each item include evidence and (if obvious) the canonical location in baseline docs.

### REVIEW_CACHE.md (quick context)

- Bullets only
- Proven / stable / actionable
- ≤ 50 lines
- Each bullet must point to a baseline doc section (file + heading)
