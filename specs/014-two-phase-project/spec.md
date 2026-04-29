# Feature Specification: Two-Phase Project Switch

**Feature Branch**: `014-two-phase-project`
**Created**: 2026-04-29
**Status**: Draft
**Input**: User description: "Two-phase project switch with project_will_change signal, defensive validation against stale project_id, and audit of deferred-work patterns that capture project_id."

---

## Clarifications

### Session 2026-04-29

- Q: When a Lua callback raises a JVE_ASSERT-class invariant violation, what should the bridge do? → A: Log a stack trace, then continue. This matches the established JVE_ASSERT semantics in C++ (loud, actionable, but non-fatal — the editor stays up so the user keeps their session).
- Q: Defensive `current_project_id` ↔ live-DB validation — permanent or stopgap? → A: Keep permanently. Cheap fail-loud check; catches any future module that re-introduces the bug. Defense in depth.
- Q: Pre-switch background-worker cancellation contract? → A: Hybrid — set cancel flag AND block briefly (~1s drain budget) for already-queued writes to land in the outgoing DB; results that don't drain in time are discarded with a logged note. Per-write validation (FR-006) is the safety net for any straggler that escapes the drain.

---

## Scope

- WHAT and WHY: correct, fail-loud project switching; today silent log-and-discard hides cross-project data corruption.
- NOT in scope: prescriptive HOW for handler internals — only the contract is fixed.
- Audience: engineers maintaining JVE's signal contract and any module that holds project-scoped state.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

A JVE user has a project open and is interacting with the timeline. Background work (media probes, peak generation, debounced status persistence) is in flight, holding pending writes targeted at the open project's database. The user opens or imports a different project. The editor must:

1. Flush every pending write to the **outgoing** project's database before that database is detached.
2. Cancel or invalidate every deferred task that targets the outgoing project.
3. Attach the **incoming** project's database, then load fresh state.
4. Continue running with no silent failures, no log-and-discarded asserts, and no writes that crossed project boundaries.

### Acceptance Scenarios

1. **Given** a project P1 is open with a debounced media-status persist scheduled (timer pending), **When** the user opens project P2, **Then** the pending persist completes against P1's database before P1 is detached, and the editor switches to P2 with no `assert_project_exists` errors.

2. **Given** a project P1 is open and a `single_shot_timer` is pending whose callback uses cached project state, **When** the user opens P2 and the timer fires after the switch, **Then** the callback either no-ops (validated against the live database) or has been cancelled — it does NOT write to P2 with P1's project_id.

3. **Given** a project P1 is open with an in-flight background probe writing into the media-status cache, **When** the user opens P2, **Then** the probe is cancelled before P1 detaches, no probe results land in P2's database under P1's project_id, and any partial work is either flushed to P1 or discarded — never silently mis-routed.

4. **Given** a successful re-import of `anamnesis-gold-timeline.drp` followed by user interaction (arrow, play, click), **When** TSO is reviewed, **Then** zero `assert_project_exists ... Stale project_id after project switch?` lines are present.

5. **Given** every existing handler that subscribes to the post-switch signal, **When** the audit catalog is consulted, **Then** each handler is classified (must-cancel-deferred-work, must-flush-pending-writes, no-action) and any handler in the first two categories has been migrated to the pre-switch phase or made stale-safe.

### Edge Cases

- **No prior project open** (cold start): the pre-switch phase fires with a "no outgoing project" payload; handlers must no-op cleanly. No DB write attempted.
- **Project close, no replacement** (user closes without opening another): the pre-switch phase still fires and flushes; the editor enters the no-active-project state without errors.
- **Pre-switch handler errors**: an individual handler raising an error must not block the switch indefinitely, must not crash the editor silently, and must surface the error somewhere observable. It must NOT be silently log-and-discarded such that the engineer cannot find it.
- **A deferred task fires DURING the pre-switch phase** (e.g. a sub-second timer): the task's project_id-validation must succeed (live DB still matches outgoing project) or the cancellation must have already run.
- **A deferred task fires DURING the post-switch phase, before all post-switch handlers have completed** (Qt event loop reentry): the task must not write to the new database with the old project_id; defensive validation catches this.
- **Repeated rapid switches** (P1 → P2 → P3 within a single Qt event loop turn): each switch is a complete two-phase cycle; no pending work from P1 may end up in P3.
- **Lua-callback assertion failures** anywhere in the switch flow: must not be silently discarded by the C++/Lua callback bridge — that pattern is what hid the failures driving this feature.

---

## Requirements *(mandatory)*

### Functional Requirements

#### Two-Phase Switch Contract

- **FR-001**: System MUST emit a pre-switch signal synchronously, BEFORE detaching the outgoing project's database, every time the active project changes (open, switch, close, re-import). The signal payload MUST identify the outgoing project (or indicate "no project was open").

- **FR-002**: System MUST emit the existing post-switch signal synchronously, AFTER attaching the incoming project's database. The signal payload MUST identify the incoming project (or indicate "no active project").

- **FR-003**: Every database-writing operation that occurs during a project lifetime and persists across the switch (debounced timers, background workers, queued tasks) MUST be either:
  - flushed to the outgoing project's database during the pre-switch phase, OR
  - cancelled during the pre-switch phase, OR
  - guarded at fire time by validating the captured project_id against the live database (and no-op'ing if stale, per FR-006).

- **FR-003a**: For background workers (asynchronous threads writing into a per-project cache, e.g. the media probe), the pre-switch handler MUST:
  1. signal cancellation immediately (set a cancel flag the worker observes), AND
  2. block briefly — up to a 1-second drain budget — to allow already-queued writes to land in the outgoing project's database, AND
  3. discard any results that do not drain within the budget, logging a single warning naming the worker and the dropped count.

  Workers that drain quickly do not appear to stall the switch. The drain budget is a hard cap, not an SLA — the switch always proceeds. Per-write validation (FR-006) catches any straggler that escapes the drain by writing after the budget expires.

- **FR-004**: Pre-switch handlers MUST run while the outgoing project's database is still the live connection. Post-switch handlers MUST run only after the incoming project's database is the live connection. The signal-dispatch contract MUST guarantee this ordering for every emit.

#### Defensive Validation

- **FR-005**: Every database write that takes a `project_id` argument MUST validate that the argument matches the live database's sole project. The validation MUST be unbypassable — there must be no public DB-write API that takes a `project_id` and skips the check.

- **FR-006**: Modules that cache the active project_id at the module level MUST validate the cached value against the live database before any write. A mismatch MUST log a JVE_ASSERT-style stack trace at error level (per FR-008) naming the cached value, the live value, and the calling module, then no-op the write — neither silently skip nor silently swallow. This validation is a **permanent** invariant check (defense in depth): the check stays after the pre-switch signal contract is in place, so any future module that re-introduces the stale-cache bug fails loud.

- **FR-007**: After this feature lands, an engineer searching the codebase for subscribers to the post-switch signal MUST find a committed audit catalog (in repo, not just memory) classifying every handler as "no-action," "must-cancel-deferred-work," or "must-flush-pending-writes," and every entry in the latter two categories MUST have a corresponding pre-switch handler or fire-time guard.

#### Failure Visibility (the meta-bug)

- **FR-008**: When a Lua callback (Qt slot, signal handler, posted-event callback) raises an error, the Lua-callback bridge MUST log a full stack trace identifying the failing module, the failing assertion message, and the call site, then continue. This matches JVE_ASSERT semantics in C++: loud and actionable (the engineer sees the trace immediately) but non-fatal (the editor keeps running so the user does not lose their session). The bridge MUST NOT log only the bare error message without a trace, which is the silent-swallow pattern that hid the failures driving this feature.

- **FR-009**: The pre-switch phase's per-handler error path MUST behave identically to FR-008: a thrown error logs a stack trace and dispatch continues with the next handler. The switch itself MUST NOT be blocked by a single handler's failure (the outgoing project may be about to be replaced or deleted; halting on the outgoing project leaves the editor in an unusable state).

#### Coverage & Verification

- **FR-010**: The implementation MUST include automated tests that verify, observably:
  - the pre-switch signal fires before the database swap (the live DB connection still resolves to the outgoing project at that moment)
  - the post-switch signal fires after the swap (the live DB connection resolves to the incoming project at that moment)
  - a debounced persist scheduled during the outgoing project lands in the outgoing project's database
  - a deferred timer that would have fired post-switch with stale project_id is either cancelled or no-ops via validation, and produces no `assert_project_exists` failure
  - the cold-start case (no prior project) does not error
  - the close-without-replacement case does not error

- **FR-011**: The implementation MUST verify the original failing scenario: re-import `anamnesis-gold-timeline.drp`, perform a representative set of timeline interactions (arrow, play, click), and confirm zero `assert_project_exists` lines in TSO across the session.

### Non-Goals

- Refactoring the open-project flow itself (the file picker, conversion dialog, recent-projects UI, etc.). This feature only adds the pre-switch emit and migrates handlers.
- Changing what post-switch handlers do AFTER the switch (clearing caches, loading new state). Only what they do BEFORE is in scope.
- Per-handler progress reporting, timeouts, or async coordination during the pre-switch phase. The phase is synchronous; per-handler errors are logged-and-skipped (FR-009) rather than orchestrated.
- Generalizing this pattern to other lifecycle signals. Project switch is the immediate problem; broader lifecycle work can build on this contract later.

### Key Entities *(include if feature involves data)*

- **Project Switch Event**: a logical operation with two phases (pre-switch, post-switch). Carries the outgoing project_id and the incoming project_id. Every project lifecycle change (open, import, close, re-import) is a project switch event.

- **Deferred-Work Closure**: any callback scheduled to run later (single-shot timer, background worker callback, posted event) that touches the database or carries an implicit project_id assumption. Each one belongs to exactly one project at the moment it was scheduled.

- **Module-Local Project Cache**: a module-level variable holding the project_id the module believes is active. Each cache MUST stay synchronized with the live database, and every consumer of the cache MUST validate before writing.

- **Audit Catalog**: a committed document (the deliverable for FR-007) listing every post-switch handler in the codebase, its classification, and its migration status.

---

## Resolved Decisions

All open decisions have been resolved in this session's clarifications.

- **Lua-callback assertion-failure policy / pre-switch handler error policy** — *Resolved 2026-04-29:* log a stack trace and continue. Matches JVE_ASSERT semantics. FR-008 / FR-009 updated.
- **Defensive validation: permanent or stopgap?** — *Resolved 2026-04-29:* permanent. Defense in depth. FR-006 updated.

---

## Review & Acceptance Checklist

### Content Quality

- [x] Source files / line numbers in the original input are scoping hints; the spec phrases requirements behaviorally.
- [x] Focused on correctness and observability, not implementation mechanics.
- [x] Written for engineers maintaining handlers and the signal contract.
- [x] All mandatory sections completed.

### Requirement Completeness

- [x] No `[NEEDS CLARIFICATION]` markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable (zero asserts in TSO; audit catalog committed; tests pass)
- [x] Scope is clearly bounded (Non-Goals section)
- [x] Dependencies and assumptions identified

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed

---

## Unresolved Questions (concise)

*(none — see Resolved Decisions)*
