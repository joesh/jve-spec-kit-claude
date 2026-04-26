-- Test: Clip:delete() cleans up properties and clip_links.
-- Verifies the systemic fix — no orphaned rows left after clip deletion.

require("test_env")

local database = require("core.database")
local Clip = require("models.clip")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== Clip:delete() Orphan Cleanup Tests ===")

-- Setup
local db_path = "/tmp/jve/test_clip_delete_orphans.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'nested', 24, 1, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq1', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Create two linked clips with properties
db:exec(string.format([[
    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj1', 'placeholder', '_placeholder', 100, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj1', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 100, 0, 100, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, volume, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, playhead_frame) VALUES
    ('vid1', 'proj1', 'Video', 'v1', '_v13_placeholder_master', 'seq1', 0, 100, 0, 100, 1, 1.0, %d, %d, NULL, NULL, 'resample', 0),
    ('aud1', 'proj1', 'Audio', 'a1', '_v13_placeholder_master', 'seq1', 0, 100, 0, 100, 1, 1.0, %d, %d, NULL, NULL, 'resample', 0);
]], now, now, now, now))

-- Add link group
db:exec([[
    INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
    VALUES ('lg1', 'vid1', 'video', 0, 1);
    INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
    VALUES ('lg1', 'aud1', 'audio', 0, 1);
]])

-- Add properties
db:exec([[
    INSERT INTO properties (id, clip_id, property_name, property_value, property_type)
    VALUES ('p1', 'vid1', 'color_correction', '{"brightness":1.2}', 'json');
    INSERT INTO properties (id, clip_id, property_name, property_value, property_type)
    VALUES ('p2', 'aud1', 'eq_preset', '{"bass":3}', 'json');
]])

-- Helper: count rows
local function count_rows(table_name, where_clause)
    local sql = "SELECT COUNT(*) FROM " .. table_name
    if where_clause then sql = sql .. " WHERE " .. where_clause end
    local stmt = db:prepare(sql)
    local count = 0
    if stmt:exec() and stmt:next() then count = stmt:value(0) end
    stmt:finalize()
    return count
end

-- Pre-delete state
print("\n--- Pre-delete ---")
check("2 clips", count_rows("clips", "track_id IN ('v1','a1')") == 2)
check("2 link rows", count_rows("clip_links", "link_group_id = 'lg1'") == 2)
check("2 property rows", count_rows("properties", "clip_id IN ('vid1','aud1')") == 2)

-- Delete video clip via Clip:delete()
print("\n--- Delete vid1 ---")
local clip = Clip.load("vid1")
check("clip loaded", clip ~= nil)
assert(clip:delete(), "delete failed")

check("vid1 deleted", count_rows("clips", "id = 'vid1'") == 0)
check("vid1 link cleaned", count_rows("clip_links", "clip_id = 'vid1'") == 0)
check("vid1 property cleaned", count_rows("properties", "clip_id = 'vid1'") == 0)
-- aud1's link row should still exist (it belongs to aud1, not vid1)
check("aud1 link preserved", count_rows("clip_links", "clip_id = 'aud1'") == 1)
check("aud1 property preserved", count_rows("properties", "clip_id = 'aud1'") == 1)

-- Delete audio clip
print("\n--- Delete aud1 ---")
local clip2 = Clip.load("aud1")
assert(clip2:delete(), "delete failed")

check("aud1 deleted", count_rows("clips", "id = 'aud1'") == 0)
check("aud1 link cleaned", count_rows("clip_links", "clip_id = 'aud1'") == 0)
check("aud1 property cleaned", count_rows("properties", "clip_id = 'aud1'") == 0)
check("all links gone", count_rows("clip_links", "link_group_id = 'lg1'") == 0)
check("all props gone", count_rows("properties", "clip_id IN ('vid1','aud1')") == 0)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_clip_delete_cleans_orphans.lua passed")
