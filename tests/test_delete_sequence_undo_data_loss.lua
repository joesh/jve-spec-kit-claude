-- Regression: DeleteSequence undo must preserve ALL sequence/clip/link state.
-- Found bugs: fetch_sequence_record missing start_timecode_frame, scroll offsets,
-- split ratio. fetch_sequence_clips missing volume, marks, playhead.
-- clip_links and clip_properties never fetched.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
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

print("\n=== DeleteSequence Undo Data Loss Tests ===")

-- Setup DB with rich state
local db_path = "/tmp/jve/test_delete_seq_undo.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()


db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

-- Sequence with all fields populated (non-default values to detect loss)
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height,
        start_timecode_frame,
        view_start_frame, view_duration_frames, playhead_frame,
        video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
        mark_in_frame, mark_out_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Timeline', 'nested', 24, 1,
        48000, 1920, 1080,
        86400,
        50, 500, 100,
        42, 17, 0.65,
        10, 200,
        '["clip_a"]', '[{"edge":"head"}]', '[{"track":"v1"}]',
        7, %d, %d
    );
]], now, now))

-- Also create a second sequence so project isn't empty after delete
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq2', 'proj1', 'Backup', 'nested', 24, 1,
        48000, 1920, 1080,
        0, 240, 0,
        '[]', '[]', '[]',
        0, %d, %d
    );
]], now, now))

-- Tracks
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 1, 0, 0.8, -0.5);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq1', 'A1', 'AUDIO', 1, 1, 1, 0, 1, 0.6, 0.3);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v2', 'seq2', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Clips with non-default volume, marks, playhead
db:exec(string.format([[
    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj1', 'placeholder', '_placeholder', 5200, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj1', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 5200, 0, 5200, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, volume, mark_in_frame, mark_out_frame, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy) VALUES
    ('clip_a', 'proj1', 'VideoClip', 'v1', '_v13_placeholder_master', 'seq1', 0, 100, 1000, 1100, 1, 0.75, 10, 90, 50, %d, %d, NULL, NULL, 'resample');
]], now, now))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, volume, mark_in_frame, mark_out_frame, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy) VALUES
    ('clip_b', 'proj1', 'AudioClip', 'a1', '_v13_placeholder_master', 'seq1', 0, 200, 5000, 5200, 1, 0.5, 20, 180, 0, %d, %d, NULL, NULL, 'resample');
]], now, now))

-- Clip links (A/V sync)
db:exec([[
    INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
    VALUES ('link1', 'clip_a', 'video', 0, 1);
    INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
    VALUES ('link1', 'clip_b', 'audio', 10, 1);
]])

-- Clip properties
db:exec([[
    INSERT INTO properties (id, clip_id, property_name, property_value, property_type)
    VALUES ('prop1', 'clip_a', 'color_correction', '{"brightness":1.2}', 'json');
    INSERT INTO properties (id, clip_id, property_name, property_value, property_type)
    VALUES ('prop2', 'clip_b', 'eq_preset', '{"bass":3}', 'json');
]])

-- Init command_manager on seq2 (not seq1) since we're deleting seq1
command_manager.init("seq2", "proj1")

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

-- ── Execute DeleteSequence ──
print("\n--- Delete sequence ---")
local r = execute_cmd("DeleteSequence", {sequence_id = "seq1"})
check("delete succeeds", r and r.success)

-- Verify it's gone
local deleted = Sequence.load("seq1")
check("sequence deleted from DB", deleted == nil)

-- ── Undo ──
print("\n--- Undo delete ---")
r = undo()
-- Undo may return true, {success=true}, or false on error
local undo_ok = r == true or (type(r) == "table" and r.success)
if not undo_ok then
    -- Sequence restored despite undo returning failure? Check directly.
    local check_seq = Sequence.load("seq1")
    undo_ok = check_seq ~= nil
end
check("undo restores sequence", undo_ok)

-- ── Verify sequence state restored ──
print("\n--- Verify sequence fields ---")
local restored = Sequence.load("seq1")
check("sequence restored", restored ~= nil)

if restored then
    check("name", restored.name == "Timeline")
    check("start_timecode_frame=86400", restored.start_timecode_frame == 86400)
    check("video_scroll_offset=42", restored.video_scroll_offset == 42)
    check("audio_scroll_offset=17", restored.audio_scroll_offset == 17)
    check("split_ratio≈0.65", math.abs(restored.video_audio_split_ratio - 0.65) < 0.001)
    check("playhead=100", restored.playhead_position == 100)
    check("viewport_start=50", restored.viewport_start_time == 50)
    check("viewport_dur=500", restored.viewport_duration == 500)
    check("mark_in=10", restored.mark_in == 10)
    check("mark_out=200", restored.mark_out == 200)
end

-- ── Verify clips restored with all fields ──
-- Note: load_clips doesn't expose volume/marks/playhead, so verify via raw SQL
print("\n--- Verify clip fields ---")
local clips = database.load_clips("seq1")
check("2 clips restored", #clips == 2)

-- Check volume/marks/playhead via raw SQL (load_clips doesn't read these)
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

check("video clip volume=0.75", get_clip_field("clip_a", "volume") == 0.75)
check("video clip mark_in=10", get_clip_field("clip_a", "mark_in_frame") == 10)
check("video clip mark_out=90", get_clip_field("clip_a", "mark_out_frame") == 90)
check("video clip playhead=50", get_clip_field("clip_a", "playhead_frame") == 50)
check("audio clip volume=0.5", get_clip_field("clip_b", "volume") == 0.5)
check("audio clip mark_in=20", get_clip_field("clip_b", "mark_in_frame") == 20)

-- ── Verify clip links restored ──
print("\n--- Verify clip links ---")
local link_count = 0
local link_stmt = db:prepare("SELECT COUNT(*) FROM clip_links WHERE clip_id IN ('clip_a', 'clip_b')")
if link_stmt:exec() and link_stmt:next() then
    link_count = link_stmt:value(0)
end
link_stmt:finalize()
check("clip links restored (2 rows)", link_count == 2)

-- Verify link details
local link_detail_stmt = db:prepare("SELECT role, time_offset FROM clip_links WHERE clip_id = 'clip_b'")
if link_detail_stmt:exec() and link_detail_stmt:next() then
    check("audio link role=audio", link_detail_stmt:value(0) == "audio")
    check("audio link time_offset=10", link_detail_stmt:value(1) == 10)
end
link_detail_stmt:finalize()

-- ── Verify properties restored ──
print("\n--- Verify properties ---")
local prop_count = 0
local prop_stmt = db:prepare("SELECT COUNT(*) FROM properties WHERE clip_id IN ('clip_a', 'clip_b')")
if prop_stmt:exec() and prop_stmt:next() then
    prop_count = prop_stmt:value(0)
end
prop_stmt:finalize()
check("properties restored (2 rows)", prop_count == 2)

-- ── Verify tracks restored with non-default values ──
print("\n--- Verify track fields ---")
local track_stmt = db:prepare("SELECT muted, soloed, volume, pan, locked FROM tracks WHERE id = 'v1'")
if track_stmt:exec() and track_stmt:next() then
    check("track v1 muted=1", track_stmt:value(0) == 1)
    check("track v1 soloed=0", track_stmt:value(1) == 0)
    check("track v1 volume=0.8", math.abs(track_stmt:value(2) - 0.8) < 0.001)
    check("track v1 pan=-0.5", math.abs(track_stmt:value(3) - (-0.5)) < 0.001)
    check("track v1 locked=0", track_stmt:value(4) == 0)
end
track_stmt:finalize()

local track_a_stmt = db:prepare("SELECT locked, soloed, volume, pan FROM tracks WHERE id = 'a1'")
if track_a_stmt:exec() and track_a_stmt:next() then
    check("track a1 locked=1", track_a_stmt:value(0) == 1)
    check("track a1 soloed=1", track_a_stmt:value(1) == 1)
    check("track a1 volume=0.6", math.abs(track_a_stmt:value(2) - 0.6) < 0.001)
    check("track a1 pan=0.3", math.abs(track_a_stmt:value(3) - 0.3) < 0.001)
end
track_a_stmt:finalize()

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_delete_sequence_undo_data_loss.lua passed")
