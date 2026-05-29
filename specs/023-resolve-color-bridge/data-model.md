# Data Model: Resolve Color Roundtrip Bridge (schema V11 → V12)

Two new persisted tables in `src/lua/schema.sql`. No migration — bump `schema_version` to 12; Joe regenerates the `.jvp` (`feedback_schema_bump_freely`). The helper's idempotency ledger is **not** persisted here (process-local).

Source: spec.md FR-011..017, FR-013a; clarifications 2026-05-29 (same-machine, read-only, one target, manual sync, cascade+stale). Mirrors research.md §5.1.

---

## Entity: `clip_grade`

A per-clip color grade read back from Resolve. Read-only in JVE.

```sql
CREATE TABLE IF NOT EXISTS clip_grade (
    clip_id     TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    -- CDL primaries (linear floats). All-NULL when fidelity has no representable CDL.
    slope_r REAL, slope_g REAL, slope_b REAL,
    offset_r REAL, offset_g REAL, offset_b REAL,
    power_r REAL, power_g REAL, power_b REAL,
    saturation REAL,
    lut_ref     TEXT,                       -- local LUT path (same-machine), or NULL
    fidelity    TEXT NOT NULL,              -- 'primary' | 'partial' | 'unrepresentable'
    source      TEXT NOT NULL,              -- provenance, e.g. 'resolve_readback'
    stale       INTEGER NOT NULL,           -- 0/1; writer always sets it (no SQL default — 2.13). 1 = source Resolve item absent at last read-back
    synced_at   INTEGER NOT NULL            -- unix seconds of last successful sync
);
```

**Fields / validation**
- `clip_id` — PK and FK to `clips(id)`; one grade per clip (FR-014 grade-attaches-to-clip, clarification: one target). `ON DELETE CASCADE` ⇒ deleting a clip drops its grade (FR-013a).
- CDL primaries — REAL. Either all nine + `saturation` are present (a representable CDL) or all NULL. Assert this invariant at the model write boundary; never store a partial CDL (constitution VII).
- `lut_ref` — local filesystem path; NULL if the grade has no baked LUT. Cross-machine LUT transport is out of scope (clarification: same-machine).
- `fidelity` — enum, NOT NULL. `'primary'` ⇒ CDL fully represents the grade; `'partial'`/`'unrepresentable'` ⇒ Resolve grade exceeds CDL/LUT (FR-015). The model rejects any other value (assert).
- `stale` — set to 1 when read-back finds the clip's Resolve item gone (FR-013a). Never silently cleared; the grade values are retained. A subsequent successful sync clears it back to 0.
- `source` — provenance string; `'resolve_readback'` for v1 (no JVE-authored grades — read-only).

**Lifecycle**
- **Created/updated**: only by the `SyncGradesFromResolve` command (FR-017) via upsert. Never written outside a `command_event` (`todo_command_bypass_enforcement`).
- **Undo**: the command captures prior rows and restores them.
- **Deleted**: only by FK cascade when the clip is deleted. No standalone delete.

---

## Entity: `resolve_bridge_link` (identity ledger)

Persisted mapping from a JVE clip to its Resolve timeline item, surviving JVE re-edits so re-conform doesn't scramble grades (FR-011, §2.2). One Resolve target per project ⇒ keyed on clip id alone.

```sql
CREATE TABLE IF NOT EXISTS resolve_bridge_link (
    jve_clip_uuid     TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    resolve_item_id   TEXT NOT NULL,        -- the Resolve timeline-item id recovered via the join key
    grade_fingerprint TEXT                  -- hash of last-synced grade, for change detection
);
```

**Fields / validation**
- `jve_clip_uuid` — PK and FK to `clips(id)`; `ON DELETE CASCADE` drops the link when the clip is deleted (FR-013a).
- `resolve_item_id` — opaque Resolve identifier returned by `import_timeline`/`read_identities` (NOT NULL).
- `grade_fingerprint` — fingerprint of the grade last synced for this clip; used to detect "did this grade change in Resolve since last sync" without diffing full CDLs. NULL until first grade sync.

**Lifecycle**
- **Created/updated**: by `SendToResolve` (records the import mapping) and `SyncGradesFromResolve` (updates `grade_fingerprint`).
- **Reconcile (re-conform, FR-012)**: on re-send, for each current JVE clip —
  - clip UUID unchanged → keep its existing `resolve_item_id`;
  - clip is a blade/split fragment of a clip present at last send → both fragments inherit the parent's `resolve_item_id`, so both inherit the parent's grade (clarification: bladed both-inherit). The exact fragment-recognition rule (candidate: `media.file_uuid` + overlapping source TC range) is a Phase-4 de-risk decision (spec Deferred).
  - clip with no prior link → new Resolve item; recorded after import.
- **Deleted**: only by FK cascade.

---

## Relationships

```
clips (1) ──< clip_grade            (0..1 grade per clip; cascade delete)
clips (1) ──< resolve_bridge_link   (0..1 link per clip;  cascade delete)
clip_grade.clip_id  == resolve_bridge_link.jve_clip_uuid  (both are clips.id)
```

A clip may have a link without a grade (sent but not yet graded) or a grade without a current link (Resolve item later deleted → grade marked `stale`).

## Model layer

`src/lua/models/clip_grade.lua` — mirrors existing model conventions (`models/clip.lua`: no `database.get_connection()` from commands; SQL isolation policy). Public surface:
- `ClipGrade.load(clip_id)` / `ClipGrade.batch_load(clip_ids)` — for the renderer (pull-based, FR-016).
- `ClipGrade.fingerprint(grade)` — stable hash for `grade_fingerprint`.
- write helpers used **only** by the command layer (assert CDL all-or-nothing + fidelity enum at the boundary).

`src/lua/core/resolve_bridge/identity_ledger.lua` — `resolve_bridge_link` read/write + the reconcile algorithm above.

## Non-trivial test values (constitution III)

- A clip at TC `01:00:04:12` @ 23.976 with a CDL of slope `(1.05, 0.98, 0.92)`, offset `(0.01, 0.0, -0.02)`, power `(1.1, 1.0, 0.95)`, sat `0.85` — exercises non-unity per-channel values, not the all-1.0 identity that would hide bugs.
- A `partial`-fidelity clip with a LUT path and NULL CDL — exercises the fidelity/representability branch.
- A graded clip whose Resolve item is removed → `stale=1`, grade retained.
- Delete the clip → both `clip_grade` and `resolve_bridge_link` rows gone (cascade).

**Failure-path tests (ENGINEERING 2.32)** — assert boundaries tested via `pcall`, validating the message is actionable (names the clip id + the violated invariant):
- Writing a partial CDL (e.g. `slope_r` set, `power_b` NULL) → asserts (all-nine-or-none invariant).
- Writing `fidelity` outside the enum → asserts.
- Writing a `clip_grade` outside a `command_event` → asserts (command-only mutation, `todo_command_bypass_enforcement`).
