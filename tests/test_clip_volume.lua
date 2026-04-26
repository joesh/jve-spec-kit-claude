#!/usr/bin/env luajit

-- Per-clip volume: persistence, round-trip, snapshot round-trip.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local database = require("core.database")
local Clip = require("models.clip")

local DB_PATH = "/tmp/jve/test_clip_volume.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(require("import_schema")))

-- Seed project, media, sequence, track
assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('proj', 'Project', 'resample', 0, 0, '{}');

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'seq', 'proj', 'Sequence', 'nested',
        24, 1, 48000,
        1920, 1080,
        0, 240, 0,
        '[]', '[]', '[]',
        0, 0, 0
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]]))

require("test_env").create_test_media({
    id = "media1",
    project_id = "proj",
    name = "TestMedia",
    file_path = "/tmp/test.mov",
    duration_frames = 1000000,
    fps_numerator = 48000,
    fps_denominator = 1,
    audio_channels = 2,
    codec = "pcm_s16le",
    audio_sample_rate = 48000,
})

-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media1")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media1", "proj")

-- =========================================================================
-- Test 1: Create clip with non-unity volume, save, reload, verify
-- =========================================================================
local clip1_id = Clip.create({
        nested_sequence_id = MC_TEST,
        name = "Quiet Clip",
        project_id = "proj",
        owner_sequence_id = "seq",
        track_id = "a1",
        timeline_start_frame = 48000,
        duration_frames = 120000 - 0,
        source_in_frame = 0,
        source_out_frame = 120000,
        volume = 0.501187,
        fps_mismatch_policy = "resample",
        playhead_frame = 0,
        enabled = 1,
    })
local clip1 = Clip.load(clip1_id)
assert(clip1.volume == 0.501187, "create: volume should be 0.501187, got " .. tostring(clip1.volume))

local loaded1 = Clip.load(clip1.id)
assert(loaded1, "reload: clip should exist")
assert(math.abs(loaded1.volume - 0.501187) < 0.0001,
    string.format("reload: volume should be ~0.501187, got %s", tostring(loaded1.volume)))
print("  ✓ Clip volume persists through save/reload (0.501187 ≈ -6dB)")

-- =========================================================================
-- Test 2: Default volume is 1.0 (unity gain)
-- =========================================================================
local clip2_id = Clip.create({
        nested_sequence_id = MC_TEST,
        name = "Unity Clip",
        project_id = "proj",
        owner_sequence_id = "seq",
        track_id = "a1",
        timeline_start_frame = 144000,
        duration_frames = 24000,
        source_in_frame = 0,
        source_out_frame = 24000,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
local clip2 = Clip.load(clip2_id)
assert(clip2.volume == 1.0, "default: volume should be 1.0, got " .. tostring(clip2.volume))
local loaded2 = Clip.load(clip2.id)
assert(loaded2.volume == 1.0, "default reload: volume should be 1.0, got " .. tostring(loaded2.volume))
print("  ✓ Default volume is 1.0 (unity gain)")

-- =========================================================================
-- Test 3: Volume survives UPDATE (modify and re-save)
-- =========================================================================
loaded1.volume = 0.251189  -- -12dB
loaded1:save(db)
local reloaded = Clip.load(loaded1.id)
assert(math.abs(reloaded.volume - 0.251189) < 0.0001,
    string.format("update: volume should be ~0.251189, got %s", tostring(reloaded.volume)))
print("  ✓ Volume survives UPDATE")

-- =========================================================================
-- Test 4: Volume round-trips through snapshot
-- =========================================================================
local snapshot_manager = require("core.snapshot_manager")

-- Create a clip with interesting volume
local clip3_id = Clip.create({
        nested_sequence_id = MC_TEST,
        name = "Snapshot Clip",
        project_id = "proj",
        owner_sequence_id = "seq",
        track_id = "a1",
        timeline_start_frame = 240000,
        duration_frames = 24000,
        source_in_frame = 48000,
        source_out_frame = 72000,
        volume = 0.707946,
        fps_mismatch_policy = "resample",
        playhead_frame = 0,
        enabled = 1,
    })
local clip3 = Clip.load(clip3_id)

-- Take snapshot (API: create_snapshot(db, seq_id, seq_number, clips))
snapshot_manager.create_snapshot(db, "seq", 1, {clip1, clip2, clip3})

-- Modify volume (simulate a command changing it)
clip3.volume = 0.1
clip3:save(db)
-- Restore snapshot (API: load_snapshot(db, seq_id))
local snap_state = snapshot_manager.load_snapshot(db, "seq")
assert(snap_state, "snapshot should exist")
assert(snap_state.clips and #snap_state.clips > 0, "snapshot should have clips")

-- Find our clip in the snapshot
local found = false
for _, snap_clip in ipairs(snap_state.clips) do
    if snap_clip.id == clip3.id then
        assert(math.abs(snap_clip.volume - 0.707946) < 0.0001,
            string.format("snapshot: volume should be ~0.707946, got %s", tostring(snap_clip.volume)))
        found = true
        break
    end
end
assert(found, "snapshot should contain clip3")
print("  ✓ Volume round-trips through snapshot")

-- =========================================================================
-- Test 5: Volume validation (negative volume asserts)
-- =========================================================================
local ok, err = pcall(function()
    local bad = Clip.create({
        nested_sequence_id = MC_TEST,
        name = "Bad Clip",
        project_id = "proj",
        owner_sequence_id = "seq",
        track_id = "a1",
        timeline_start_frame = 360000,
        duration_frames = 24000,
        source_in_frame = 0,
        source_out_frame = 24000,
        volume = -0.5,
        fps_mismatch_policy = "resample",
        playhead_frame = 0,
        enabled = 1,
    })
    bad:save()
end)
assert(not ok, "negative volume should fail")
assert(err:find("volume"), "error should mention volume, got: " .. tostring(err))
print("  ✓ Negative volume fails validation")

-- =========================================================================
-- Test 6: Volume = 0.0 (silence) persists and round-trips
-- =========================================================================
local clip_silent_id = Clip.create({
        nested_sequence_id = MC_TEST,
        name = "Silent Clip",
        project_id = "proj",
        owner_sequence_id = "seq",
        track_id = "a1",
        timeline_start_frame = 480000,
        duration_frames = 24000,
        source_in_frame = 0,
        source_out_frame = 24000,
        volume = 0.0,
        fps_mismatch_policy = "resample",
        playhead_frame = 0,
        enabled = 1,
    })
local clip_silent = Clip.load(clip_silent_id)
assert(clip_silent.volume == 0.0, "create: volume should be 0.0, got " .. tostring(clip_silent.volume))
local loaded_silent = Clip.load(clip_silent_id)
assert(loaded_silent.volume == 0.0,
    string.format("reload: volume should be 0.0, got %s", tostring(loaded_silent.volume)))
print("  ✓ Volume = 0.0 (silence) persists through save/reload")

print("✅ test_clip_volume.lua passed")
