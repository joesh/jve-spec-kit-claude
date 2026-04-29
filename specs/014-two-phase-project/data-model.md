# Data Model: Two-Phase Project Switch

**Feature**: 014-two-phase-project · **Phase 1** · **Date**: 2026-04-29

The feature has no schema changes. The "data" here is signal payload shape, in-flight state machine, and the audit-catalog row schema. SQL schema is unaffected.

---

## 1. Project Switch Event

A logical operation with two synchronous phases. Not persisted; lives only as in-flight signal payload.

### Fields

| Field | Type | Notes |
|---|---|---|
| `outgoing_project_id` | string \| nil | nil only at cold start (no prior project) |
| `incoming_project_id` | string \| nil | nil when closing without replacement |
| `phase` | enum: `pre`, `post` | Which signal is firing right now |
| `drain_budget_ms` | integer | Fixed at 1000 per FR-003a; not runtime-tunable |

### Lifecycle

```
none ──(open P1)──► open(P1)
       outgoing=nil       │
       incoming=P1        │
                          │ (open P2)
                          │ outgoing=P1, incoming=P2
                          ▼
                     switching(P1, P2)
                       │
                       │ phase=pre  → emit project_will_change(P1)
                       │ database.init(P2)
                       │ phase=post → emit project_changed(P2)
                       ▼
                     open(P2)
                       │
                       │ (close project)
                       │ outgoing=P2, incoming=nil
                       ▼
                     switching(P2, nil)
                       │
                       │ phase=pre  → emit project_will_change(P2)
                       │ database.detach()
                       │ phase=post → emit project_changed(nil)
                       ▼
                       none
```

### Invariants

- **Pre-phase invariant**: at the time `project_will_change` handlers run, `database.get_current_project_id() == outgoing_project_id` (or nil for cold start).
- **Post-phase invariant**: at the time `project_changed` handlers run, `database.get_current_project_id() == incoming_project_id` (or nil for close-without-replacement).
- **Atomicity**: the two phases of one switch are dispatched on the same Qt event-loop turn. No other top-level event runs between them. (Qt single-shot timers scheduled DURING the phases will fire later, in subsequent turns.)
- **Sequencing of nested switches**: if a `project_will_change` or `project_changed` handler triggers another switch (rare; e.g. an error recovery), the inner switch completes fully before the outer dispatch resumes. This is implicit from synchronous Lua dispatch but worth stating.

---

## 2. Module-Local Project Cache

A pattern, not a single entity. Documented so the audit catalog has a consistent schema.

### Schema

| Field | Type | Description |
|---|---|---|
| `module` | string | e.g. `core/media/media_status` |
| `cache_var` | string | The Lua local-or-module variable name (e.g. `current_project_id`) |
| `set_on` | enum: `project_changed`, `project_will_change`, `manual` | Which signal/path sets it |
| `cleared_on` | enum | Which signal/path clears it |
| `validate_before_write` | bool | MUST be true for all entries after this feature lands |

### Identification rule

A "module-local project cache" is any non-test source file with a top-level local or module-table field that:
- holds a `project_id` string at runtime
- is read by any function that performs a database write
- can survive a project switch (i.e. is not function-scoped)

### Active inventory (Phase 0 grep result)

| module | cache_var | set_on | cleared_on | validate_before_write |
|---|---|---|---|---|
| `core/media/media_status` | `current_project_id` | `project_changed` (via `M.load_persisted`) | `project_changed` (via `M.clear`) | NO at planning time; YES after this feature lands |

Phase 4 re-greps to confirm no new caches were added without validation.

---

## 3. Audit Catalog

The committed FR-007 deliverable, in `handler_audit.md`. The schema is fixed so future audits (when we add more lifecycle signals, say) reuse it.

### Row schema — `project_changed` handlers

| Column | Type | Description |
|---|---|---|
| `handler_label` | string | Human-readable name (e.g. `media_status flush+reload`) |
| `file` | string | Path relative to repo root |
| `line` | integer | Line of the `Signals.connect` call |
| `priority` | integer | Numeric priority (default 100 if unspecified) |
| `body_summary` | string | One-sentence description of what the handler does |
| `classification` | enum: `no-action`, `must-cancel-deferred-work`, `must-flush-pending-writes` | Per FR-007 |
| `migration_status` | enum: `none-needed`, `migrated`, `safe-by-validation` | Outcome after Phase 4 |
| `migration_notes` | string | Free-form, e.g. "moved persist_now() to project_will_change handler in same module" |
| `owner` | string | Module owner / git blame reference |

### Row schema — `qt_create_single_shot_timer` deferred work

| Column | Type | Description |
|---|---|---|
| `site_label` | string | e.g. `media_status persist debounce` |
| `file` | string | |
| `line` | integer | |
| `delay_ms` | integer or symbolic | e.g. `PERSIST_DEBOUNCE_MS` |
| `callback_summary` | string | What fires when the timer pops |
| `project_scoped` | enum: `yes`, `no`, `tbd` | Does the callback touch DB / project state? |
| `mitigation` | enum: `cancel-on-will-change`, `validate-at-fire-time`, `none-needed` | Per FR-003 |
| `migration_status` | enum: `none-needed`, `migrated`, `safe-by-validation` | |

### Constraints

- **No row may have `classification ∈ {must-cancel, must-flush}` AND `migration_status = none-needed`.** This is the key invariant the audit catalog enforces.
- **No row may have `project_scoped = yes` AND `mitigation = none-needed`.** Same invariant for the timer table.
- **Every row MUST be addressed before the feature ships.** "TBD" is acceptable in research.md (Phase 0) but not in the committed `handler_audit.md`.

---

## 4. Signal payload contracts (cross-reference)

The two signals' detailed contracts live in `contracts/signal_will_change.md`. Here's the at-a-glance:

### `project_will_change` (NEW)

- **Args**: `(outgoing_project_id: string|nil)`
- **Live invariant during dispatch**: `database.get_current_project_id() == outgoing_project_id`
- **Allowed handler ops**: write to outgoing DB (flush), cancel deferred work, snapshot state.
- **Forbidden**: opening the new DB (it doesn't exist yet); long blocking ops > drain budget.

### `project_changed` (EXISTING)

- **Args**: `(incoming_project_id: string|nil)` — unchanged
- **Live invariant during dispatch**: `database.get_current_project_id() == incoming_project_id`
- **Allowed handler ops**: clear caches, load persisted state for new project, refresh UI.
- **Forbidden**: writing to OUTGOING project's DB (it's gone); reading caches that haven't been cleared.

---

## 5. Validation rules (cross-reference)

The validation rules live in `contracts/persist_now_validation.md`. Summary:

- Every DB-write taking a `project_id` arg → `assert_project_exists(project_id)` (hard fail-loud per rule VI; matches existing semantics).
- Every module-local `current_project_id` read before write → `database.assert_project_id_is_live(cached_id, caller_label)` (logs trace, returns false; caller no-ops).
- The two layers are complementary: `assert_project_exists` is for direct API misuse (caller passed a wrong id); `assert_project_id_is_live` is for module-local-cache staleness (cache is out of sync with the live DB).

---

## State transitions (summary)

```
                   ┌─────────────┐
                   │    none     │
                   └──────┬──────┘
                          │  open(P)
                          │  emit project_will_change(nil)
                          │  database.init(P)
                          │  emit project_changed(P)
                          ▼
                   ┌─────────────┐
                   │   open(P)   │◄──┐
                   └──────┬──────┘   │
                          │          │  switch(P→Q)
                          │  close   │  emit project_will_change(P)
                          │          │  database.init(Q)
                          ▼          │  emit project_changed(Q)
                   (back to none) ───┘
                                     (Q now active; loop)
```

Every transition out of `open(X)` triggers `project_will_change(X)`. Every transition into `open(X)` (or into `none`) triggers `project_changed(X-or-nil)`. The cold-start case is the `nil → open(P)` transition: pre-switch fires with `outgoing=nil` and handlers early-return without touching the DB.
