-- Tests for database.load_sequences — verifies duration computation from clips
-- and field naming consistency.

require("test_env")

local database = require("core.database")

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

print("\n=== load_sequences Duration Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_load_sequences_dur.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local now = os.time()
local db = database.get_connection()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

-- Sequence with 2 clips on different tracks
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Timeline', 'nested', 24, 1, 48000, 1920, 1080,
        50, 500, 100, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v2', 'seq1', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Clip A: frames 0-99 (duration 100)
db:exec(string.format([[
    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj1', 'placeholder', '_placeholder', 200505, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj1', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 200505, 0, 200505, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('clip_a', 'proj1', 'A', 'v1', '_v13_placeholder_master', 'seq1', 0, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

-- Clip B: frames 200-499 (duration 300, ends at 500)
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('clip_b', 'proj1', 'B', 'v2', '_v13_placeholder_master', 'seq1', 200, 300, 0, 300, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

-- ── Test 1: Duration computed as max(clip_end) ──
print("\n--- Duration from clips ---")
local seqs = database.load_sequences("proj1")
check("returns 1 sequence", #seqs == 1)
local s = seqs[1]
check("duration = 500 (max of 100, 500)", s.duration == 500)

-- ── Test 2: Basic field presence ──
print("\n--- Field presence ---")
check("id", s.id == "seq1")
check("name", s.name == "Timeline")
check("kind", s.kind == "nested")
check("frame_rate table", type(s.frame_rate) == "table")
check("fps_numerator=24", s.frame_rate.fps_numerator == 24)
check("fps_denominator=1", s.frame_rate.fps_denominator == 1)
check("width=1920", s.width == 1920)
check("height=1080", s.height == 1080)
check("audio_sample_rate=48000", s.audio_sample_rate == 48000)

-- ── Test 3: Empty sequence has duration 0 ──
print("\n--- Empty sequence ---")
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq_empty', 'proj1', 'Empty', 'nested', 25, 1, 48000, 1920, 1080,
        0, 250, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))

seqs = database.load_sequences("proj1")
check("returns 2 sequences", #seqs == 2)
local empty_seq
for _, sq in ipairs(seqs) do
    if sq.id == "seq_empty" then empty_seq = sq end
end
check("empty seq found", empty_seq ~= nil)
check("empty seq duration=0", empty_seq.duration == 0)

-- ── Test 4: Non-trivial DRP-scale values ──
print("\n--- DRP-scale clip ---")
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq_drp', 'proj1', 'DRP', 'nested', 25, 1, 48000, 1920, 1080,
        0, 250, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v_drp', 'seq_drp', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('drp_clip', 'proj1', 'DRP', 'v_drp', '_v13_placeholder_master', 'seq_drp', 89849, 12345, 188160, 200505, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

seqs = database.load_sequences("proj1")
local drp_seq
for _, sq in ipairs(seqs) do
    if sq.id == "seq_drp" then drp_seq = sq end
end
check("drp seq found", drp_seq ~= nil)
-- duration = 89849 + 12345 = 102194
check("drp duration = 102194", drp_seq.duration == 102194)

-- ── Test 5: nil project_id errors ──
print("\n--- Error paths ---")
local ok, err = pcall(database.load_sequences, nil)
check("nil project_id errors", not ok)
check("error mentions project_id", tostring(err):match("project_id") ~= nil)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_load_sequences_duration.lua passed")
