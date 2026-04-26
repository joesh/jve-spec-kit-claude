-- Regression: SplitClip must preserve volume on both halves.
-- Bug: second_clip created without volume — gets default 1.0 instead of original.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")

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

print("\n=== SplitClip Preserves Metadata Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_split_metadata.db"
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
        0, 1000, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Media + masterclip for split (Clip.create needs media_id for master_clip resolution)
db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels, codec,
        created_at, modified_at)
    VALUES ('media1', 'proj1', 'Source', '/tmp/test.mov', 10000, 24, 1, 1920, 1080, 0, 'h264', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('mc_seq', 'proj1', 'MC', 'masterclip', 24, 1, 48000, 1920, 1080,
        0, 10000, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('mc_v1', 'mc_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec(string.format([[
    -- V13 master sequence + track + media_ref for media1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('master_media1', 'proj1', 'media1_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media1', 'master_media1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media1' WHERE id = 'master_media1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media1', 'proj1', 'master_media1', 'master_v_media1', 'media1', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    
    ('mc_clip', 'proj1', 'Source', 'mc_v1', 'master_media1', 'mc_seq', 0, 10000, 0, 10000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

-- Timeline clip with non-default volume, linked to masterclip
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, volume, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, playhead_frame)
VALUES
    
    ('clip1', 'proj1', 'Gained', 'v1', 'master_media1', 'seq1', 100, 200, 5000, 5200, 1, 1.0, %d, %d, NULL, NULL, 'resample', 0);
]], now, now))

command_manager.init("seq1", "proj1")

local function execute_cmd(name, params)
    params = params or {}
    params.project_id = params.project_id or "proj1"
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

local function undo()
    command_manager.begin_command_event("script")
    local result = command_manager.undo()
    command_manager.end_command_event()
    return result
end

local function get_clip_field(clip_id, field)
    local q = db:prepare("SELECT " .. field .. " FROM clips WHERE id = ?")
    q:bind_value(1, clip_id)
    local val = nil
    if q:exec() and q:next() then
        val = q:value(0)
    end
    q:finalize()
    return val
end

-- Verify pre-conditions
print("\n--- Pre-split ---")
check("clip1 volume=0.42", math.abs(get_clip_field("clip1", "volume") - 0.42) < 0.001)

-- Split at frame 200 (midpoint of 100-frame clip at position 100)
print("\n--- Split ---")
local r = execute_cmd("SplitClip", {
    clip_id = "clip1",
    split_frame = 200,
    sequence_id = "seq1",
})
check("split succeeds", r == true or (type(r) == "table" and r.success))

-- Find the second clip (new clip created by split)
local second_clip_id = nil
local stmt = db:prepare("SELECT id FROM clips WHERE track_id = 'v1' AND timeline_start_frame = 200")
if stmt:exec() and stmt:next() then
    second_clip_id = stmt:value(0)
end
stmt:finalize()
check("second clip created", second_clip_id ~= nil)

-- First half should keep original volume
print("\n--- Post-split volumes ---")
local first_vol = get_clip_field("clip1", "volume")
check("first half volume=0.42", first_vol and math.abs(first_vol - 0.42) < 0.001)

-- Second half MUST have same volume (bug: was getting default 1.0)
if second_clip_id then
    local second_vol = get_clip_field(second_clip_id, "volume")
    check("second half volume=0.42", second_vol and math.abs(second_vol - 0.42) < 0.001)
end

-- Undo should restore original clip exactly
print("\n--- Undo split ---")
undo()
local restored_vol = get_clip_field("clip1", "volume")
check("undo: volume=0.42", restored_vol and math.abs(restored_vol - 0.42) < 0.001)

-- Second clip should be gone
local gone = get_clip_field(second_clip_id, "id")
check("undo: second clip deleted", gone == nil)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_split_preserves_clip_metadata.lua passed")
