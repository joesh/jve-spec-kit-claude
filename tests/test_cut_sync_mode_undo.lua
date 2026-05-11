#!/usr/bin/env luajit

-- Test: cut sync-mode ripple trim and undo correctness.
--
-- Domain behaviors under test:
--
-- T1 (cut-mode splits spanning clip):
--   When a clip on V1 is ripple-trimmed, and V2 has sync_mode='cut', a V2 clip
--   that spans the trim boundary is split at that boundary. The left half stays
--   anchored; the right half stays at its original TC position (cut-mode
--   preserves downstream TC under the current workaround — see
--   test_ripple_sync_cut header).
--
-- T2 (undo restores exact pre-trim state):
--   After undoing the ripple trim, the DB must return to exactly the pre-trim
--   state: V1's clip duration is restored, the right-half clip created by the
--   cut-mode split is deleted, and the left-half clip's duration is restored to
--   its original value. No phantom clips remain.
--
-- T3 (off-mode track is unaffected):
--   A track with sync_mode='off' is excluded from both ripple shift and cut
--   dispatch. Its clip stays exactly where it was throughout.
--
-- T4 (redo re-applies the split):
--   Redo after undo must re-produce the same DB state as the original execute:
--   V1 shortened, V2 split, right half at the shifted position.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local Command         = require("command")
local command_manager = require("core.command_manager")
local Clip            = require("models.clip")
local ripple_layout   = require("tests.helpers.ripple_layout")
local timeline_state  = require("ui.timeline.timeline_state")

print("=== test_cut_sync_mode_undo.lua ===")

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Verify in-memory clip_state matches expected count and positions.
-- The UI renders from clip_state, NOT from the DB — this catches bugs
-- where DB is correct but the renderer sees stale/wrong data.
local function inmem_clips_on_track(track_id)
    local list = timeline_state.get_track_clip_index(track_id) or {}
    local out = {}
    for _, c in ipairs(list) do
        if not c.is_gap then
            out[#out+1] = {id=c.id, timeline_start=c.timeline_start, duration=c.duration}
        end
    end
    table.sort(out, function(a,b) return a.timeline_start < b.timeline_start end)
    return out
end


local function load_clip_opt(clip_id)
    local ok, c = pcall(Clip.load, clip_id)
    if not ok then return nil end
    return c
end

local function all_timeline_clips_on_track(db, track_id)
    local rows = {}
    local s = db:prepare(
        "SELECT id, timeline_start_frame, duration_frames FROM clips "
        .. "WHERE track_id=? ORDER BY timeline_start_frame")
    assert(s, string.format("all_timeline_clips_on_track: prepare failed for track %s", tostring(track_id)))
    s:bind_value(1, track_id); s:exec()
    while s:next() do
        rows[#rows + 1] = {
            id             = s:value(0),
            timeline_start = s:value(1),
            duration       = s:value(2),
        }
    end
    s:finalize()
    return rows
end

-- ── fixture ──────────────────────────────────────────────────────────────────
-- V1: anchor clip at [0, 1000) — this is what we trim.
-- V2: long clip at [0, 2000) — sync_mode set to 'cut' below.
-- V3: clip at [500, 1500) — sync_mode set to 'off' below.
-- No right-side clips: this is a pure extend/shrink test.

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_cut_sync_mode_undo.db",
    tracks = {
        order = {"v1", "v2", "v3"},
        v1 = {id = "track_v1", name = "V1", track_type = "VIDEO", track_index = 1, enabled = 1},
        v2 = {id = "track_v2", name = "V2", track_type = "VIDEO", track_index = 2, enabled = 1},
        v3 = {id = "track_v3", name = "V3", track_type = "VIDEO", track_index = 3, enabled = 1},
    },
    clips = {
        order = {"v1_anchor", "v2_long", "v3_off"},
        v1_anchor = {
            id             = "clip_v1_anchor",
            track_key      = "v1",
            timeline_start = 0,
            duration       = 1000,
            source_in      = 500,    -- non-zero so source_out computation is exercised
        },
        v2_long = {
            id             = "clip_v2_long",
            track_key      = "v2",
            timeline_start = 0,
            duration       = 2000,
            source_in      = 0,
        },
        v3_off = {
            id             = "clip_v3_off",
            track_key      = "v3",
            timeline_start = 500,
            duration       = 1000,
            source_in      = 0,
        },
    },
})

-- Set sync modes: V2 → cut, V3 → off (V1 stays default ripple)
command_manager.execute("SetSyncMode", {
    track_id   = "track_v2",
    sync_mode  = "cut",
    project_id = layout.project_id,
})
command_manager.execute("SetSyncMode", {
    track_id   = "track_v3",
    sync_mode  = "off",
    project_id = layout.project_id,
})

-- Re-init timeline_state so it picks up the current track+clip state after
-- the SetSyncMode writes. SetSyncMode is not undoable so it's safe to
-- re-init here without affecting undo history.
layout:init_timeline_state()

local db = layout.db

-- ── T1: cut-mode splits the spanning V2 clip at the trim boundary ─────────

print("\n-- T1: cut-mode splits spanning V2 clip")

-- Trim V1's out-edge by -200 (shrink from 1000→800).
-- trim_point for out-edge = base_clip.timeline_start + base_clip.duration = 0+1000 = 1000.
-- V2 clip spans [0, 2000), so it straddles frame 1000 → must be split.
local trim_cmd = Command.create("BatchRippleEdit", layout.project_id)
trim_cmd:set_parameter("sequence_id", layout.sequence_id)
trim_cmd:set_parameter("edge_infos", {
    {clip_id = "clip_v1_anchor", edge_type = "out", track_id = "track_v1"},
})
trim_cmd:set_parameter("delta_frames", -200)

local result = command_manager.execute(trim_cmd)
assert(result and result.success, string.format(
    "T1: BatchRippleEdit should succeed; got: %s", tostring(result and result.error_message)))

-- V1 clip must be shorter.
local v1_after = load_clip_opt("clip_v1_anchor")
assert(v1_after, "T1: V1 anchor clip missing after trim")
assert(v1_after.duration == 800, string.format(
    "T1: V1 duration must be 800 after -200 trim; got %d", v1_after.duration))

-- V2 must now have TWO clips (split at frame 1000).
local v2_clips_t1 = all_timeline_clips_on_track(db, "track_v2")
assert(#v2_clips_t1 == 2, string.format(
    "T1: V2 must have exactly 2 clips after cut-mode split; got %d", #v2_clips_t1))

-- Left half: anchored at 0, duration up to the split point (frame 1000).
local v2_left = v2_clips_t1[1]
assert(v2_left.timeline_start == 0,
    string.format("T1: V2 left half must start at 0; got %d", v2_left.timeline_start))
assert(v2_left.duration == 1000,
    string.format("T1: V2 left half must span to split point (dur=1000); got %d", v2_left.duration))
assert(v2_left.id == "clip_v2_long",
    "T1: original V2 clip id must be the left half")

-- Right half: stays at original TC position (cut mode preserves downstream TC).
-- A 200-frame implicit gap forms between V1's new out (800) and V2's right start (1000).
local v2_right = v2_clips_t1[2]
assert(v2_right.timeline_start == 1000, string.format(
    "T1: V2 right half must stay at 1000 (cut mode preserves downstream TC); got %d",
    v2_right.timeline_start))
assert(v2_right.duration == 1000, string.format(
    "T1: V2 right half must have dur=1000; got %d", v2_right.duration))

-- V3 (sync_mode='off') must be completely untouched.
local v3_clips_t1 = all_timeline_clips_on_track(db, "track_v3")
assert(#v3_clips_t1 == 1,
    string.format("T1: V3 (off mode) must still have exactly 1 clip; got %d", #v3_clips_t1))
assert(v3_clips_t1[1].timeline_start == 500,
    string.format("T1: V3 clip must not move (off mode); got start=%d", v3_clips_t1[1].timeline_start))
assert(v3_clips_t1[1].duration == 1000,
    string.format("T1: V3 clip duration unchanged; got %d", v3_clips_t1[1].duration))

-- In-memory state (what the renderer sees) must match DB state.
-- Tests that only check DB can pass while the UI is broken.
local v2_inmem_t1 = inmem_clips_on_track("track_v2")
assert(#v2_inmem_t1 == 2, string.format(
    "T1 (in-mem): V2 clip_state must have 2 clips; got %d", #v2_inmem_t1))
assert(v2_inmem_t1[1].timeline_start == 0 and v2_inmem_t1[1].duration == 1000,
    string.format("T1 (in-mem): V2 left half wrong; ts=%d dur=%d",
        v2_inmem_t1[1].timeline_start, v2_inmem_t1[1].duration))
assert(v2_inmem_t1[2].timeline_start == 1000 and v2_inmem_t1[2].duration == 1000,
    string.format("T1 (in-mem): V2 right half wrong; ts=%d dur=%d",
        v2_inmem_t1[2].timeline_start, v2_inmem_t1[2].duration))

print("T1 passed")

-- ── T2: undo restores exact pre-trim DB state ─────────────────────────────

print("\n-- T2: undo restores exact pre-trim state")

command_manager.undo()

-- V1 anchor must be back to original duration=1000.
local v1_undone = load_clip_opt("clip_v1_anchor")
assert(v1_undone, "T2: V1 anchor clip must exist after undo")
assert(v1_undone.duration == 1000, string.format(
    "T2: V1 must be restored to duration=1000 after undo; got %d", v1_undone.duration))
assert(v1_undone.timeline_start == 0,
    string.format("T2: V1 timeline_start must be 0 after undo; got %d", v1_undone.timeline_start))

-- V2 must be a SINGLE clip again (right half deleted by undo).
local v2_clips_t2 = all_timeline_clips_on_track(db, "track_v2")
assert(#v2_clips_t2 == 1, string.format(
    "T2: V2 must have exactly 1 clip after undo (right half deleted); got %d", #v2_clips_t2))

-- The surviving clip must be the original clip at its original position and duration.
local v2_restored = v2_clips_t2[1]
assert(v2_restored.id == "clip_v2_long",
    "T2: surviving V2 clip must be the original (clip_v2_long)")
assert(v2_restored.timeline_start == 0,
    string.format("T2: V2 must start at 0 after undo; got %d", v2_restored.timeline_start))
assert(v2_restored.duration == 2000, string.format(
    "T2: V2 must be restored to full duration=2000 after undo; got %d", v2_restored.duration))

-- Right half must be gone from DB entirely.
local v2_right_after_undo = load_clip_opt(v2_right.id)
assert(v2_right_after_undo == nil, string.format(
    "T2: right-half clip %s must be deleted from DB after undo", tostring(v2_right.id)))

-- V3 still untouched.
local v3_clips_t2 = all_timeline_clips_on_track(db, "track_v3")
assert(#v3_clips_t2 == 1 and v3_clips_t2[1].timeline_start == 500,
    "T2: V3 (off mode) unchanged after undo")

-- In-memory state after undo must match restored DB.
local v2_inmem_t2 = inmem_clips_on_track("track_v2")
assert(#v2_inmem_t2 == 1, string.format(
    "T2 (in-mem): V2 clip_state must have 1 clip after undo; got %d", #v2_inmem_t2))
assert(v2_inmem_t2[1].id == "clip_v2_long",
    "T2 (in-mem): surviving V2 clip in cache must be original clip_v2_long")
assert(v2_inmem_t2[1].duration == 2000, string.format(
    "T2 (in-mem): V2 clip in cache must be restored to dur=2000; got %d", v2_inmem_t2[1].duration))

print("T2 passed")

-- ── T3 (already verified inline above, named check here) ──────────────────
print("\n-- T3: off-mode track verification (covered by T1/T2 inline checks)")
print("T3 passed")

-- ── T4: redo re-applies the split ─────────────────────────────────────────

print("\n-- T4: redo reproduces original trim+split state")

command_manager.redo()

-- V1 must be short again.
local v1_redone = load_clip_opt("clip_v1_anchor")
assert(v1_redone and v1_redone.duration == 800, string.format(
    "T4: V1 must be 800 after redo; got %s",
    tostring(v1_redone and v1_redone.duration)))

-- V2 must have 2 clips again, in the same positions as T1.
local v2_clips_t4 = all_timeline_clips_on_track(db, "track_v2")
assert(#v2_clips_t4 == 2, string.format(
    "T4: V2 must have 2 clips after redo; got %d", #v2_clips_t4))

local v2_left_t4  = v2_clips_t4[1]
local v2_right_t4 = v2_clips_t4[2]
assert(v2_left_t4.timeline_start == 0 and v2_left_t4.duration == 1000,
    string.format("T4: V2 left half must be [0, 1000); got start=%d dur=%d",
        v2_left_t4.timeline_start, v2_left_t4.duration))
assert(v2_right_t4.timeline_start == 1000 and v2_right_t4.duration == 1000,
    string.format("T4: V2 right half must stay at [1000, 2000) (cut mode); got start=%d dur=%d",
        v2_right_t4.timeline_start, v2_right_t4.duration))

-- V3 still untouched.
local v3_clips_t4 = all_timeline_clips_on_track(db, "track_v3")
assert(#v3_clips_t4 == 1 and v3_clips_t4[1].timeline_start == 500,
    "T4: V3 (off mode) unchanged after redo")

-- In-memory state after redo must match re-applied split.
local v2_inmem_t4 = inmem_clips_on_track("track_v2")
assert(#v2_inmem_t4 == 2, string.format(
    "T4 (in-mem): V2 clip_state must have 2 clips after redo; got %d", #v2_inmem_t4))
assert(v2_inmem_t4[1].timeline_start == 0 and v2_inmem_t4[1].duration == 1000,
    string.format("T4 (in-mem): V2 left half wrong; ts=%d dur=%d",
        v2_inmem_t4[1].timeline_start, v2_inmem_t4[1].duration))
assert(v2_inmem_t4[2].timeline_start == 1000 and v2_inmem_t4[2].duration == 1000,
    string.format("T4 (in-mem): V2 right half wrong; ts=%d dur=%d",
        v2_inmem_t4[2].timeline_start, v2_inmem_t4[2].duration))

print("T4 passed")

layout:cleanup()
print("\n✅ test_cut_sync_mode_undo.lua passed")
