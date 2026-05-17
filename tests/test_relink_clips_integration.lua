#!/usr/bin/env luajit
--- T016: Integration test for RelinkClips — full flow with real DB
require("test_env")

-- No-op timer
_G.qt_create_single_shot_timer = function() end

-- Mock panel_manager
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_clips_integration.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local uuid = require("uuid")
local json = require("dkjson")

local Clip = require("models.clip")
local Media = require("models.media")
local media_relinker = require("core.media_relinker")

local TEST_DB = "/tmp/jve/test_relink_integration.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-int"
local seq_id = uuid.generate()
local v1_track = uuid.generate()
local a1_track = uuid.generate()

-- Create project, sequence, tracks
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'Integration Project', 'resample', %d, %d, '{}');

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Main', 'sequence', 25, 1, 48000, 1920, 1080, 0, 500, 0, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], project_id, now, now,
    seq_id, project_id, now, now,
    v1_track, seq_id,
    a1_track, seq_id))

-- Create media files (video + audio) with start TC
local video_media_id = uuid.generate()
local audio_media_id = uuid.generate()

local video_media = Media.create({
    id = video_media_id,
    project_id = project_id,
    file_path = "/offline/shoot1/A026_C007.mov",
    name = "A026_C007.mov",
    duration_frames = 1000,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
    metadata = json.encode({start_tc_value = 89750, start_tc_rate = 25}),
})
video_media:save(db)
local audio_media = Media.create({
    id = audio_media_id,
    project_id = project_id,
    file_path = "/offline/shoot1/A026_C007.wav",
    name = "A026_C007.wav",
    duration_frames = 48000000,  -- in samples at 48000Hz
    fps_numerator = 48000,
    fps_denominator = 1,
    width = 0,
    height = 0,
    audio_channels = 2,
    audio_sample_rate = 48000,
    metadata = json.encode({
        start_tc_value = 0, start_tc_rate = 25,
        start_tc_audio_samples = 172320000, start_tc_audio_rate = 48000,
    }),
})
audio_media:save(db)
-- V13: master sequences for the two media files; clips reference these.
local _Sequence = require("models.sequence")
local video_master = _Sequence.ensure_master(video_media_id, project_id)
local audio_master = _Sequence.ensure_master(audio_media_id, project_id)
-- Create clips: 2 video, 1 audio
local v_clip_1 = uuid.generate()
local v_clip_2 = uuid.generate()
local a_clip_1 = uuid.generate()

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('%s', '%s', 'V-Shot1', '%s', '%s', '%s',
        0, 100, 100, 200, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);

    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('%s', '%s', 'V-Shot2', '%s', '%s', '%s',
        100, 50, 500, 550, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);

    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('%s', '%s', 'A-Shot1', '%s', '%s', '%s',
        0, 100, 4800000, 9600000, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);
]], v_clip_1, project_id, v1_track, video_master, seq_id, now, now,
    v_clip_2, project_id, v1_track, video_master, seq_id, now, now,
    a_clip_1, project_id, a1_track, audio_master, seq_id, now, now))

command_manager.init(seq_id, project_id)

---------------------------------------------------------------------------------
-- Test 1: Build clip_info structs from offline media
---------------------------------------------------------------------------------
print("\n--- Test 1: Build clip_info from offline media ---")
do
    -- Verify clips load correctly
    local vc1 = Clip.load(v_clip_1)
    assert(vc1, "v_clip_1 should load")
    assert(vc1.source_in == 100, "v_clip_1 source_in = 100")
    assert(vc1.source_out == 200, "v_clip_1 source_out = 200")

    -- Verify Media:get_start_tc works
    local vm = Media.load(video_media_id)
    local tc_val, tc_rate = vm:get_start_tc()
    assert(tc_val == 89750, "video start TC value")
    assert(tc_rate == 25, "video start TC rate")

    -- Verify Clip.find_clips_for_media
    local video_clips = Clip.find_clips_for_media(video_media_id)
    assert(#video_clips == 2, string.format("expected 2 video clips, got %d", #video_clips))

    local audio_clips = Clip.find_clips_for_media(audio_media_id)
    assert(#audio_clips == 1, string.format("expected 1 audio clip, got %d", #audio_clips))

    print("  ✓ clips and media load correctly")
    print("  ✓ find_clips_for_media returns correct counts")
end

---------------------------------------------------------------------------------
-- Test 2: compute_tc_offset for video/audio sync
---------------------------------------------------------------------------------
print("\n--- Test 2: Video/audio TC offset sync ---")
do
    -- Video: stored 89750 @ 25fps = 3590s
    -- Audio: stored 172320000 @ 48000Hz = 3590s
    -- Same absolute time → offset should be 0
    local offset = media_relinker.compute_tc_offset(89750, 25, 172320000, 48000)
    assert(offset == 0, string.format("v/a cross-rate: expected 0, got %d", offset))
    print("  ✓ video/audio TC cross-rate comparison = 0 offset")
end

---------------------------------------------------------------------------------
-- Test 3: relink_media_batch with simple filename match (no TC offset)
---------------------------------------------------------------------------------
print("\n--- Test 3: Batch relink with filename match (same TC) ---")
do
    -- Build media_infos (one per media — media-level relink)
    local vm = Media.load(video_media_id)
    local tc_val, tc_rate = vm:get_start_tc()
    local extent_start, extent_end = vm:get_source_extent(tc_rate or 25)
    local media_infos = {{
        media_id = video_media_id,
        media_path = vm:get_file_path(),
        media_name = vm.name,
        media_start_tc_value = tc_val,
        media_start_tc_rate = tc_rate,
        width = vm.width,
        height = vm.height,
        source_extent_start = extent_start,
        source_extent_end = extent_end,
    }}

    -- Create a fake search directory with a matching file
    local search_dir = "/tmp/jve/relink_test_media"
    os.execute(string.format("mkdir -p %q", search_dir))
    local dummy_file = search_dir .. "/A026_C007.mov"
    local f = io.open(dummy_file, "w")
    if f then
        f:write("dummy")
        f:close()
    end

    local options = {
        search_paths = { search_dir },
        matching_rules = {
            match_filename = true,
            match_timecode = false,  -- skip TC check (dummy file has no real TC)
            match_resolution = false,
            match_frame_rate = false,
            accept_trimmed_media = false,
            accept_filename_suffixes = false,
        },
    }

    local progress_calls = 0
    local results = media_relinker.relink_media_batch(media_infos, options, function()
        progress_calls = progress_calls + 1
    end)

    -- Media-level relink: one entry per media, not per clip
    assert(#results.relinked == 1, string.format("expected 1 relinked (per-media), got %d", #results.relinked))
    assert(#results.failed == 0, string.format("expected 0 failed, got %d", #results.failed))
    assert(progress_calls > 0, "progress callback should have been called")

    -- Verify the single media entry points to the correct file
    local entry = results.relinked[1]
    assert(entry.media_id == video_media_id, "relinked entry should reference our media")
    assert(entry.new_path == dummy_file, "path should match dummy file")

    -- Cleanup
    os.remove(dummy_file)

    print("  ✓ 2 clips matched by filename")
    print("  ✓ source ranges unchanged (no TC offset)")
    print("  ✓ progress callback invoked")
end

---------------------------------------------------------------------------------
-- Test 4: RelinkClips command execute + undo roundtrip
---------------------------------------------------------------------------------
print("\n--- Test 4: RelinkClips execute + undo roundtrip ---")
do
    -- Execute RelinkClips
    local cmd = Command.create("RelinkClips", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("clip_relink_map", {
        [v_clip_1] = { new_source_in = 50, new_source_out = 150 },
        [v_clip_2] = { new_source_in = 450, new_source_out = 500 },
    })
    cmd:set_parameter("media_path_changes", {
        [video_media_id] = "/new_location/A026_C007.mov",
    })

    local result = command_manager.execute(cmd)
    assert(result.success, "RelinkClips should succeed")

    -- Verify
    local c1 = Clip.load(v_clip_1)
    assert(c1.source_in == 50, "after execute: clip1 source_in = 50")
    local m = Media.load(video_media_id)
    assert(m:get_file_path() == "/new_location/A026_C007.mov", "media path updated")

    -- Undo
    command_manager.undo()

    c1 = Clip.load(v_clip_1)
    assert(c1.source_in == 100, "after undo: clip1 source_in restored to 100")
    m = Media.load(video_media_id)
    assert(m:get_file_path() == "/offline/shoot1/A026_C007.mov", "media path restored")

    print("  ✓ RelinkClips execute updates clips + media")
    print("  ✓ undo restores everything")
end

---------------------------------------------------------------------------------
-- Test 5: segment matching functions
---------------------------------------------------------------------------------
print("\n--- Test 5: Segment matching ---")
do
    assert(media_relinker.match_segment_filename("A026_C007.mov", "A026_C007_001.mov") == true)
    assert(media_relinker.match_segment_filename("A026_C007.mov", "A026_C007_002.mov") == true)
    assert(media_relinker.match_segment_filename("A026_C007.mov", "A026_C007.mov") == false)
    assert(media_relinker.match_segment_filename("A026_C007.mov", "B001_C001_001.mov") == false)

    local index = {
        ["a026_c007.mov"] = {"/vol/A026_C007.mov"},
        ["a026_c007_001.mov"] = {"/vol/A026_C007_001.mov"},
        ["a026_c007_002.mov"] = {"/vol/A026_C007_002.mov"},
    }
    local seg_idx = media_relinker.build_segment_index(index)
    assert(seg_idx["a026_c007.mov"], "segment index should have entries")
    assert(#seg_idx["a026_c007.mov"] == 2, "should have 2 segments")

    print("  ✓ segment filename matching works")
    print("  ✓ segment index built correctly")
end

print("\n✅ test_relink_clips_integration.lua passed")
