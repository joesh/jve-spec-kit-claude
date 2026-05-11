#!/usr/bin/env luajit

-- 015 — cut-mode regression: when track sync_mode='cut' and a clip on that
-- track spans the ripple boundary, the cut splits the clip into left+right
-- halves. After the BatchRippleEdit completes, BOTH halves must still be in
-- the DB at the expected positions.
--
-- Reported bug: dragging V2's IN edge left by N frames with V1 in cut mode
-- (V1 has a clip spanning V2's IN frame) — V1's upstream/left half
-- "disappears" from the rendered timeline.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_cut_mode_left_half_persists.lua ===")

-- Fixture: V1 has one wide clip spanning [500, 2500). V2 has a clip at
-- [1000, 2000) — drag its IN left. V1 must be split at 1000.
local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_cut_mode_left_half_persists.db",
    fps_numerator = 1000, fps_denominator = 1,
    tracks = {
        order = {"v1", "v2"},
        v1 = {id="trk_v1", name="V1", track_type="VIDEO", track_index=1, enabled=1},
        v2 = {id="trk_v2", name="V2", track_type="VIDEO", track_index=2, enabled=1},
    },
    clips = {
        order = {"c_v1_wide", "c_v2"},
        c_v1_wide = {id="c_v1_wide", name="V1Wide", track_key="v1", media_key="main",
                     timeline_start=500,  duration=2000, source_in=500,
                     fps_numerator=1000, fps_denominator=1},
        c_v2      = {id="c_v2",      name="V2",     track_key="v2", media_key="main",
                     timeline_start=1000, duration=1000, source_in=600,
                     fps_numerator=1000, fps_denominator=1},
    },
})

layout:init_timeline_state()
local db = database.get_connection()
assert(db:exec("UPDATE tracks SET sync_mode='cut'    WHERE id='trk_v1'"))
assert(db:exec("UPDATE tracks SET sync_mode='ripple' WHERE id='trk_v2'"))

local DELTA = -100   -- V2 IN dragged left 100 frames; V2 extends, ripple delta = -100

-- ── Step 1: dry_run preview. Must NOT mutate the DB.
-- (Drag fires dry_run on every pixel — if dry_run mutates, V1 ends up
-- pre-split with an orphaned right-half UUID before the commit even runs.)
local Clip = require("models.clip")
local function count_v1_clips()
    local n = 0
    for _, c in ipairs(Clip.list_in_sequence(layout.sequence_id) or {}) do
        if c.track_id == "trk_v1" then n = n + 1 end
    end
    return n
end
local pre_count = count_v1_clips()
assert(pre_count == 1, "fixture should start with 1 clip on V1, got " .. pre_count)

-- Match production: the UI invokes the executor directly for dry-run so
-- the command doesn't persist as an undo entry. Going through
-- command_manager.execute would record a separate top-level command in
-- history that interferes with subsequent undo.
local Command = require("command")
local dry_cmd = Command.create("BatchRippleEdit", layout.project_id)
dry_cmd:set_parameter("sequence_id",  layout.sequence_id)
dry_cmd:set_parameter("edge_infos",   {{clip_id="c_v2", edge_type="in", trim_type="ripple", track_id="trk_v2"}})
dry_cmd:set_parameter("delta_frames", DELTA)
dry_cmd:set_parameter("dry_run",      true)
local dry_exec = command_manager.get_executor("BatchRippleEdit")
local dry_ok = dry_exec(dry_cmd)
assert(dry_ok, "dry_run BatchRippleEdit failed")
local mid_count = count_v1_clips()
assert(mid_count == 1, string.format(
    "FAIL: dry_run mutated DB — V1 clip count went from %d to %d. "
    .. "dry_run must never write to disk; the cut branch's nested SplitClip "
    .. "must be virtualized in dry-run mode.", pre_count, mid_count))
print(string.format("  dry_run did not mutate DB: V1 still has %d clip(s)", mid_count))

-- ── Step 2: commit. Now the split should actually happen.
local r = command_manager.execute("RippleTrimEdge", {
    sequence_id  = layout.sequence_id,
    clip_id      = "c_v2",
    edge         = "left",
    delta_frames = DELTA,
    project_id   = layout.project_id,
})
assert(r and r.success, "RippleTrimEdge failed: " .. tostring(r and r.error_message))

-- ── V1 left half: was clip "c_v1_wide". After cut at 1000:
--     timeline_start=500, duration=500 (covers [500, 1000)).
local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id='c_v1_wide'")
assert(stmt); stmt:exec(); stmt:next()
local left_ts, left_dur = stmt:value(0), stmt:value(1); stmt:finalize()
assert(left_ts == 500, string.format(
    "FAIL: V1 left half timeline_start=%s, expected 500 (clip disappeared or shifted)",
    tostring(left_ts)))
assert(left_dur == 500, string.format(
    "FAIL: V1 left half duration=%s, expected 500", tostring(left_dur)))
print(string.format("  V1 left half OK: ts=%d dur=%d", left_ts, left_dur))

-- ── V1 right half: extend-direction ripple. Trim_point=1000 is the cut.
-- V2 IN extended by -100; the ripple bulk-shifts content downstream of
-- the cut by +100 (the IN-edge propagation). The right half rides with
-- the ripple — its source range stays the same (source_in=1000), only
-- its timeline_start moves to 1000 + 100 = 1100. A 100-frame gap forms
-- on V1 between left half (ends at 1000) and right half (starts 1100).
local stmt2 = db:prepare(
    "SELECT id, timeline_start_frame, duration_frames FROM clips "
    .. "WHERE track_id='trk_v1' AND id != 'c_v1_wide'")
assert(stmt2); stmt2:exec(); stmt2:next()
local right_id, right_ts, right_dur = stmt2:value(0), stmt2:value(1), stmt2:value(2); stmt2:finalize()
assert(right_id, "FAIL: V1 right half not found")
assert(right_ts == 1100, string.format(
    "FAIL: V1 right half ts=%s, expected 1100 (cut+ripple extends → right rides +100)",
    tostring(right_ts)))
assert(right_dur == 1500, string.format(
    "FAIL: V1 right half duration=%s, expected 1500", tostring(right_dur)))
print(string.format("  V1 right half OK: id=%s ts=%d dur=%d", right_id, right_ts, right_dur))

-- (V2 itself moves as a side effect of the bulk shift on V2's track;
-- exercising that is a separate concern from the cut bug this test owns.)

-- ── In-memory clip_state must carry resolved_media on the right half.
-- The renderer reaches for clip.resolved_media.id when fetching audio
-- peaks; if it's nil the right half renders without a waveform. Both
-- halves share the same media chain — the right-half mutation must
-- hydrate it from the source clip.
local timeline_state = require("ui.timeline.timeline_state")
local right_in_state
for _, c in ipairs(timeline_state.get_track_clip_index("trk_v1") or {}) do
    if c.id == right_id then right_in_state = c; break end
end
assert(right_in_state, "FAIL: V1 right half missing from clip_state")
assert(right_in_state.resolved_media and right_in_state.resolved_media.id,
    "FAIL: V1 right half has no resolved_media in clip_state — renderer "
    .. "can't fetch peaks → waveform blank")

-- ── Step 3: undo. The nested SplitClip under this command's group must
-- be reversed: right half deleted, original clip restored to full bounds.
local undo_r = command_manager.undo()
assert(undo_r and undo_r.success, "undo failed: " .. tostring(undo_r and undo_r.error_message))

local function count_v1()
    local n = 0
    for _, c in ipairs(Clip.list_in_sequence(layout.sequence_id) or {}) do
        if c.track_id == "trk_v1" then n = n + 1 end
    end
    return n
end
local post_undo = count_v1()
assert(post_undo == 1, string.format(
    "FAIL: after undo V1 has %d clips, expected 1 (the nested SplitClip "
    .. "was not reversed — right half lingers)", post_undo))

local stmt4 = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id='c_v1_wide'")
assert(stmt4); stmt4:exec(); stmt4:next()
local rts, rdur = stmt4:value(0), stmt4:value(1); stmt4:finalize()
assert(rts == 500 and rdur == 2000, string.format(
    "FAIL: after undo V1 original is ts=%s dur=%s, expected ts=500 dur=2000",
    tostring(rts), tostring(rdur)))
print(string.format("  undo restored V1: ts=%d dur=%d", rts, rdur))

print("\n✅ test_cut_mode_left_half_persists.lua passed")
