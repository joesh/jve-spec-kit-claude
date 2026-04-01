-- Regression: delete_clip undo must preserve volume, marks, playhead.
-- capture_clip_state was missing these fields — clips would lose metadata on undo.

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

print("\n=== DeleteClip Undo Metadata Preservation Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_delete_clip_metadata.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24, 1, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Clip with non-default metadata
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        enabled, offline, fps_numerator, fps_denominator,
        volume, mark_in_frame, mark_out_frame, playhead_frame,
        created_at, modified_at)
    VALUES ('clip1', 'proj1', 'clip', 'TestClip', 'v1', 'seq1',
        100, 200, 5000, 5200,
        1, 0, 24, 1,
        0.42, 30, 170, 85,
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
    if q:exec() and q:next() then
        val = q:value(0)
    end
    q:finalize()
    return val
end

-- Verify pre-conditions
print("\n--- Pre-delete state ---")
check("clip exists", get_clip_field("clip1", "id") == "clip1")
check("pre volume=0.42", math.abs(get_clip_field("clip1", "volume") - 0.42) < 0.001)
check("pre mark_in=30", get_clip_field("clip1", "mark_in_frame") == 30)
check("pre mark_out=170", get_clip_field("clip1", "mark_out_frame") == 170)
check("pre playhead=85", get_clip_field("clip1", "playhead_frame") == 85)

-- Delete
print("\n--- Delete clip ---")
local r = execute_cmd("DeleteClip", {clip_id = "clip1", sequence_id = "seq1"})
check("delete succeeds", r and (r.success or r == true))
check("clip deleted", get_clip_field("clip1", "id") == nil)

-- Undo
print("\n--- Undo delete ---")
r = undo()
check("undo succeeds", r and (r.success or r == true))

-- Verify metadata preserved
print("\n--- Post-undo metadata ---")
check("clip restored", get_clip_field("clip1", "id") == "clip1")
check("volume=0.42", math.abs((get_clip_field("clip1", "volume") or 0) - 0.42) < 0.001)
check("mark_in=30", get_clip_field("clip1", "mark_in_frame") == 30)
check("mark_out=170", get_clip_field("clip1", "mark_out_frame") == 170)
check("playhead=85", get_clip_field("clip1", "playhead_frame") == 85)
-- Also verify core fields survived
check("timeline_start=100", get_clip_field("clip1", "timeline_start_frame") == 100)
check("duration=200", get_clip_field("clip1", "duration_frames") == 200)
check("name=TestClip", get_clip_field("clip1", "name") == "TestClip")

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_delete_clip_undo_preserves_metadata.lua passed")
