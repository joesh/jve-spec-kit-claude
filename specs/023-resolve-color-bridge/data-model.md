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

## Clip identity (inbound adoption — FR-011b)

`clip.id` is **not always a JVE-minted UUID.** Mirroring the existing `media.id = MediaRef DbId or uuid.generate()` rule (`importer_core.lua`), the DRP/DRT importer adopts the Resolve **timeline-item id** (`Sm2TiVideoClip`/`Sm2TiAudioClip` `DbId`) as `clip.id` when present, else mints a UUID. Consequences:

- For an imported clip, `clip.id` **is** the Resolve item id — the identity link is the id itself (no `resolve_bridge_link` row needed to know the mapping; a row is still used to carry fingerprints).
- Video and audio of one synced clip are distinct Resolve items with distinct DbIds → distinct JVE clips, no PK collision.
- Clips JVE creates after import (blades, paste) get fresh UUIDs and match positionally.
- Re-importing the same DRP yields the same `clip.id`s (stable across re-imports — fixes the prior "fresh ids each import" gap).
- No schema change: `clips.id` is already `TEXT PRIMARY KEY` and already holds non-UUID ids for media; a grep confirmed no code assumes `clip.id` is UUID-shaped.

## Entity: `resolve_bridge_link` (identity + sync ledger)

Persisted per-clip bridge state: the Resolve item correspondence plus the fingerprints used for change/conflict detection (FR-011). Bidirectional — see "Clip identity" above: for imported clips `resolve_item_id` equals `clip.id`; for JVE-originated (UUID) clips it is the matched Resolve id. One Resolve target per project ⇒ keyed on clip id alone.

```sql
CREATE TABLE IF NOT EXISTS resolve_bridge_link (
    jve_clip_uuid     TEXT PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
    resolve_item_id   TEXT NOT NULL,        -- Resolve timeline-item id; == clip.id for imported clips
    grade_fingerprint TEXT,                 -- hash of last-synced grade, for change detection
    edit_fingerprint  TEXT                  -- hash of last-synced edit state (record/source/track/enabled), for conflict detection (FR-025)
);
```

**Fields / validation**
- `jve_clip_uuid` — PK and FK to `clips(id)`; `ON DELETE CASCADE` drops the link when the clip is deleted (FR-013a).
- `resolve_item_id` — Resolve timeline-item id (NOT NULL). For imported clips it equals `clip.id`; carried explicitly so UUID clips (matched positionally) and imported clips share one schema.
- `grade_fingerprint` — fingerprint of the grade last synced; detects "did the grade change in Resolve since last sync" without diffing full CDLs. NULL until first grade sync.
- `edit_fingerprint` — fingerprint of the edit state (record start/duration, source in/out, track, enabled) at last sync; an edit-pull compares the live state and the current JVE clip against this to tell a Resolve-side change from a JVE-side local change (FR-025). NULL until first connect/sync.

**Lifecycle**
- **Created/updated**: by `SendToResolve` (outbound mapping), `ConnectToResolveProject` (inbound — id match per FR-011b, else positional per FR-011c), `SyncGradesFromResolve` (`grade_fingerprint`), and `SyncEditsFromResolve` (`edit_fingerprint`). Always inside a `command_event`.
- **Reconcile (FR-012)**: on re-send / re-connect, for each current JVE clip —
  - `clip.id` matches a live Resolve item id → direct link (the common case for imported clips);
  - else positional/content match (`media.file_uuid` + source TC + timeline position, FR-011c);
  - blade/split fragment of a prior clip → both fragments inherit the parent's `resolve_item_id` and grade (bladed both-inherit). Exact fragment-recognition is a Phase-4 de-risk decision (spec Deferred).
  - unmatched → reported, not silently dropped.
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
