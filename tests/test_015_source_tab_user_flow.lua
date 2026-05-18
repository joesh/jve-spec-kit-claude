#!/usr/bin/env luajit

-- 015 — Black-box test of the source-tab user flow at the data/state layer.
--
-- This is a BEHAVIOR test, not an implementation test. It describes what
-- the user expects to see when interacting with source tabs, without
-- naming the modules/functions that implement those behaviors. Each
-- assertion corresponds to something visible in the running editor —
-- if the editor breaks visibly, an assertion here should fail.
--
-- Coverage limits: this test exercises timeline_state and the data
-- layer it sits on. UI-layer behaviors that require Qt widget creation
-- (tab strip rendering, monitor frame swapping, scroll restore) are NOT
-- covered here — those need a `--test` integration script. Anything in
-- this file that fails reveals a bug at the data layer or below.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database       = require("core.database")
local command_mgr    = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_015_source_tab_user_flow.lua ===")

-- ── Fixture: a record sequence + two master sequences with media at
-- realistic camera-original TC origins (~1.3M frames, 22 hours @ 24fps).
-- Each master's persisted viewport is the template default (0, 300) which
-- does NOT cover the master's content — a known gap that the activation
-- path must paper over so the user sees clips, not an empty viewport.

local DB = "/tmp/jve/test_015_source_tab_user_flow.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES
      ('rec',  'proj', 'Record', 'sequence', 25, 1, 48000, 1920, 1080, 200, 0, 1500, %d, %d),
      -- Master A: video + audio. Schema requires audio_sample_rate non-NULL
      -- when there's an audio media_ref. Camera-original media at TC origin
      -- 1,324,752 video frames (= 15:19:58:00 @ 24fps).
      ('msa',  'proj', 'A012',   'master', 24, 1, NULL, 1920, 1080,   0, 0,  300, %d, %d),
      ('msb',  'proj', 'A037',   'master', 24, 1, NULL, 1920, 1080,   0, 0,  300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rv1', 'rec', 'V1', 'VIDEO', 1, 1),
      ('ra1', 'rec', 'A1', 'AUDIO', 1, 1),
      ('av1', 'msa', 'V1', 'VIDEO', 1, 1),
      ('aa1', 'msa', 'A1', 'AUDIO', 1, 1),
      ('bv1', 'msb', 'V1', 'VIDEO', 1, 1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES
      ('ma', 'proj', 'A012', '/tmp/A012.mov', 1200, 24, 1, 48000, 1920, 1080, %d, %d),
      ('mb', 'proj', 'A037', '/tmp/A037.mov',  600, 24, 1, 48000, 1920, 1080, %d, %d);
    -- Master A: video media_ref in VIDEO FRAMES (master video timebase).
    -- Master A: audio media_ref in AUDIO SAMPLES (master audio timebase).
    -- 1,324,752 frames @ 24fps = 55198 sec; × 48000 Hz = 2,649,504,000 samples.
    -- 1200 frames duration = 50 sec × 48000 = 2,400,000 samples.
    -- The two media_refs describe the SAME physical span on disk in their
    -- respective track timebases — what the DRP importer actually writes.
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      ('mra_v', 'proj', 'msa', 'av1', 'ma', 0, 1200,    1324752,    1200, 1, 1.0, 0, %d, %d),
      ('mra_a', 'proj', 'msa', 'aa1', 'ma', 0, 2400000, 2649504000, 2400000, 1, 1.0, 0, %d, %d);
    -- Master B: video at TC origin frame 0 (file with no embedded TC).
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      ('mrb_v', 'proj', 'msb', 'bv1', 'mb', 0, 600, 0, 600, 1, 1.0, 0, %d, %d);
]], now,now, now,now, now,now, now,now, now,now, now,now, now,now, now,now, now,now))

command_mgr.init("rec", "proj")
timeline_state.init("rec", "proj")

-- ── Helper: does the current viewport intersect any visible clip? ─────
local function viewport_intersects_any_clip()
    local vs = timeline_state.get_viewport_start_time()
    local vd = timeline_state.get_viewport_duration()
    local ve = vs + vd
    for _, c in ipairs(timeline_state.get_clips()) do
        if not c.is_gap then
            local cs, ce = c.sequence_start, c.sequence_start + c.duration
            if cs < ve and ce > vs then return true, vs, ve, cs, ce end
        end
    end
    return false, vs, ve, nil, nil
end

local failures = {}
local function check(label, ok, detail)
    if ok then
        print(string.format("  PASS  %s", label))
    else
        print(string.format("  FAIL  %s — %s", label, detail or "(no detail)"))
        table.insert(failures, label)
    end
end

-- ── Baseline: clean state on record ───────────────────────────────────
print("-- baseline: timeline_state.init('rec') --")
check("active is record",
    timeline_state.get_active_sequence_id() == "rec",
    "got " .. tostring(timeline_state.get_active_sequence_id()))
check("displayed is record",
    timeline_state.get_displayed_tab_id() == "rec",
    "got " .. tostring(timeline_state.get_displayed_tab_id()))
check("timeline view has no real clips initially (record was empty)",
    #timeline_state.get_clips() == 0, "record has " .. #timeline_state.get_clips() .. " clips")

-- ── Activate master A as displayed (source tab equivalent) ────────────
print("-- activate master A as displayed --")
local rec_persisted_playhead_before = require("models.sequence").load("rec").playhead_position
timeline_state.activate_displayed("msa")

check("displayed is now master A",
    timeline_state.get_displayed_tab_id() == "msa",
    "got " .. tostring(timeline_state.get_displayed_tab_id()))
check("active is STILL record (FR-005)",
    timeline_state.get_active_sequence_id() == "rec",
    "got " .. tostring(timeline_state.get_active_sequence_id()))

-- Master A has 2 media_refs (V + A) → 2 virtual clips on activation.
local clips = timeline_state.get_clips()
local virtual_count = 0
for _, c in ipairs(clips) do
    if c.is_master_virtual then virtual_count = virtual_count + 1 end
end
check("timeline view shows master A's media_refs as 2 virtual clips",
    virtual_count == 2,
    string.format("got %d virtual clips of %d total", virtual_count, #clips))

-- The audio and video media_refs describe the SAME physical span in their
-- track-respective timebases. After synthesis they must show up at the
-- SAME sequence_start in the timeline view's coordinate system (master video frames).
-- A 2000× discrepancy indicates audio sample units leaking through as frames.
local v_clip, a_clip
for _, c in ipairs(clips) do
    if c.is_master_virtual and c.track_type == "VIDEO" then v_clip = c end
    if c.is_master_virtual and c.track_type == "AUDIO" then a_clip = c end
end
check("master A virtual VIDEO clip exists",  v_clip ~= nil, "")
check("master A virtual AUDIO clip exists",  a_clip ~= nil, "")
if v_clip and a_clip then
    check("audio virtual clip's sequence_start is in MASTER FRAMES (not samples)",
        math.abs(a_clip.sequence_start - v_clip.sequence_start) <= 1,
        string.format("video=%d audio=%d (audio is %.0fx larger — sample units leaking)",
            v_clip.sequence_start, a_clip.sequence_start,
            a_clip.sequence_start / math.max(1, v_clip.sequence_start)))
    check("audio virtual clip's duration is in MASTER FRAMES (not samples)",
        math.abs(a_clip.duration - v_clip.duration) <= 1,
        string.format("video duration=%d audio duration=%d", v_clip.duration, a_clip.duration))
end

-- Critical user-visible behavior: viewport must contain content.
-- The screenshot showed an empty timeline view because viewport=(0,300) but
-- master content sits at frame 1,324,752.
local intersects, vs, ve, cs, ce = viewport_intersects_any_clip()
check("viewport intersects master A's content (content visible)",
    intersects,
    string.format("viewport=[%s,%s) clip=[%s,%s)", tostring(vs), tostring(ve), tostring(cs), tostring(ce)))

-- ── Bad-persisted-viewport case: viewport so large it "intersects"
-- content but renders it as a single pixel. Real DBs in the wild have
-- ended up with viewport_duration in the billions of frames. Activation
-- must normalize the viewport — leaving the user with an unusably wide
-- viewport is no better than the empty-view symptom this fixes.
print("-- corrupt master A's persisted viewport, re-activate --")
db:exec("UPDATE sequences SET view_start_frame=0, view_duration_frames=2700000000 WHERE id='msa'")
timeline_state.activate_displayed("rec")
timeline_state.activate_displayed("msa")
local content_extent = 1200
local vd2 = timeline_state.get_viewport_duration()
check("absurd persisted viewport (2.7B frames) is normalized on activation",
    vd2 < content_extent * 100,
    string.format("viewport_duration=%d (content_extent=%d, ratio=%.0fx)",
        vd2, content_extent, vd2 / content_extent))

-- ── Switch to master B ───────────────────────────────────────────────
print("-- activate master B as displayed --")
timeline_state.activate_displayed("msb")
check("displayed is now master B",
    timeline_state.get_displayed_tab_id() == "msb",
    "got " .. tostring(timeline_state.get_displayed_tab_id()))
check("active is STILL record (FR-005)",
    timeline_state.get_active_sequence_id() == "rec",
    "got " .. tostring(timeline_state.get_active_sequence_id()))

local clips_b = timeline_state.get_clips()
local virtual_b = 0
for _, c in ipairs(clips_b) do
    if c.is_master_virtual then virtual_b = virtual_b + 1 end
end
check("timeline view shows master B's 1 virtual clip",
    virtual_b == 1,
    string.format("got %d virtual clips of %d total", virtual_b, #clips_b))

local intersects_b, vsb, veb, csb, ceb = viewport_intersects_any_clip()
check("viewport intersects master B's content",
    intersects_b,
    string.format("viewport=[%s,%s) clip=[%s,%s)", tostring(vsb), tostring(veb), tostring(csb), tostring(ceb)))

-- ── Switch back to record. Record's persisted state must be intact. ───
print("-- activate record again --")
timeline_state.activate_displayed("rec")
check("displayed is record again",
    timeline_state.get_displayed_tab_id() == "rec",
    "got " .. tostring(timeline_state.get_displayed_tab_id()))

local rec_after = require("models.sequence").load("rec")
check("record's persisted playhead unchanged by source-tab visits (no corruption)",
    rec_after.playhead_position == rec_persisted_playhead_before,
    string.format("before=%s after=%s",
        tostring(rec_persisted_playhead_before),
        tostring(rec_after.playhead_position)))

-- Record's playhead must be a sensible frame (< 1M) — plausibility check
-- against the bug observed in TSO where record playhead read as 1.5B.
check("record's persisted playhead is < 1,000,000 frames (sanity)",
    rec_after.playhead_position < 1000000,
    string.format("playhead=%s (huge value indicates corruption)",
        tostring(rec_after.playhead_position)))

-- Switching back removes virtual clips (record is empty in this fixture).
local clips_back = timeline_state.get_clips()
local still_virtual = 0
for _, c in ipairs(clips_back) do
    if c.is_master_virtual then still_virtual = still_virtual + 1 end
end
check("record timeline view has no virtual master clips after switching back",
    still_virtual == 0,
    string.format("got %d virtual clips leaking from master tab", still_virtual))

-- ── Marks/patches preservation across tab swaps (FR-007) ─────────────
-- (Skipped at this layer — patches and marks would need command setup.
--  Add those when extending this test or in a separate FR-007 black-box test.)

-- ── Report ────────────────────────────────────────────────────────────
print("")
if #failures == 0 then
    print("✅ test_015_source_tab_user_flow.lua passed")
else
    print(string.format("❌ test_015_source_tab_user_flow.lua FAILED — %d behavior(s) broken:", #failures))
    for _, f in ipairs(failures) do
        print("    - " .. f)
    end
    os.exit(1)
end
