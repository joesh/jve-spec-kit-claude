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

**Navigation Index Rule (Mandatory):**

To avoid guessing file locations, you MUST consult the repository navigation indexes *before* opening non-baseline code files:

- `docs/symbol-index/symbols.json` (symbol → file/line/kind)
- `docs/symbol-index/commands.json` (command name → module/entrypoint)
- `tags` (ctags) when useful

Consulting these indexes is permitted before the Exploration Gate and does NOT count against the file budget.

If the required symbol/command is missing or stale in the indexes, treat that as a baseline insufficiency and fix the index (see Section 6).

**Exploration Gate (Mandatory):**

This repository has an implementation-derived baseline under:

docs/implementation-review-baseline/

Before any repo-wide search, grepping, hypothesis formation, or architectural inference:

- You MUST read the relevant baseline documents.
- You MUST treat them as authoritative context.

If no baseline section covers the area being changed, treat that absence as a **baseline gap**, not an excuse to infer intent.

Baseline documents describe observed implementation reality, not design intent.

**Exploration Gate (Mandatory):**

After reading the baseline, and before opening any non-baseline code files:

- You MUST state a concrete, falsifiable hypothesis grounded in a cited baseline section.
- You MUST name the specific file(s) you intend to inspect next (maximum **3**).
- Each file MUST be justified by explaining which baseline statement, invariant, or flow it is testing or clarifying.

**Adaptive Expansion Rule:**

- The authorized file list may expand from **3 up to 5 files** only if inspection of the initial files demonstrates they are insufficient to test the stated hypothesis.
- Such expansion MUST be explicitly acknowledged and treated as a **baseline insufficiency**, triggering the delta requirements in Section 3.

Opening additional files beyond the authorized list is prohibited.

**LLM Pre-Action Checklist (Mandatory):**

Before taking *any* action beyond reading baseline documents and consulting the navigation indexes, the following checklist MUST be completed explicitly:

1. **Baseline sections read:** list exact files + section numbers.
2. **Navigation indexes consulted:** list which of `symbols.json`, `commands.json`, `tags` were used.
3. **Change classification (tentative):** baseline-consistent, baseline-extending, or baseline-invalidating.
4. **Concrete hypothesis:** one falsifiable statement tied to a baseline citation.
5. **Authorized file list:** ≤3 files, each with justification tied to the hypothesis and/or an index entry.
6. **Search status:** confirm that no repo-wide grep or broad search will occur until the hypothesis requires it.
7. **Fallback status:** confirm that no compatibility fallbacks or defensive behavior will be introduced unless explicitly baseline-extending.

If any item cannot be completed, work MUST pause and the gap must be resolved or documented as a baseline insufficiency.

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

**Baseline Insufficiency Rule:**

The first time work requires leaving the baseline-defined surface area, the delta MUST explicitly explain why the baseline was insufficient or incomplete.

**Learning-as-you-go Rule (Mandatory):**

If investigation required non-obvious file discovery (e.g., “where is command X implemented?”), you MUST record the durable shortcut so future reviews do not repeat the search:

- Prefer adding a bullet to `docs/implementation-review-deltas/REVIEW_CACHE.md` when it is stable.
- Otherwise record it in the delta.

Examples of durable shortcuts:
- command name → registry key → module path → entrypoint
- symbol/function name → defining file + line range (or index entry)

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

## 6. Build, Test, and Index Discipline (Mandatory)

All ENGINEERING.md test rules apply.

Additionally:
- A successful `make` MUST be run before any work is considered complete.
- `make` MUST complete with:
  - no build errors
  - no lint warnings
  - no failing tests
  - no warning or skipped tests
- If `make` triggers tests by default, those results are authoritative.
- Work MUST NOT be declared complete unless this condition is met and stated explicitly.

**Navigation Index Maintenance (Mandatory):**

- `make` MUST also produce up-to-date navigation indexes:
  - `docs/symbol-index/symbols.json`
  - `docs/symbol-index/commands.json`
  - `tags` (ctags)
- If a change affects symbol locations or command registration, the indexes MUST be regenerated and committed.
- If indexes are missing/stale and block hypothesis formation, fix the indexes before widening exploration.

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
- Performing repo-wide greps or broad searches without a stated, falsifiable hypothesis
- Using search as a substitute for identifying the relevant baseline invariant or flow
- Introducing compatibility fallbacks or defensive behavior not described in the baseline, unless explicitly classified as Baseline-extending and documented

**Enforcement:**

Any response that opens non-baseline files, performs repo-wide search/grep, or expands scope without first completing the LLM Pre-Action Checklist is **invalid** and must restart from the checklist. in the baseline
- Treating deltas as authoritative truth
- Updating baseline docs speculatively
- Recording aspirational or unverified behavior
- Using REVIEW_CACHE as a progress log
- Performing repo-wide greps or broad searches without a stated, falsifiable hypothesis
- Using search as a substitute for identifying the relevant baseline invariant or flow
- Introducing compatibility fallbacks or defensive behavior not described in the baseline, unless explicitly classified as Baseline-extending and documented

---

## 8. Completion Gate (Mandatory)

Before declaring work complete, the following MUST be stated explicitly:

- `make` was run
- Build completed without errors or warnings
- All t

---

## 9. Success Criteria

A future reviewer or LLM should be able to:

- Understand the system without a full code walk
- Identify invariants and failure modes
- See where the system has changed and why
- Continue incremental development without re-baselining

