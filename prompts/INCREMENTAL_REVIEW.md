Read ENGINEERING.md and DEVELOPMENT-PROCESS.md first.

IMPLEMENTATION REVIEW — INCREMENTAL DELTA

Baseline canonical docs live under:
docs/implementation-review-baseline/

Quick context + delta trail live under:
docs/implementation-review-deltas/
- REVIEW_CACHE.md (rolling quick context; bullets; ≤50 lines)
- YYYY-MM-DD-<topic>.md (dated delta notes)

Hard constraints:
- Do NOT do a full repo scan.
- Review ONLY the diff vs base and the immediate blast radius.
- Do NOT restate baseline material unless it became false.
- Review only. Do NOT propose PRs or rewrites.

Mandatory outputs:
1) NEW VIOLATIONS / REGRESSIONS (with rule IDs + evidence)
2) NON-BLOCKING ISSUES
3) TEST ACTIONS
4) STRUCTURAL DEBT (DELTA): new duplication/dead code/missed unification introduced by the diff

Documentation:
5) DOC PATCHES (baseline) — unified diffs, minimal edits to keep baseline true
6) DELTA NOTE — add ONE dated note under docs/implementation-review-deltas/YYYY-MM-DD-<topic>.md
7) REVIEW_CACHE — update docs/implementation-review-deltas/REVIEW_CACHE.md only if a proven/stable bullet should change
