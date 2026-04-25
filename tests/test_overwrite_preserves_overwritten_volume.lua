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

-- Timeline sequence
local seq = Sequence.create("Timeline", "proj1",
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {id = "seq1", audio_rate = 48000})
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
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        media_id, master_clip_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('mc_clip', 'proj1', 'master', 'Source', 'mc_v1', 'mc_seq',
        'media1', 'mc_seq',
        0, 10000, 0, 10000, 1, 0, 24, 1, %d, %d);
]], now, now))

-- Existing timeline clip with volume=0.3 (quiet clip that will be partially overwritten)
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        media_id, master_clip_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator,
        volume,
        created_at, modified_at)
    VALUES ('existing', 'proj1', 'clip', 'Quiet', 'v1', 'seq1',
        'media1', 'mc_seq',
        0, 200, 0, 200, 1, 0, 24, 1,
        0.3,
        %d, %d);
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
    master_clip_id = "mc_seq",
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
