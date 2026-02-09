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

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== Database Error Paths Tests (T5) ===")

local db_path = "/tmp/jve/test_database_error_paths.db"
os.remove(db_path)

assert(database.init(db_path))
local db = database.get_connection()

-- Seed: project + sequence + track + media + clips
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq1', 'timeline', 24, 1, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'shot_01.mov', '/tmp/jve/shot_01.mov', 1000,
        24, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now))

-- clip1: normal clip with media
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip1', 'proj1', 'timeline', 'My Clip', 'trk1', 'med1',
        'seq1',
        0, 100, 0, 100,
        24, 1, 1, 0, %d, %d);
]], now, now))

-- clip2: clip with empty name → should generate default
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip2', 'proj1', 'timeline', '', 'trk1', 'med1',
        'seq1',
        100, 50, 0, 50,
        24, 1, 1, 0, %d, %d);
]], now, now))

-- Audio track for no-overlap clips
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a1', 'seq1', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- clip3: clip with NO media (media_id NULL) on audio track
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip3', 'proj1', 'timeline', '', 'trk_a1', NULL,
        'seq1',
        0, 200, 0, 200,
        48000, 1, 1, 0, %d, %d);
]], now, now))

-- Empty sequence for zero-clip tests
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq_empty', 'proj1', 'Empty Seq', 'timeline', 30, 1, 48000,
        1920, 1080, 0, 300, 0, '[]', '[]', %d, %d);
]], now, now))


-- ═══════════════════════════════════════════════════════════════
-- 1. load_clips / build_clip_from_query_row
-- ═══════════════════════════════════════════════════════════════

print("\n--- 1. load_clips / build_clip_from_query_row ---")

-- 1a. Missing sequence_id → FATAL
expect_error("load_clips(nil) → FATAL", function()
    database.load_clips(nil)
end, "FATAL.*requires sequence_id")

-- 1b. Normal clip → correct Rational fields
local clips = database.load_clips("seq1")
check("load_clips returns 3 clips", #clips == 3)

local c1
for _, c in ipairs(clips) do
    if c.id == "clip1" then c1 = c end
end
assert(c1, "clip1 not found in load_clips result")

check("clip1.project_id", c1.project_id == "proj1")
check("clip1.track_id", c1.track_id == "trk1")
check("clip1.media_id", c1.media_id == "med1")
check("clip1.name", c1.name == "My Clip")
check("clip1.enabled", c1.enabled == true)
check("clip1.offline", c1.offline == false)

-- Integer coordinate fields
check("clip1.timeline_start is integer", type(c1.timeline_start) == "number")
check("clip1.timeline_start == 0", c1.timeline_start == 0)
check("clip1.duration == 100", c1.duration == 100)
check("clip1.source_in == 0", c1.source_in == 0)
check("clip1.source_out == 100", c1.source_out == 100)
check("clip1.rate.fps_numerator", c1.rate.fps_numerator == 24)
check("clip1.rate.fps_denominator", c1.rate.fps_denominator == 1)

-- 1c. Media label
check("clip1.media_name == shot_01.mov", c1.media_name == "shot_01.mov")
check("clip1.media_path", c1.media_path == "/tmp/jve/shot_01.mov")
check("clip1.label is name (non-empty)", c1.label == "My Clip")

-- 1d. Clip with empty name → generated default
local c2
for _, c in ipairs(clips) do
    if c.id == "clip2" then c2 = c end
end
assert(c2, "clip2 not found")
check("clip2 empty name → Clip <id>", c2.name == "Clip " .. ("clip2"):sub(1, 8))

-- 1e. Clip with no media → nil media fields, label falls back to clip id
local c3
for _, c in ipairs(clips) do
    if c.id == "clip3" then c3 = c end
end
assert(c3, "clip3 not found")
check("clip3.media_id is nil", c3.media_id == nil or c3.media_id == "")
check("clip3.media_name is nil", c3.media_name == nil)
check("clip3 no-media label → Clip <id>", c3.label == "Clip " .. ("clip3"):sub(1, 8))

-- 1f. Empty sequence → empty array
local empty_clips = database.load_clips("seq_empty")
check("load_clips empty seq → {}", #empty_clips == 0)

-- 1g. Nonexistent sequence → empty array (not error, just no rows)
local ghost_clips = database.load_clips("nonexistent_seq")
check("load_clips nonexistent → {}", #ghost_clips == 0)


-- ═══════════════════════════════════════════════════════════════
-- 2. load_sequences
-- ═══════════════════════════════════════════════════════════════

print("\n--- 2. load_sequences ---")

-- 2a. Missing project_id → FATAL
expect_error("load_sequences(nil) → FATAL", function()
    database.load_sequences(nil)
end, "FATAL.*requires project_id")

expect_error("load_sequences('') → FATAL", function()
    database.load_sequences("")
end, "FATAL.*requires project_id")

-- 2b. Valid project → returns sequences with computed duration
local seqs = database.load_sequences("proj1")
check("load_sequences returns 2 sequences", #seqs == 2)

local seq1
for _, s in ipairs(seqs) do
    if s.id == "seq1" then seq1 = s end
end
assert(seq1, "seq1 not found in load_sequences result")

check("seq1.name", seq1.name == "Seq1")
check("seq1.frame_rate.fps_numerator", seq1.frame_rate.fps_numerator == 24)
check("seq1.frame_rate.fps_denominator", seq1.frame_rate.fps_denominator == 1)
check("seq1.audio_sample_rate", seq1.audio_sample_rate == 48000)
check("seq1.width", seq1.width == 1920)
check("seq1.height", seq1.height == 1080)

-- Duration = max(clip_end). All timeline_start/duration stored in sequence fps (24/1):
-- clip1: 0+100=100, clip2: 100+50=150, clip3: 0+200=200. Max = 200.
check("seq1.duration is integer", type(seq1.duration) == "number")
check("seq1.duration = 200 frames (max clip end)", seq1.duration == 200)

-- 2c. Empty sequence → duration = Rational(0)
local seq_empty
for _, s in ipairs(seqs) do
    if s.id == "seq_empty" then seq_empty = s end
end
assert(seq_empty, "seq_empty not found")
check("empty seq duration == 0", seq_empty.duration == 0)

-- 2d. Nonexistent project → empty array
local ghost_seqs = database.load_sequences("nonexistent_proj")
check("load_sequences nonexistent → {}", #ghost_seqs == 0)


-- ═══════════════════════════════════════════════════════════════
-- 3. load_sequence_track_heights
-- ═══════════════════════════════════════════════════════════════

print("\n--- 3. load_sequence_track_heights ---")

-- 3a. nil sequence_id → {}
local result = database.load_sequence_track_heights(nil)
check("track_heights(nil) → {}", type(result) == "table" and next(result) == nil)

-- 3b. empty string → {}
result = database.load_sequence_track_heights("")
check("track_heights('') → {}", type(result) == "table" and next(result) == nil)

-- 3c. Nonexistent sequence → {}
result = database.load_sequence_track_heights("no_such_seq")
check("track_heights(nonexistent) → {}", type(result) == "table" and next(result) == nil)

-- 3d. Valid JSON object → decoded payload
db:exec([[
    INSERT OR REPLACE INTO sequence_track_layouts (sequence_id, track_heights_json, updated_at)
    VALUES ('seq1', '{"trk1": 80, "trk_a1": 40}', 1000);
]])
result = database.load_sequence_track_heights("seq1")
check("valid JSON → trk1=80", result.trk1 == 80)
check("valid JSON → trk_a1=40", result.trk_a1 == 40)

-- 3e. Malformed JSON → dkjson returns (nil, pos), caught at decode
db:exec([[
    UPDATE sequence_track_layouts SET track_heights_json = '{bad json###'
    WHERE sequence_id = 'seq1';
]])
expect_error("malformed JSON → FATAL", function()
    database.load_sequence_track_heights("seq1")
end, "invalid JSON")

-- 3f. JSON array [1,2,3] → rejected (track heights must be object, not array)
db:exec([[
    UPDATE sequence_track_layouts SET track_heights_json = '[1, 2, 3]'
    WHERE sequence_id = 'seq1';
]])
expect_error("JSON array → FATAL (expected object)", function()
    database.load_sequence_track_heights("seq1")
end, "expected JSON object")

-- 3g. JSON string instead of object → FATAL (string is not a table)
db:exec([[
    UPDATE sequence_track_layouts SET track_heights_json = '"hello"'
    WHERE sequence_id = 'seq1';
]])
expect_error("JSON string → FATAL (expected object)", function()
    database.load_sequence_track_heights("seq1")
end, "expected JSON object")

-- 3h. Empty string in DB → {} (no decode attempted)
db:exec([[
    UPDATE sequence_track_layouts SET track_heights_json = ''
    WHERE sequence_id = 'seq1';
]])
result = database.load_sequence_track_heights("seq1")
check("empty string JSON → {}", type(result) == "table" and next(result) == nil)

-- Cleanup for later tests
db:exec("DELETE FROM sequence_track_layouts WHERE sequence_id = 'seq1';")


-- ═══════════════════════════════════════════════════════════════
-- 4. save_bins
-- ═══════════════════════════════════════════════════════════════

print("\n--- 4. save_bins ---")

-- 4a. nil project_id → (false, reason)
local ok, reason = database.save_bins(nil, {})
check("save_bins(nil) → false", ok == false)
check("save_bins(nil) reason", type(reason) == "string" and reason:match("Missing project_id"))

-- 4b. empty project_id → (false, reason)
ok, reason = database.save_bins("", {})
check("save_bins('') → false", ok == false)

-- 4c. Empty bins list → success (no bins inserted, but no error)
ok = database.save_bins("proj1", {})
check("save_bins empty list → true", ok == true)

-- 4d. Single root bin → success, verify via load_bins
ok = database.save_bins("proj1", {
    { id = "bin_root", name = "Footage" },
})
check("save_bins single root → true", ok == true)

local bins = database.load_bins("proj1")
check("load_bins after save → 1 bin", #bins == 1)
check("bin name = Footage", bins[1] and bins[1].name == "Footage")

-- 4e. Parent-child hierarchy → success
ok = database.save_bins("proj1", {
    { id = "bin_root", name = "Footage" },
    { id = "bin_child", name = "Day 1", parent_id = "bin_root" },
    { id = "bin_grandchild", name = "Take 3", parent_id = "bin_child" },
})
check("save_bins hierarchy → true", ok == true)

bins = database.load_bins("proj1")
check("hierarchy: 3 bins saved", #bins == 3)

-- Verify parent-child links
local bin_map = {}
for _, b in ipairs(bins) do bin_map[b.id] = b end
check("child parent_id = root", bin_map.bin_child and bin_map.bin_child.parent_id == "bin_root")
check("grandchild parent_id = child", bin_map.bin_grandchild and bin_map.bin_grandchild.parent_id == "bin_child")
check("root parent_id = nil", bin_map.bin_root and bin_map.bin_root.parent_id == nil)

-- 4f. Re-save with subset → stale bins removed
ok = database.save_bins("proj1", {
    { id = "bin_root", name = "Footage" },
})
check("re-save subset → true", ok == true)

bins = database.load_bins("proj1")
check("stale bins removed → 1 bin", #bins == 1)

-- 4g. Bin with empty name → silently dropped by build_bin_lookup
ok = database.save_bins("proj1", {
    { id = "bin_good", name = "Good" },
    { id = "bin_empty", name = "" },
    { id = "bin_spaces", name = "   " },
})
check("bins with empty names → true", ok == true)

bins = database.load_bins("proj1")
check("empty-name bins dropped → 1 bin", #bins == 1)
check("only Good bin remains", bins[1] and bins[1].name == "Good")

-- 4h. Tag assignment preservation across re-save
-- First save bins and assign a clip
database.save_bins("proj1", {
    { id = "bin_a", name = "Bin A" },
    { id = "bin_b", name = "Bin B" },
})
database.assign_master_clips_to_bin("proj1", {"clip1"}, "bin_a")

-- Re-save with same bins → assignment should survive
database.save_bins("proj1", {
    { id = "bin_a", name = "Bin A" },
    { id = "bin_b", name = "Bin B" },
})

local clip_bin_map = database.load_master_clip_bin_map("proj1")
check("assignment survives re-save", clip_bin_map["clip1"] == "bin_a")


-- ═══════════════════════════════════════════════════════════════
-- 5. assign_master_clips_to_bin
-- ═══════════════════════════════════════════════════════════════

print("\n--- 5. assign_master_clips_to_bin ---")

-- Ensure bins exist
database.save_bins("proj1", {
    { id = "bin_x", name = "Bin X" },
    { id = "bin_y", name = "Bin Y" },
})

-- 5a. nil project_id → (false, reason)
ok, reason = database.assign_master_clips_to_bin(nil, {"clip1"}, "bin_x")
check("assign(nil proj) → false", ok == false)
check("assign(nil proj) reason", type(reason) == "string" and reason:match("Missing project_id"))

-- 5b. empty project_id → (false, reason)
ok, reason = database.assign_master_clips_to_bin("", {"clip1"}, "bin_x")
check("assign('' proj) → false", ok == false)

-- 5c. Empty clip_ids → (true) no-op
ok = database.assign_master_clips_to_bin("proj1", {}, "bin_x")
check("assign empty clips → true", ok == true)

-- 5d. Non-table clip_ids → (true) no-op
ok = database.assign_master_clips_to_bin("proj1", "not_a_table", "bin_x")
check("assign non-table clips → true", ok == true)

-- 5e. Invalid bin_id (nonexistent) → (false, reason)
ok, reason = database.assign_master_clips_to_bin("proj1", {"clip1"}, "nonexistent_bin")
check("assign invalid bin → false", ok == false)
check("assign invalid bin → reason", type(reason) == "string" and reason:match("invalid bin"))

-- 5f. Empty-string bin_id → (false, reason)
ok, reason = database.assign_master_clips_to_bin("proj1", {"clip1"}, "")
check("assign empty bin_id → false", ok == false)

-- 5g. Valid assignment → success
ok = database.assign_master_clips_to_bin("proj1", {"clip1"}, "bin_x")
check("assign valid → true", ok == true)

clip_bin_map = database.load_master_clip_bin_map("proj1")
check("clip1 assigned to bin_x", clip_bin_map["clip1"] == "bin_x")

-- 5h. Reassign to different bin → moves
ok = database.assign_master_clips_to_bin("proj1", {"clip1"}, "bin_y")
check("reassign → true", ok == true)

clip_bin_map = database.load_master_clip_bin_map("proj1")
check("clip1 moved to bin_y", clip_bin_map["clip1"] == "bin_y")

-- 5i. nil bin_id → unassign (delete assignment, no insert)
ok = database.assign_master_clips_to_bin("proj1", {"clip1"}, nil)
check("unassign (nil bin) → true", ok == true)

clip_bin_map = database.load_master_clip_bin_map("proj1")
check("clip1 unassigned", clip_bin_map["clip1"] == nil)

-- 5j. Multiple clips at once
ok = database.assign_master_clips_to_bin("proj1", {"clip1", "clip2"}, "bin_x")
check("assign 2 clips → true", ok == true)

clip_bin_map = database.load_master_clip_bin_map("proj1")
check("clip1 in bin_x", clip_bin_map["clip1"] == "bin_x")
check("clip2 in bin_x", clip_bin_map["clip2"] == "bin_x")


-- ═══════════════════════════════════════════════════════════════
-- 6. load_clip_marks / save_clip_marks
-- ═══════════════════════════════════════════════════════════════

print("\n--- 6. load_clip_marks / save_clip_marks ---")

-- 6a. load_clip_marks nil → assert
expect_error("load_clip_marks(nil) → assert", function()
    database.load_clip_marks(nil)
end, "clip_id required")

-- 6b. load_clip_marks('') → assert
expect_error("load_clip_marks('') → assert", function()
    database.load_clip_marks("")
end, "clip_id required")

-- 6c. load_clip_marks nonexistent → nil
local marks = database.load_clip_marks("nonexistent_clip")
check("load_clip_marks nonexistent → nil", marks == nil)

-- 6d. load_clip_marks valid → default values (nil marks, 0 playhead)
marks = database.load_clip_marks("clip1")
check("clip1 marks loaded", marks ~= nil)
check("clip1 mark_in default nil", marks.mark_in_frame == nil)
check("clip1 mark_out default nil", marks.mark_out_frame == nil)
check("clip1 playhead default 0", marks.playhead_frame == 0)

-- 6e. save_clip_marks nil clip → assert
expect_error("save_clip_marks(nil) → assert", function()
    database.save_clip_marks(nil, nil, nil, 0)
end, "clip_id required")

-- 6f. save_clip_marks nil playhead → assert
expect_error("save_clip_marks nil playhead → assert", function()
    database.save_clip_marks("clip1", nil, nil, nil)
end, "playhead required")

-- 6g. save_clip_marks → round-trip
database.save_clip_marks("clip1", 10, 90, 42)
marks = database.load_clip_marks("clip1")
check("mark_in round-trip", marks.mark_in_frame == 10)
check("mark_out round-trip", marks.mark_out_frame == 90)
check("playhead round-trip", marks.playhead_frame == 42)

-- 6h. Clear marks (set nil) → nullable
database.save_clip_marks("clip1", nil, nil, 0)
marks = database.load_clip_marks("clip1")
check("mark_in cleared → nil", marks.mark_in_frame == nil)
check("mark_out cleared → nil", marks.mark_out_frame == nil)
check("playhead reset → 0", marks.playhead_frame == 0)


-- ═══════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
    print("❌ test_database_error_paths.lua FAILED")
    os.exit(1)
else
    print("✅ test_database_error_paths.lua passed")
end
