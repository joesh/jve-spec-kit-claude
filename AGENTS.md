# Codex instructions for this repository

## Review guidelines
- For PR reviews, output a section titled "DOC PATCHES" containing unified diffs that update the canonical docs under docs/.
- Target files:
  - docs/EVIDENCE_INDEX.md
  - docs/CODEBASE_OVERVIEW.md
  - docs/ARCHITECTURE_MAP.md
  - docs/GOLDEN_PATHS.md
  - docs/INVARIANTS.md
  - docs/TRAPS.md
  - docs/PATTERNS.md
  - docs/REVIEW_CACHE.md
- No prose outside:
  1) DOC PATCHES (diffs)
  2) TOP RISKS (ranked)
  3) RULE VIOLATIONS (with file paths + symbols + tests)
  4) TEST GAPS
- Every claim must cite evidence: file paths + symbols/functions + (if applicable) tests.
- Actively hunt STRUCTURAL DEBT: duplication, dead/abandoned code, parallel implementations, missed unification opportunities; include evidence and suggested canonical location.
- docs/REVIEW_CACHE.md: bullets only, proven/stable/actionable, <= 50 lines, and each bullet must point to a canonical doc section.
