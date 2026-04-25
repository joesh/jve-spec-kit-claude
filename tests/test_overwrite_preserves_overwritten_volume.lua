-- Regression: Overwrite that trims/deletes an existing clip with non-default
-- volume must preserve that volume through undo. Tests the full chain:
-- resolve_occlusions → plan_delete (previous state) → apply_mutations →
-- revert_mutations (undo) → restore_deleted_clip.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Sequence = require("models.sequence")

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

print("\n=== Overwrite Preserves Overwritten Clip Volume ===")

-- Setup
local db_path = "/tmp/jve/test_overwrite_volume.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

    -- V13 placeholder master sequence (test references nested_sequence_id='mc_seq' literally)
    db:exec(string.format([[INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('mc_seq_media', 'proj1', 'placeholder', '_placeholder', 10000, 30, 1, 1920, 1080, 0, 'raw', 0, 0)]]))
    db:exec(string.format([[INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('mc_seq', 'proj1', 'mc_seq', 'master', 30, 1, 48000, 1920, 1080, 0, 0)]]))
    db:exec(string.format([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('mc_seq_v1', 'mc_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)]]))
    db:exec(string.format([[UPDATE sequences SET default_video_layer_track_id = 'mc_seq_v1' WHERE id = 'mc_seq']]))
    db:exec(string.format([[INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mc_seq_mr', 'proj1', 'mc_seq', 'mc_seq_v1', 'mc_seq_media', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0)]]))

-- Timeline sequence
local seq = Sequence.create("Timeline", "proj1",
    { fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    { kind = "nested",id = "seq1", audio_rate = 48000})
assert(seq:save(), "setup: save sequence")

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Source media + masterclip
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

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, master_clip_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('mc_clip', 'proj1', 'Source', 'mc_v1', 'master_media1', 'mc_seq', 'mc_seq', 0, 10000, 0, 10000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

-- Existing timeline clip with volume=0.3 (quiet clip that will be partially overwritten)
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, master_clip_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, volume, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, playhead_frame)
VALUES
    ('existing', 'proj1', 'Quiet', 'v1', 'master_media1', 'seq1', 'mc_seq', 0, 200, 0, 200, 1, 1.0, %d, %d, NULL, NULL, 'resample', 0);
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
    if q:exec() and q:next() then val = q:value(0) end
    q:finalize()
    return val
end

-- Pre-conditions
print("\n--- Pre-overwrite ---")
check("existing clip volume=0.3", math.abs(get_clip_field("existing", "volume") - 0.3) < 0.001)
check("existing clip dur=200", get_clip_field("existing", "duration_frames") == 200)

-- Overwrite: place a 50-frame clip at position 50 (partially overwrites 'existing')
print("\n--- Overwrite ---")
execute_cmd("Overwrite", {
    sequence_id = "seq1",
    nested_sequence_id = "mc_seq",
    source_in = 0,
    source_out = 50,
    playhead = 50,
})

-- The existing clip should be split/trimmed around the overwrite
-- Check that whatever remains of 'existing' still has volume 0.3
local existing_vol = get_clip_field("existing", "volume")
if existing_vol then
    check("existing clip retains volume after overwrite", math.abs(existing_vol - 0.3) < 0.001)
end

-- Undo
print("\n--- Undo overwrite ---")
undo()

-- After undo, existing clip should be fully restored with original volume
check("undo: existing clip exists", get_clip_field("existing", "id") == "existing")
check("undo: volume=0.3", math.abs((get_clip_field("existing", "volume") or 0) - 0.3) < 0.001)
check("undo: duration=200", get_clip_field("existing", "duration_frames") == 200)
check("undo: timeline_start=0", get_clip_field("existing", "timeline_start_frame") == 0)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_overwrite_preserves_overwritten_volume.lua passed")
