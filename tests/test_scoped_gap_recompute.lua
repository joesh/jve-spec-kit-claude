#!/usr/bin/env luajit

-- Scoped gap recomputation regression guard (feature 008, T011).
--
-- Domain behavior: after a mutation that affects one track, only that
-- track's gaps should be recomputed. Other tracks' gap clip IDs and
-- positions must be byte-identical before and after.
--
-- Operates at the timeline_state level: sets up clips on two tracks,
-- calls recompute_gap_clips({[track_id]=true}) with a single-track
-- scope, and verifies the untouched track's gap list is unchanged.

require("test_env")

local database = require("core.database")
local timeline_core_state = require("ui.timeline.state.timeline_core_state")
local data = require("ui.timeline.state.timeline_state_data")
-- Setup: create a DB with 2 tracks, clips on each
local db_path = "/tmp/jve/test_scoped_gap_recompute.db"
os.remove(db_path)
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Create project + sequence (minimum required columns)
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj1', 'test', 'resample', %d, %d)",
    now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate, width, height,
        created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq 1', 'nested', 25, 1, 48000, 1920, 1080, %d, %d)
]], now, now))

-- Create tracks
db:exec("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1)")
db:exec("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_a1', 'seq1', 'A1', 'AUDIO', 2, 1)")

-- Create clips: V1 has clips at 0-100 and 200-400 (gap 100-200). A1 has clip at 0-300 and 400-500 (gap 300-400).
local function insert_clip(id, track_id, start, dur)
    db:exec(string.format(
        "INSERT INTO clips (id, project_id, clip_kind, track_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, created_at, modified_at) " ..
        "VALUES ('%s', 'proj1', 'timeline', '%s', %d, %d, 0, %d, 25, 1, 1, %d, %d)",
        id, track_id, start, dur, dur, now, now))
end

insert_clip("clip_v1a", "track_v1", 0, 100)
insert_clip("clip_v1b", "track_v1", 200, 200)
insert_clip("clip_a1a", "track_a1", 0, 300)
insert_clip("clip_a1b", "track_a1", 400, 100)

-- Initialize timeline_state
local command_manager = require("core.command_manager")
command_manager.init("seq1", "proj1")
timeline_core_state.init("seq1", "proj1")

-- Collect current gap IDs on each track
local function get_gap_ids_for_track(track_id)
    local ids = {}
    for _, clip in ipairs(data.state.clips) do
        if clip.track_id == track_id and clip.clip_kind == "gap" then
            table.insert(ids, clip.id)
        end
    end
    table.sort(ids)
    return ids
end

local v1_gaps_before = get_gap_ids_for_track("track_v1")
local a1_gaps_before = get_gap_ids_for_track("track_a1")

assert(#v1_gaps_before > 0, "V1 should have gaps after init")
assert(#a1_gaps_before > 0, "A1 should have gaps after init")

-- Scoped recompute: pass affected_track_ids naming V1 only. The
-- contract (T011) is that A1's gap clip IDs stay byte-identical
-- because its track is not in the affected set.
local affected = { ["track_v1"] = true }
timeline_core_state.recompute_gap_clips(affected)

-- V1 gaps should be recomputed (may have new IDs)
local v1_gaps_after = get_gap_ids_for_track("track_v1")
assert(#v1_gaps_after > 0, "V1 should still have gaps after scoped recompute")

-- A1 gaps should be UNCHANGED — same IDs
local a1_gaps_after = get_gap_ids_for_track("track_a1")
assert(#a1_gaps_after == #a1_gaps_before,
    string.format("A1 gap count changed: before=%d after=%d", #a1_gaps_before, #a1_gaps_after))

for i, id in ipairs(a1_gaps_before) do
    assert(a1_gaps_after[i] == id,
        string.format("A1 gap ID changed: before=%s after=%s", id, tostring(a1_gaps_after[i])))
end

database.shutdown()
os.remove(db_path)

print("✅ test_scoped_gap_recompute.lua passed")
