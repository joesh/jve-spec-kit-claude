#!/usr/bin/env luajit
--- Test: relink operates on all media (not just offline)
--
-- Verifies:
-- 1. find_project_media returns ALL non-proxy media (online + offline)
-- 2. find_media_for_clips returns media for specific clip IDs
-- 3. find_offline_media still filters to offline-only (predicate)
require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_all_media.lua ===")

local database = require("core.database")
local uuid = require("uuid")
local json = require("dkjson")
local Media = require("models.media")
local media_relinker = require("core.media_relinker")

local TEST_DB = "/tmp/jve/test_relink_all_media.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-all-media"
local seq_id = uuid.generate()
local v1_track = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'All Media Project', 'resample', %d, %d, '{}');

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Main', 'sequence', 25, 1, 48000, 1920, 1080, 0, 500, 0, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], project_id, now, now, seq_id, project_id, now, now, v1_track, seq_id))

---------------------------------------------------------------------------------
-- Create ONLINE media (file exists on disk)
---------------------------------------------------------------------------------
local online_dir = "/tmp/jve/relink_all_test"
os.execute(string.format("mkdir -p %q", online_dir))
local online_file = online_dir .. "/online_clip.mov"
local f = io.open(online_file, "w")
assert(f, "failed to create test file")
f:write("dummy online media")
f:close()

local online_media = Media.create({
    id = uuid.generate(),
    project_id = project_id,
    file_path = online_file,
    name = "online_clip.mov",
    duration_frames = 500,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
    metadata = json.encode({start_tc_value = 90000, start_tc_rate = 25}),
})
online_media:save(db)
---------------------------------------------------------------------------------
-- Create OFFLINE media (file does NOT exist)
---------------------------------------------------------------------------------
local offline_media = Media.create({
    id = uuid.generate(),
    project_id = project_id,
    file_path = "/nonexistent/path/offline_clip.mov",
    name = "offline_clip.mov",
    duration_frames = 300,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
    metadata = json.encode({start_tc_value = 45000, start_tc_rate = 25}),
})
offline_media:save(db)
---------------------------------------------------------------------------------
-- Create PROXY media (should always be excluded)
---------------------------------------------------------------------------------
local proxy_media = Media.create({
    id = uuid.generate(),
    project_id = project_id,
    file_path = "/nonexistent/ProxyMedia/proxy_clip.mov",
    name = "proxy_clip.mov",
    duration_frames = 500,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 960,
    height = 540,
    audio_channels = 0,
    metadata = json.encode({start_tc_value = 0, start_tc_rate = 25}),
})
proxy_media:save(db)
---------------------------------------------------------------------------------
-- Create clips on the timeline
---------------------------------------------------------------------------------
local online_clip_id = uuid.generate()
local offline_clip_id = uuid.generate()
local offline_clip_2_id = uuid.generate()

-- V13: master sequences for the two media files (proxy excluded — clips
-- never reference it, so it doesn't need a master).
local _Sequence = require("models.sequence")
local online_master = _Sequence.ensure_master(online_media.id, project_id)
local offline_master = _Sequence.ensure_master(offline_media.id, project_id)

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('%s', '%s', 'Online-Shot', '%s', '%s', '%s',
        0, 100, 100, 200, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);

    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('%s', '%s', 'Offline-Shot1', '%s', '%s', '%s',
        100, 80, 50, 130, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);

    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('%s', '%s', 'Offline-Shot2', '%s', '%s', '%s',
        180, 60, 200, 260, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);
]], online_clip_id, project_id, v1_track, online_master, seq_id, now, now,
    offline_clip_id, project_id, v1_track, offline_master, seq_id, now, now,
    offline_clip_2_id, project_id, v1_track, offline_master, seq_id, now, now))

---------------------------------------------------------------------------------
-- Test 1: find_project_media returns ALL non-proxy media
---------------------------------------------------------------------------------
print("\n--- Test 1: find_project_media returns online + offline ---")
do
    local all_media = media_relinker.find_project_media(db, project_id)
    assert(#all_media == 2,
        string.format("expected 2 media (online+offline), got %d", #all_media))

    local found_online = false
    local found_offline = false
    for _, m in ipairs(all_media) do
        if m.id == online_media.id then found_online = true end
        if m.id == offline_media.id then found_offline = true end
        -- proxy must NOT appear
        assert(m.id ~= proxy_media.id, "proxy media must be excluded")
    end
    assert(found_online, "online media must be included")
    assert(found_offline, "offline media must be included")
    print("  ✓ both online and offline media returned")
    print("  ✓ proxy media excluded")
end

---------------------------------------------------------------------------------
-- Test 2: find_media_for_clips returns media for specific clip IDs
---------------------------------------------------------------------------------
print("\n--- Test 2: find_media_for_clips for selected clips ---")
do
    -- Select only the online clip
    local media_for_one = media_relinker.find_media_for_clips(db, {online_clip_id})
    assert(#media_for_one == 1,
        string.format("expected 1 media for 1 clip, got %d", #media_for_one))
    assert(media_for_one[1].id == online_media.id, "should be the online media")
    print("  ✓ single clip → correct media")

    -- Select both offline clips (same media) — should deduplicate
    local media_for_two = media_relinker.find_media_for_clips(db, {offline_clip_id, offline_clip_2_id})
    assert(#media_for_two == 1,
        string.format("expected 1 unique media for 2 clips sharing same media, got %d", #media_for_two))
    assert(media_for_two[1].id == offline_media.id, "should be the offline media")
    print("  ✓ two clips sharing media → deduplicated to 1 media")

    -- Select all three clips
    local media_for_all = media_relinker.find_media_for_clips(db,
        {online_clip_id, offline_clip_id, offline_clip_2_id})
    assert(#media_for_all == 2,
        string.format("expected 2 unique media for 3 clips, got %d", #media_for_all))
    print("  ✓ three clips → 2 unique media")
end

---------------------------------------------------------------------------------
-- Test 3: find_offline_media still works as predicate (only offline)
---------------------------------------------------------------------------------
print("\n--- Test 3: find_offline_media returns only offline ---")
do
    local offline_only = media_relinker.find_offline_media(db, project_id)
    assert(#offline_only == 1,
        string.format("expected 1 offline media, got %d", #offline_only))
    assert(offline_only[1].id == offline_media.id, "should be the offline media")
    print("  ✓ find_offline_media returns only offline (predicate works)")
end

---------------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------------
os.remove(online_file)
os.execute(string.format("rm -rf %q", online_dir))

print("\n✅ test_relink_all_media.lua passed")
