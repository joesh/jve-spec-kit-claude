# Development Process (Mandatory)

This document defines the required workflow for all changes to this repository.

It governs *how* work is done.
ENGINEERING.md governs *what is allowed*.

If there is any conflict, **ENGINEERING.md always wins**.

---

## 1. Baseline-First Rule (Mandatory)

This repository has an implementation-derived baseline under:

docs/implementation-review-baseline/

Before any repo-wide search, grepping, hypothesis formation, or architectural inference:

- You MUST read the relevant baseline documents.
- You MUST treat them as authoritative context.

If no baseline section covers the area being changed, treat that absence as a **baseline gap**, not an excuse to infer intent.

Baseline documents describe observed implementation reality, not design intent.

---

## 2. Change Classification

Every change must be classified as one of:

1. Baseline-consistent (no baseline statements become false)
2. Baseline-extending (new behavior not previously documented)
3. Baseline-invalidating (existing baseline statements become false)

Cases (2) and (3) require documentation updates.

---

## 3. Incremental Review & Deltas

When a change meaningfully affects understanding of the system:

- Add ONE dated delta file under:
  docs/implementation-review-deltas/YYYY-MM-DD-<topic>.md

Each delta must include:
- What changed (commit(s) or description)
- Which baseline files and sections are affected
- New risks or test gaps introduced

Delta files are explanatory history.
They are NOT canonical truth.

---

## 4. Baseline Maintenance

If a change makes any baseline statement false or incomplete:

- Update the relevant numbered baseline file(s)
- Apply the minimal edit necessary to restore correctness
- Do NOT restate unaffected sections

If baseline and code disagree, the discrepancy must be resolved explicitly.
Never silently favor the code.

---

## 5. REVIEW_CACHE.md (Selective, Not Exhaustive)

docs/implementation-review-deltas/REVIEW_CACHE.md is a rolling quick-context index.

Rules:
- Bullets only
- ≤ 50 lines total (prune aggressively)
- Only include proven, stable, reusable facts
- Each bullet must point to a baseline file + section

Not every delta belongs in REVIEW_CACHE.
Use it only for information that saves future review time.

---

## 6. Test Discipline (Mandatory)

All ENGINEERING.md test rules apply.

Additionally:
- Any new invariant, codepath, or failure mode requires tests.
- Existing tests must not be weakened or reinterpreted.
- If behavior changes, add new tests; do not “fix” old expectations.

---

## 7. Prohibited Behaviors

- Re-deriving architecture already documented in the baseline
- Treating deltas as authoritative truth
- Updating baseline docs speculatively
- Recording aspirational or unverified behavior
- Using REVIEW_CACHE as a progress log

---

## 8. Success Criteria

A future reviewer or LLM should be able to:

- Understand the system without a full code walk
- Identify invariants and failure modes
- See where the system has changed and why
- Continue incremental development without re-baselining
