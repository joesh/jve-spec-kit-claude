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
- `grade_fingerprint` — fingerprint of the grade last synced; detects "did the grade change in Resolve since last sync" without diffing full CDLs. NULL until first grade sync. **Contract**: nil-or-non-empty-string only; the model rejects `""` (empty string is a malformed bootstrap signal that would force re-bootstrap forever).
- `edit_fingerprint` — fingerprint of the edit state (record start/duration, source in/out, track, enabled) at last sync; an edit-pull compares the live state and the current JVE clip against this to tell a Resolve-side change from a JVE-side local change (FR-025). NULL until first connect/sync. Same nil-or-non-empty contract as `grade_fingerprint`.

**Algorithmic invariant**: each `resolve_item_id` maps to at most one JVE clip. Blade-inherit fragments do **not** get their own ledger rows — only the parent's row is persisted; fragments inherit the parent's mapping at query time. `identity_ledger.lookup_clip_id` asserts the uniqueness (defensive against reconcile bugs); a future schema bump may enforce it via `UNIQUE(resolve_item_id)`.

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

---

## SyncEditsFromResolve — classification + dispatch contract (FR-024 / FR-025)

The `read_timeline` response from the helper (`contracts/helper-protocol.md` §`read_timeline`) is classified into four buckets before any model write happens. `classify_all` is pure data; `apply` translates each `to_apply` entry into existing JVE commands under one undo group — no parallel clip-mutation path (1.9). Source: `src/lua/core/commands/sync_edits_from_resolve.lua`, `src/lua/core/resolve_bridge/edit_diff.lua`, `src/lua/core/resolve_bridge/identity_ledger.lua`.

### Scope

- **V1 ships VIDEO only.** Audio support — subframe-aware fingerprint, table-typed positional fields, sample-rate mismatch handling — lands separately (`todo_t054_audio_support`).
- **One Resolve timeline per response** (helper-protocol guarantee). The classifier does not detect cross-timeline contamination from response shape alone; it asserts each clip's `owner_sequence_id` matches the supplied `sequence_id`.
- **Schema V12+** required (`resolve_bridge_link` table and its `resolve_item_id` index).

### `classify_all(response, sequence_id, db, take_resolve_set?) → {to_apply, conflicts, skipped, unmatched}`

Inputs:
- `response` — helper `read_timeline` payload.
- `sequence_id` — JVE sequence the response describes.
- `db` — open SQLite connection (clip + ledger reads).
- `take_resolve_set` — optional `{[clip_id] = true}`; clips listed here have their stored fingerprint synthesized from `current` (caller chose Take-Resolve on a prior conflict).

Internal phases:
1. **Response walk** — `classify_row` per item: ledger lookup → clip load + invariant assert → V1 video-only assert → track-change branch → edit-diff branch.
2. **Ledger walk** — for each `resolve_bridge_link` row whose clip belongs to `sequence_id` and whose `resolve_item_id` was not seen in the response, emit a `deleted_in_resolve` conflict.

Iteration order is response order, not contractual; callers key bucket entries by `clip_id` (or `resolve_item_id` for `unmatched`).

### Bucket entry shapes

| Bucket | Required fields | Optional |
|--------|------------------|----------|
| `to_apply[]` | `clip_id, resolve_item_id, kind="resolve_only", live, current, stored_fp, track_id, track_type` | `bootstrapped`, `requires_track_move`, `target_track_id` |
| `conflicts[]` | `resolve_item_id, reason` | `clip_id, kind, live, current, stored_fp, track_id, track_type, live_track_id` |
| `skipped[]` | `clip_id, resolve_item_id, reason, live, current, stored_fp, track_id, track_type` | `bootstrapped` |
| `unmatched[]` | `resolve_item_id, reason` | — |

`kind` (the `edit_diff.classify` outcome) is preserved on `to_apply` entries and on `conflicts` entries whose reason is `diverged_both_sides`; elsewhere `reason` is the sole discriminator. `bootstrapped = true` marks entries whose `stored_fp` was synthesized from `current` (no prior ledger fingerprint); `apply` persists those fingerprints outside the undo group so subsequent syncs have a baseline.

### Closed-set reasons

```
CONFLICT_REASONS = {
    diverged_both_sides, deleted_in_resolve,
    fps_mismatch_unsupported, subframe_unsupported,
    unknown_delta_shape, composite_undecomposable,
    mutual_composite, overwrite_absorb_inconsistent,
    slip_unsupported, roll_unsupported,
    multi_mapped_ambiguous, missing_target_track_in_jve,
}
SKIP_REASONS = {
    neither_changed, only_jve_changed,
    no_modal_v1_unhandled_conflict, stale_user_choice,
    phase0_failed, phaseB_failed,
}
UNMATCHED_REASONS = { ledger_missing }
```

Every emit point asserts its `reason` is in the appropriate set — catches typos and drift between spec and code (2.21). Pass-1 `classify_all` emits a subset; the remainder become reachable in Pass-2 `apply`.

### `apply(response, sequence_id, project_id, db, user_choices?) → {applied, failed, skipped, fingerprints_persisted}`

`user_choices` (V2): `{take_resolve: [clip_id], keep_jve: [clip_id], delete_locally: [{clip_id, flavor: "ripple"|"overwrite"}]}`. The three lists are mutually exclusive per clip; `apply` asserts. V1 MVP path ignores `user_choices` and surfaces conflict entries as `apply.skipped[]` with `reason = no_modal_v1_unhandled_conflict`.

Internal flow:
1. Pre-flight intent resolution (delete-wins, mutual-exclusion assert).
2. Build `take_resolve_set`; `classify_all(response, sequence_id, db, take_resolve_set)`.
3. Persist bootstrap fingerprints for every entry — in `skipped[]` OR `to_apply[]` — with `bootstrapped = true` (outside undo group; metadata-only). Persisting bootstrapped `to_apply` entries up front means a subsequent dispatch failure leaves the baseline fingerprint in place so the next sync diffs against it.
4. V1 MVP path: surface `conflicts[]` entries into `result.skipped[]` with `reason = no_modal_v1_unhandled_conflict`, carrying the classifier's `kind / live / current / stored_fp / track_id / track_type / live_track_id` fields through verbatim (modal shape parity). Also pass through `classified.skipped` entries.
5. If no `to_apply` dispatches planned → return.
6. `command_manager.begin_undo_group("Sync Edits from Resolve")`.
7. Pre-Phase-0 — `delete_locally` dispatches (V2 only; V1 user_choices=nil → no deletes).
8. **Phase 0** — `MoveClipToTrack` per `to_apply` entry with `requires_track_move = true`.
9. **Phase A** — `ToggleClipEnabled` per clip with Δenabled.
10. **Phase B** — trim fixpoint loop (`RippleTrimEdge` / `OverwriteTrimEdge`); blanket reload of sequence clips after each `RippleTrimEdge` to absorb sync_mode cross-track propagation.
11. **Phase C** — `Nudge` for residual pure-record-start shifts.
12. **Phase D** — surface unmatched shape-residuals into `apply.skipped[]` with `reason = unknown_delta_shape`.
13. `end_undo_group`.
14. Persist post-dispatch fingerprints for clips whose every dispatched verb succeeded (outside undo group).

### Result bucket shapes

| Bucket | Required fields | Optional |
|--------|-----------------|----------|
| `applied[]` | `clip_id, resolve_item_id, attempted_verbs` (array of verb strings in dispatch order) | — |
| `failed[]` | `clip_id, resolve_item_id, attempted_verb, args, error` | — |
| `skipped[]` | `clip_id, resolve_item_id, reason` | `kind, live, current, stored_fp, track_id, track_type, live_track_id` (carried from classifier) |
| `fingerprints_persisted[]` | `clip_id, resolve_item_id, edit_fingerprint, origin` (`"bootstrap"` or `"phase_success"`) | — |

`failed[]` is per-(clip, verb): one entry per attempted dispatch that returned `success=false`. Per-phase failure cascade: Phase 0 failure cascade-skips A/B/C for that clip (`reason = phase0_failed` added to `skipped[]`); Phase A failure is independent (`enabled` is geometrically inert); Phase B failure cascade-skips C (`reason = phaseB_failed`). Fingerprints persist only for clips whose every attempted phase succeeded; partial-success clips retain their prior fingerprint so the next sync retries.

### Dispatch verbs

```
DISPATCH_VERBS = {
    MoveClipToTrack, ToggleClipEnabled,
    RippleTrimEdge, OverwriteTrimEdge, Nudge,
    DeleteClip, RippleDelete,
}
```

Adding a verb means updating this constant and this section; the dispatcher asserts every `command_manager.execute` verb name is in the set.

### Modal contract

The conflict modal consumes `conflicts[]`, surfaces per-row choices, and returns `user_choices` to `apply`. V1 modal does not show auto-`to_apply` entries — those dispatch by implicit consent; a user can undo the whole sync after the fact. UI layout lives in `src/lua/ui/` and evolves independently of this data contract.
