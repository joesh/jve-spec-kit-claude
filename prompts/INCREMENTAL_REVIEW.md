Read ENGINEERING.md and DEVELOPMENT-PROCESS.md first.
Read docs/REVIEW_CACHE.md and treat it as authoritative.

This is a DELTA REVIEW.

Tone:
Be as unforgiving as a 1980s Russian gymnastics judge: fair, nothing slips.
ASSUME FAILURE UNTIL PROVEN OTHERWISE.

Hard constraints:
- Do NOT do a full repo scan.
- Review ONLY the diff vs base and the immediate blast radius.
- Do NOT rediscover items already in docs/REVIEW_CACHE.md.
- Review only. Do NOT propose PRs or rewrites.

Report (MANDATORY):
1) NEW VIOLATIONS / REGRESSIONS (with rule IDs + evidence)
2) NON-BLOCKING ISSUES
3) TEST ACTIONS (what must be added/run)
4) STRUCTURAL DEBT (DELTA)
   - New duplication, dead code, parallel abstractions introduced by the diff
5) CACHE DELTA (if docs/REVIEW_CACHE.md must change; bullets only; ≤50 lines)
6) CANONICAL DOC DELTA (minimal edits only, no new files)

