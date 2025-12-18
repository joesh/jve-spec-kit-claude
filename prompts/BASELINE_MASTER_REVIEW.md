Read ENGINEERING.md and DEVELOPMENT-PROCESS.md first.
Read docs/REVIEW_CACHE.md and treat it as authoritative.

BASELINE MASTER REVIEW
Purpose:
- Produce long-lived canonical documentation under docs/
- Establish a correctness and architecture baseline
- Prevent repeated full-code walks
- Identify proven risks, violations, and structural debt

Tone:
Be as unforgiving as a 1980s Russian gymnastics judge: fair, nothing slips.
ASSUME FAILURE UNTIL PROVEN OTHERWISE (ENGINEERING.md §2.9).
Every claim must be grounded in evidence (files / symbols / tests).

Hard constraints:
- Review and document only. Do NOT generate PRs or rewrite code.
- Repo-wide scan is allowed unless a subsystem scope is specified.
- No aspirational language. Describe only verified reality.
- Do NOT restate items already in docs/REVIEW_CACHE.md.

Deliverables (MANDATORY):

A) CANONICAL DOCUMENTATION (create/update under docs/)
1) EVIDENCE_INDEX.md
2) CODEBASE_OVERVIEW.md
3) ARCHITECTURE_MAP.md
4) GOLDEN_PATHS.md
5) INVARIANTS.md
6) TRAPS.md
7) PATTERNS.md

B) REVIEW FINDINGS (ephemeral)
8) TOP RISKS (ranked)
9) RULE VIOLATIONS (ENGINEERING / PROCESS rule IDs)
10) TEST GAPS

11) STRUCTURAL DEBT
Actively hunt for:
- Duplicate or near-duplicate logic
- Parallel implementations
- Dead or abandoned code paths
- Stale helpers/modules
- Missed unification or simplification opportunities

For each:
- Evidence (file paths + symbols)
- Why it is redundant / abandoned
- Where the canonical implementation should live (if obvious)

C) CACHE + CANON PATCHES
12) CACHE PATCH
- Propose bullets for docs/REVIEW_CACHE.md ONLY IF proven, stable, actionable
- Bullets only, must point to canonical docs
- Obey ≤50-line cap

13) CANONICAL DOC PATCHES (optional)
- Minimal edits to existing docs only
- No new files
