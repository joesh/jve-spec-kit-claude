# PROMPT_CREATE_MASTER_REVIEW.md
# Authoritative baseline-review contract (do not simplify)

Read ENGINEERING.md and DEVELOPMENT-PROCESS.md first.

BASELINE IMPLEMENTATION REVIEW — MASTER PROMPT

Purpose
-------
Produce a *full, implementation-derived baseline* of the repository so that future reviews
do NOT require repeated full-code walks.

This document is normative. Other baseline or tool-specific prompts are executions of this.
If there is a conflict, THIS FILE WINS.

Tone
----
Be as unforgiving as a 1980s Russian gymnastics judge: fair, but nothing slips.
ASSUME FAILURE UNTIL PROVEN OTHERWISE (ENGINEERING.md §2.9).

Scope
-----
- Entire repository.
- Repo-wide scan allowed.
- This is NOT incremental.

Hard Constraints
----------------
- Review and document ONLY. Do NOT generate PRs or rewrite code.
- Describe observed behavior and enforcement only.
- No aspirational or intended-design language.
- Every non-trivial claim MUST be grounded in evidence:
  file paths + symbols/functions + tests where applicable.

Authoritative Output
--------------------
Create or replace FULL CONTENTS of the following files under:

docs/implementation-review-baseline/

01-REPO-OVERVIEW.md
02-ARCHITECTURE-MAP.md
03-CORE-INVARIANTS.md
04-BEHAVIORAL-FLOWS.md
05-STRUCTURAL-DEBT.md
06-TEST-GAPS.md
07-RISK-REGISTER.md

These numbered files together form the *entire canonical baseline*.

Deliverable Requirements
------------------------

01-REPO-OVERVIEW
- What the repository is and is not.
- Major subsystems and responsibilities.
- What is explicitly out of scope.

02-ARCHITECTURE-MAP
- Actual layer boundaries (as implemented).
- Dependency direction rules.
- Known boundary violations (with evidence).

03-CORE-INVARIANTS
- Conditions that must always hold for correctness.
- Indicate whether each invariant is enforced, partially enforced, or documented-only.
- Tie invariants to code locations and tests.

04-BEHAVIORAL-FLOWS
- Actual execution paths (not intended design).
- Call chains, state transitions, mutation points.
- Entry assumptions and failure modes.

05-STRUCTURAL-DEBT
Actively hunt for:
- Duplicate or near-duplicate logic
- Parallel implementations
- Dead or abandoned code paths
- Stale helpers/modules
- Missed unification or simplification opportunities

For each structural debt item include:
- Evidence (file paths + symbols and a short excerpt or description of the duplicated pattern)
- Why it is redundant / abandoned
- Suggested unification target location (if obvious)
- Risk if left unfixed (correctness vs maintainability vs perf)

06-TEST-GAPS
- Missing or weak test coverage.
- Map each gap to the invariant(s) and flow(s) it protects.
- Cite existing tests where coverage is partial/weak.

07-RISK-REGISTER
- Ranked, concrete failure modes.
- Focus on correctness, undo/state integrity, and performance cliffs.
- Each risk must cite evidence and reference relevant baseline sections.

Structural Debt is Mandatory
----------------------------
Even if the code is strong, you MUST still look for:
- “two ways to do the same thing”
- lingering legacy code
- duplicated helpers under different module names
- unused schema fields or dead migrations
- duplicated parsing/validation logic
- parallel state tracking mechanisms

If you cannot find any, explicitly say so AND provide evidence of the search performed.

Review Cache
------------
Quick context lives here (rolling, small):
docs/implementation-review-deltas/REVIEW_CACHE.md

Rules:
- Bullets only
- Proven / stable / actionable only
- ≤ 50 lines (prune aggressively)
- Each bullet must point to baseline doc sections (file + heading)
- Only propose updates if genuinely stable; do not dump the whole review

Execution Mechanics (important for flaky UIs)
---------------------------------------------
If the output is large or the tool/UI is unstable:
- Emit ONE FILE AT A TIME.
- After completing a file, STOP and wait.
- Do not move to the next file until the user says “continue”.

No Prose Outside Files
----------------------
Outside of the required baseline files (and any explicit cache patch proposals),
do not output narrative text.

Success Criteria
----------------
A new reviewer or LLM should be able to:
- understand the repo structure without a code tour
- identify invariants and failure modes
- know where structural debt lives
- know what tests are missing
- perform incremental reviews without re-baselining
