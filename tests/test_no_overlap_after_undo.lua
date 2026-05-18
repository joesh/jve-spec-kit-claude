-- Test: no overlapping clips after undo operations.
-- Verifies the critical timeline invariant: clips on the same track must not overlap.

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

print("\n=== No Overlap After Undo Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_no_overlap_undo.db"
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
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 1000, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Helper: detect overlapping clips on a track
local function find_overlaps(track_id)
    local overlaps = {}
    local stmt = db:prepare([[
        SELECT c1.id, c1.sequence_start_frame, c1.duration_frames,
               c2.id, c2.sequence_start_frame, c2.duration_frames
        FROM clips c1
        JOIN clips c2 ON c1.track_id = c2.track_id
        WHERE c1.track_id = ?
        AND c1.id < c2.id
        AND c1.sequence_start_frame < c2.sequence_start_frame + c2.duration_frames
        AND c1.sequence_start_frame + c1.duration_frames > c2.sequence_start_frame
    ]])
    if not stmt then return overlaps end
    stmt:bind_value(1, track_id)
    if stmt:exec() then
        while stmt:next() do
            table.insert(overlaps, {
                clip1 = stmt:value(0),
                clip1_start = stmt:value(1),
                clip1_dur = stmt:value(2),
                clip2 = stmt:value(3),
                clip2_start = stmt:value(4),
                clip2_dur = stmt:value(5),
            })
        end
    end
    stmt:finalize()
    return overlaps
end

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

command_manager.init("seq1", "proj1")

-- ── Test 1: Delete middle clip, undo — no overlaps ──
print("\n--- Delete middle clip + undo ---")
db:exec(string.format([[
    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj1', 'placeholder', '_placeholder', 100, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj1', 'placeholder_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 100, 0, 100, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('c1', 'proj1', 'A', 'v1', '_v13_placeholder_master', 'seq1', 0, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('c2', 'proj1', 'B', 'v1', '_v13_placeholder_master', 'seq1', 100, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('c3', 'proj1', 'C', 'v1', '_v13_placeholder_master', 'seq1', 200, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now))

local overlaps = find_overlaps("v1")
check("initial: no overlaps", #overlaps == 0)

execute_cmd("DeleteClip", {clip_id = "c2", sequence_id = "seq1"})
overlaps = find_overlaps("v1")
check("after delete c2: no overlaps", #overlaps == 0)

undo()
overlaps = find_overlaps("v1")
check("after undo delete: no overlaps", #overlaps == 0)

-- Verify c2 is back
local clip_count = 0
local count_stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = 'v1'")
if count_stmt:exec() and count_stmt:next() then
    clip_count = count_stmt:value(0)
end
count_stmt:finalize()
check("c2 restored (3 clips)", clip_count == 3)

-- Clean up for next test
db:exec("DELETE FROM clips")

-- ── Test 2: Delete first clip then undo — positions preserved ──
print("\n--- Delete first clip + undo ---")
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('d1', 'proj1', 'First', 'v1', '_v13_placeholder_master', 'seq1', 0, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('d2', 'proj1', 'Second', 'v1', '_v13_placeholder_master', 'seq1', 100, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now))

command_manager.init("seq1", "proj1")
execute_cmd("DeleteClip", {clip_id = "d1", sequence_id = "seq1"})
undo()

overlaps = find_overlaps("v1")
check("delete first + undo: no overlaps", #overlaps == 0)

-- Verify positions
local function get_clip_start(clip_id)
    local q = db:prepare("SELECT sequence_start_frame FROM clips WHERE id = ?")
    q:bind_value(1, clip_id)
    local val = nil
    if q:exec() and q:next() then val = q:value(0) end
    q:finalize()
    return val
end

check("d1 restored at 0", get_clip_start("d1") == 0)
check("d2 still at 100", get_clip_start("d2") == 100)
db:exec("DELETE FROM clips")

-- ── Test 3: Multiple undo/redo cycles — invariant holds throughout ──
print("\n--- Multiple undo/redo cycles ---")
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('m1', 'proj1', 'A', 'v1', '_v13_placeholder_master', 'seq1', 0, 50, 0, 50, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('m2', 'proj1', 'B', 'v1', '_v13_placeholder_master', 'seq1', 50, 50, 0, 50, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('m3', 'proj1', 'C', 'v1', '_v13_placeholder_master', 'seq1', 100, 50, 0, 50, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now))

command_manager.init("seq1", "proj1")

-- Delete m2, then m1
execute_cmd("DeleteClip", {clip_id = "m2", sequence_id = "seq1"})
overlaps = find_overlaps("v1")
check("after delete m2: no overlaps", #overlaps == 0)

execute_cmd("DeleteClip", {clip_id = "m1", sequence_id = "seq1"})
overlaps = find_overlaps("v1")
check("after delete m1: no overlaps", #overlaps == 0)

-- Undo m1 delete
undo()
overlaps = find_overlaps("v1")
check("undo m1 delete: no overlaps", #overlaps == 0)

-- Undo m2 delete
undo()
overlaps = find_overlaps("v1")
check("undo m2 delete: no overlaps", #overlaps == 0)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_no_overlap_after_undo.lua passed")
