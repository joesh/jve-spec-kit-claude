-- Regression: Sequence save/load must roundtrip all fields correctly.
-- Found bugs:
-- 1. created_at overwritten with os.time() on load (line 182) — original timestamp lost
-- 2. selected_gap_infos not roundtripped — schema column exists but model ignores it

require("test_env")

local database = require("core.database")
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

print("\n=== Sequence Save/Load Roundtrip Tests ===")

-- Setup DB
local db_path = "/tmp/jve/test_sequence_roundtrip.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local db = database.get_connection()
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))

-- Insert a sequence with specific created_at (in the past)
local created_timestamp = 1700000000  -- Nov 14, 2023
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        mark_in_frame, mark_out_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number,
        start_timecode_frame, video_scroll_offset, audio_scroll_offset,
        video_audio_split_ratio,
        created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Timeline', 'nested', 24, 1,
        48000, 1920, 1080,
        100, 50, 500,
        10, 200,
        '["clip_a"]', '[{"edge":"head"}]', '[{"track_id":"v1","start":50,"dur":10}]',
        7,
        86400, 42, 17,
        0.65,
        %d, %d
    );
]], created_timestamp, created_timestamp + 100))

-- ── Test 1: Basic roundtrip ──
print("\n--- Basic field roundtrip ---")
local seq = Sequence.load("seq1")
check("load succeeds", seq ~= nil)
check("id", seq.id == "seq1")
check("project_id", seq.project_id == "proj1")
check("name", seq.name == "Timeline")
check("kind", seq.kind == "nested")
check("fps_numerator", seq.frame_rate.fps_numerator == 24)
check("fps_denominator", seq.frame_rate.fps_denominator == 1)
check("width", seq.width == 1920)
check("height", seq.height == 1080)
check("audio_sample_rate", seq.audio_sample_rate == 48000)

-- ── Test 2: Integer coordinate roundtrip ──
print("\n--- Coordinate roundtrip ---")
check("playhead_position=100", seq.playhead_position == 100)
check("viewport_start_time=50", seq.viewport_start_time == 50)
check("viewport_duration=500", seq.viewport_duration == 500)
check("start_timecode_frame=86400", seq.start_timecode_frame == 86400)
check("video_scroll_offset=42", seq.video_scroll_offset == 42)
check("audio_scroll_offset=17", seq.audio_scroll_offset == 17)
check("video_audio_split_ratio≈0.65", math.abs(seq.video_audio_split_ratio - 0.65) < 0.001)

-- ── Test 3: Optional marks ──
print("\n--- Mark roundtrip ---")
check("mark_in=10", seq.mark_in == 10)
check("mark_out=200", seq.mark_out == 200)

-- ── Test 4: Selection JSON ──
print("\n--- Selection roundtrip ---")
check("selected_clip_ids_json", seq.selected_clip_ids_json == '["clip_a"]')
check("selected_edge_infos_json", seq.selected_edge_infos_json == '[{"edge":"head"}]')

-- ── Test 5: created_at timestamp preservation ──
print("\n--- Timestamp preservation ---")
-- BUG: load() sets created_at = os.time(), losing original timestamp
check("created_at preserved from DB", seq.created_at == created_timestamp)

-- ── Test 6: selected_gap_infos roundtrip ──
print("\n--- Gap selection roundtrip ---")
-- BUG: selected_gap_infos not loaded from DB
-- Verify by reading raw DB value
local gap_json = nil
local stmt = db:prepare("SELECT selected_gap_infos FROM sequences WHERE id = 'seq1'")
if stmt:exec() and stmt:next() then
    gap_json = stmt:value(0)
end
stmt:finalize()
check("gap_infos exists in DB", gap_json ~= nil and gap_json ~= "")

-- If the model loaded it, it should be on the object
check("selected_gap_infos_json loaded", seq.selected_gap_infos_json ~= nil)

-- ── Test 7: Save then reload preserves values ──
print("\n--- Save/reload roundtrip ---")
seq.playhead_position = 999
seq.mark_in = 50
seq.mark_out = 150
seq:save()

local reloaded = Sequence.load("seq1")
check("reloaded playhead=999", reloaded.playhead_position == 999)
check("reloaded mark_in=50", reloaded.mark_in == 50)
check("reloaded mark_out=150", reloaded.mark_out == 150)
-- created_at should still be original, not os.time()
check("reloaded created_at preserved", reloaded.created_at == created_timestamp)

-- ── Test 8: Nil marks survive roundtrip ──
print("\n--- Nil marks roundtrip ---")
reloaded.mark_in = nil
reloaded.mark_out = nil
reloaded:save()

local nil_marks = Sequence.load("seq1")
check("nil mark_in roundtrips", nil_marks.mark_in == nil)
check("nil mark_out roundtrips", nil_marks.mark_out == nil)

-- ── Test 9: Non-trivial values (DRP scale) ──
print("\n--- DRP-scale values ---")
nil_marks.playhead_position = 89849
nil_marks.viewport_start_time = 80000
nil_marks.viewport_duration = 20000
nil_marks:save()

local drp = Sequence.load("seq1")
check("drp playhead=89849", drp.playhead_position == 89849)
check("drp viewport_start=80000", drp.viewport_start_time == 80000)
check("drp viewport_dur=20000", drp.viewport_duration == 20000)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_sequence_save_load_roundtrip.lua passed")
