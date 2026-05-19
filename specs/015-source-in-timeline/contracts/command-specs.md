# Command SPEC contracts

**Feature**: 015-source-in-timeline
**Date**: 2026-05-03

JVE's command framework expects each command to expose a `SPEC` table with `args`, `persisted`, and behavior flags. This document is the contract for the new and refactored commands introduced by this feature. Each command's `SPEC` is reproduced here as authoritative; the implementation in `src/lua/core/commands/` MUST match.

---

## C1. Command framework extension — `undoable = false` SPEC flag

**Modifies**: `src/lua/core/command_manager.lua`.

**Contract**: A new boolean SPEC flag `undoable = false` (default `false`). When `true`, the command framework MUST:
1. Skip writing a row to the per-sequence undo stack (`commands` table column `undo_group_id` SHOULD remain NULL or the row SHOULD be excluded from undo-cursor walks — exact mechanism deferred to /tasks).
2. Skip producing a `snapshots` row.
3. Still set `sequence_id` on the command row (rule 2.29 — for routing scope and replay-on-load semantics).
4. Still emit any signals the command would normally emit.

**Assertions** (rule 1.14, FR-047.8 path):
- After a `SPEC.undoable = false` command executes, `assert(no snapshot row was created for this command's sequence_number)`.
- After execution, `assert(per-sequence undo cursor was not advanced)`.

**Test contract**: `test_undoable_flag.lua` exercises a minimal `SPEC.undoable = false` command, verifies post-conditions, and verifies that Cmd-Z does not revert it.

---

## C2. `SetPatch` (NEW)

**File**: `src/lua/core/commands/set_patch.lua`

```lua
local SPEC = {
    args = {
        sequence_id        = { required = true,  kind = "string" },
        source_track_index = { required = true,  kind = "number" },
        enabled            = { required = false },                  -- boolean; nil means unchanged
        record_track_index = { required = false, kind = "number" }, -- nil means unchanged
    },
    persisted = {},     -- non-undoable; no previous_value capture
    undoable = false,
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
}
```

(Field shapes match existing JVE convention from `set_track_property.lua`. Range constraints — e.g. `source_track_index >= 0`, `enabled ∈ {true,false}` — are runtime asserts in the executor, not SPEC fields.)

**Behavior**:
- If no `patches` row exists for `(sequence_id, source_track_index)`, the executor INSERTS one with `enabled=1`, `record_track_index = source_track_index` (identity default), then applies the supplied `enabled` and/or `record_track_index` overrides.
- If a row exists, the executor UPDATEs the supplied fields; unsupplied fields are unchanged.
- Emits `patch_changed` signal with `(sequence_id, source_track_index)` payload.

**Asserts** (FR-047.5):
- `assert(args.sequence_id and Sequence.exists(args.sequence_id), ...)`.
- `assert(args.source_track_index >= 0)`.
- If `record_track_index` provided: `assert(args.record_track_index >= 0)`.
- After write: `assert(<patch row state matches args>)`.

**No undoer** — `SPEC.undoable = false` means undo dispatcher never invokes one.

---

## C3. `SetSyncMode` (NEW)

**File**: `src/lua/core/commands/set_sync_mode.lua`

```lua
local SPEC = {
    args = {
        track_id  = { required = true, kind = "string" },
        sync_mode = { required = true, kind = "string" },  -- enum constraint enforced at runtime + SQL CHECK
    },
    persisted = {},
    undoable = false,
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
}
```

**Behavior**:
- UPDATE `tracks SET sync_mode = ? WHERE id = ?`.
- Emits `sync_mode_changed` signal with `(track_id, new_sync_mode, previous_sync_mode)`.

**Asserts** (FR-047.2):
- `assert(args.sync_mode == 'off' or args.sync_mode == 'ripple' or args.sync_mode == 'cut', "SetSyncMode: invalid sync_mode '" .. tostring(args.sync_mode) .. "' for track " .. tostring(args.track_id))`
- `assert(Track.exists(args.track_id), "SetSyncMode: track " .. tostring(args.track_id) .. " not found")`

---

## C4. `SetTrackProperty` REFACTOR (FR-040a bug fix)

**File**: `src/lua/core/commands/set_track_property.lua` — refactor.

**Decision (per research R2)**: SPLIT into two commands:

### C4a. `ToggleTrackPreference` (NEW — non-undoable)

```lua
local SPEC = {
    args = {
        track_id = { required = true, kind = "string" },
        property = { required = true, kind = "string" },  -- enum enforced at runtime
        value    = { required = true },                   -- boolean; framework `kind` may not have a "boolean" idiom
    },
    persisted = {},
    undoable = false,                      -- THE FIX (FR-040a)
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
}
```

**Behavior**: writes the boolean directly to `tracks.<property>`. Emits `track_preference_changed` signal. NO undoer registered.

**Asserts**:
- `assert(args.property == 'muted' or args.property == 'soloed' or args.property == 'locked' or args.property == 'enabled', "ToggleTrackPreference: invalid property '" .. tostring(args.property) .. "'")`
- `assert(type(args.value) == 'boolean', "ToggleTrackPreference: value must be boolean")`

### C4b. `SetTrackMixValue` (renamed-and-narrowed from existing `SetTrackProperty`)

```lua
local SPEC = {
    args = {
        track_id   = { required = true, kind = "string" },
        property   = { required = true, kind = "string" },  -- enum (volume/pan) enforced at runtime
        value      = { required = true, kind = "number" },
        project_id = { required = true, kind = "string" },
    },
    persisted = {
        previous_value = {},
    },
    skip_clip_snapshot = true,                -- existing optimization preserved
    -- undoable = false NOT set — volume/pan changes remain undoable (existing behavior)
}
```

**Behavior**: unchanged from current `SetTrackProperty` minus the boolean property branches. Existing `track_mix_changed` signal emission preserved.

**Migration of existing call sites**: any UI code calling `SetTrackProperty` with `muted/soloed/locked/enabled` MUST switch to `ToggleTrackPreference`; calls with `volume/pan` MUST switch to `SetTrackMixValue`. Per rule 2.15 (no backward compat), `SetTrackProperty` is REMOVED in this feature; no shim, no rename.

---

## C5. `ShowSourceTab` (NEW)

**File**: `src/lua/core/commands/show_source_tab.lua`

```lua
local SPEC = {
    args = {},                                -- no args; reads source monitor's loaded master
    persisted = {},
    undoable = false,                      -- tab visibility is a UI preference
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
}
```

**Behavior**:
- Read the source monitor's loaded `master_seq_id` via `panel_manager.get_sequence_monitor("source_monitor"):get_loaded_master_seq_id()`.
- If no master is loaded: open the SourceTab anyway and render the empty placeholder (FR-007b). NO error.
- If master is loaded: open or activate the SourceTab in the tab strip (extending `open_tabs` per R3).
- Emits `source_tab_visibility_changed` signal.

**Asserts**:
- `assert(panel_manager exists and source_monitor is registered, ...)`.

**Inverse command**: `CloseSourceTab` (or the existing `close_tab(sequence_id)` path with the SourceTab's sequence_id) handles the × close affordance. If the source-monitor's loaded master changes WHILE the SourceTab is closed, no action — the tab remains closed until the user invokes `ShowSourceTab` again.

---

## C6. Edit commands extension (FR-029b auto-create)

**Files modified**: existing edit commands that resolve patches and target record tracks (e.g., `Insert`, `Overwrite`, the 3-point edit dispatch). The exact list is determined in /tasks based on which commands consume patches.

**Contract addition**: each such command's executor, BEFORE applying mutations, MUST iterate the active sequence's enabled patches and ensure a record track exists at every `record_track_index` referenced by an enabled patch. If not, the executor calls `AddTrack` within the SAME undo group so that one user-visible Cmd-Z reverts the edit + the auto-created tracks together.

**Asserts** (FR-047.6):
- `assert(<each enabled patch's record_track_index has a corresponding tracks row after the auto-create step>)`.
- `assert(<auto-created tracks were registered into the active sequence's track list before the mutation step>)`.

---

## C7. Ripple pipeline extension (FR-026)

**Files modified**:
- `src/lua/core/ripple/batch/pipeline.lua` — add new step `apply_per_track_sync_mode_dispatch(ctx)` BEFORE `ops.inject_implicit_gap_edges(ctx)`.
- `src/lua/core/commands/batch_ripple_edit.lua` — implement the new ops function.

**New ops function**: `apply_per_track_sync_mode_dispatch(ctx)`. Walks `ctx.track_clip_map`. For each track:

```
if track.sync_mode == 'off':
    mark track for exclusion from inject_implicit_gap_edges

elif track.sync_mode == 'ripple':
    no-op  (existing behavior)

elif track.sync_mode == 'cut':
    for each clip on this track that spans the trim point:
        synthesize a split edge at the trim point and add to ctx.edges
        (downstream half then ripples normally via inject_implicit_gap_edges + compute_downstream_shifts)

else:
    assert(false, 'apply_per_track_sync_mode_dispatch: unknown sync_mode "%s" on track %s', track.sync_mode, track.id)
```

**Post-condition asserts** (FR-026):
- After the full pipeline run, `assert(<no clip on any 'cut'-mode track spans the trim point>)`.
- `assert(<every produced clip is at least one frame at sequence rate>)` — reuses existing quantization invariant from JVE's manual blade tool (FR-027).
- `assert(<every 'off'-mode track's track-length is unchanged>)`.

---

## C8. Removed commands

Per rule 2.15:
- `SetTrackProperty` is REMOVED. Existing call sites must migrate to `ToggleTrackPreference` (booleans) or `SetTrackMixValue` (numerics).

---

## C9. Test contracts

Each command MUST have a `tests/test_<command_name>.lua` file with at minimum:

- **Happy path**: command executes, target row reflects new state, signal emitted, no `snapshots` row created (for non-undoable commands).
- **Failure path** (per rule 2.32 via `pcall`): each assert site fired with the expected error message format. Validate that the message includes the offending id.
- **Non-undoable invariant** (for non-undoable commands): post-execute, `commands` table row was NOT pushed to per-sequence undo cursor, and Cmd-Z does NOT revert the change. (THE regression test for FR-040a.)
- **Schema-constraint failures** (where applicable): UNIQUE violation, CHECK violation, FK CASCADE — all surface as Lua errors that the test catches.
