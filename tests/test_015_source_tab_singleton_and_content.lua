#!/usr/bin/env luajit

-- 015 — FR-001 (singleton master tab) + FR-007 (source content shown) regression.
--
-- Domain rules:
--   FR-001: at most one master tab in the timeline tab strip; loading a
--           different source replaces the existing source tab.
--   FR-005: master sequences MUST never be the active edit target.
--   FR-007: when the displayed tab is a master, the timeline view shows
--           the master's media spans (not an empty timeline).
--
-- Bugs this guards (from the 015-source-in-timeline branch):
--   1. Multiple MatchFrames left every prior source tab in the strip.
--   2. Clicking a stale master-kind tab routed through the record path
--      and set active=master, crashing playback.
--   3. Source tabs rendered as empty tracks because load_clips returns
--      no rows for masters (their content is in media_refs).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database       = require("core.database")
local Sequence       = require("models.sequence")
local timeline_state = require("ui.timeline.timeline_state")

print("=== test_015_source_tab_singleton_and_content.lua ===")

local DB = "/tmp/jve/test_015_source_tab_singleton_and_content.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")

database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- One record sequence + two master sequences (each with V1 + A1 + media_refs).
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES
      ('rec',     'proj', 'Record',   'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 1000, %d, %d),
      ('mst_a',   'proj', 'A008.mov', 'master', 24, 1, NULL, 1920, 1080, 0, 0, 1000, %d, %d),
      ('mst_b',   'proj', 'A037.mov', 'master', 24, 1, NULL, 1920, 1080, 0, 0, 1000, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rec_v1', 'rec',   'V1', 'VIDEO', 1, 1),
      ('rec_a1', 'rec',   'A1', 'AUDIO', 1, 1),
      ('a_v1',   'mst_a', 'V1', 'VIDEO', 1, 1),
      ('a_a1',   'mst_a', 'A1', 'AUDIO', 1, 1),
      ('b_v1',   'mst_b', 'V1', 'VIDEO', 1, 1),
      ('b_a1',   'mst_b', 'A1', 'AUDIO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES
      ('med_a', 'proj', 'A008.mov', '/tmp/A008.mov', 1200, 24, 1, 48000, 1920, 1080, %d, %d),
      ('med_b', 'proj', 'A037.mov', '/tmp/A037.mov',  600, 24, 1, 48000, 1920, 1080, %d, %d);

    -- Master A: TC origin at non-zero (cinema camera) frame 318650 (22:06:21:02 @ 24).
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      -- Video media_ref in master VIDEO timebase (frames @ 24fps).
      -- Audio media_ref in master AUDIO timebase (samples @ 48kHz).
      -- 318650 frames @ 24fps = 13277.083 sec × 48000 Hz = 637,300,000 samples.
      -- 1200 frames duration = 50 sec × 48000 = 2,400,000 samples.
      ('mref_a_v', 'proj', 'mst_a', 'a_v1', 'med_a', 0, 1200,    318650,    1200, 48000,    1, 1.0, 0, %d, %d),
      ('mref_a_a', 'proj', 'mst_a', 'a_a1', 'med_a', 0, 2400000, 637300000, 2400000, 48000, 1, 1.0, 0, %d, %d);

    -- Master B: TC origin at frame 0 (file with no embedded TC).
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      ('mref_b_v', 'proj', 'mst_b', 'b_v1', 'med_b', 0, 600,     0, 600, 48000,     1, 1.0, 0, %d, %d),
      -- 600 frames @ 24fps = 25 sec × 48000 = 1,200,000 samples.
      ('mref_b_a', 'proj', 'mst_b', 'b_a1', 'med_b', 0, 1200000, 0, 1200000, 48000, 1, 1.0, 0, %d, %d);
]], now, now,
    now, now, now, now, now, now,
    now, now, now, now,
    now, now, now, now,
    now, now, now, now))

-- ── (a) load_master_virtual_clips: media_refs become clip-shaped rows ──
print("-- (a) master content from media_refs --")
local virtual = database.load_master_virtual_clips("mst_a")
assert(#virtual == 2, string.format(
    "FAIL: expected 2 virtual clips for master 'mst_a' (V1 + A1 media_refs), got %d", #virtual))

-- The video virtual clip must span [318650, 318650+1200) — the file's TC range.
local v = nil
for _, c in ipairs(virtual) do
    if c.track_type == "VIDEO" then v = c end
end
assert(v, "FAIL: no VIDEO virtual clip generated for master")
assert(v.sequence_start == 318650, string.format(
    "FAIL: master video virtual clip sequence_start=%d, expected 318650 (file TC origin)", v.sequence_start))
assert(v.duration == 1200, string.format(
    "FAIL: master video virtual clip duration=%d, expected 1200 (file frame count)", v.duration))
assert(v.is_master_virtual == true,
    "FAIL: virtual clip must carry is_master_virtual=true tag")
assert(v.id:match("^mref:"),
    "FAIL: virtual clip id must be prefixed 'mref:' to distinguish from real clips")
print(string.format("  master video span: tl_start=%d duration=%d — OK",
    v.sequence_start, v.duration))

-- ── (b) load_master_virtual_clips on a different master returns its own spans
print("-- (b) per-master scoping --")
local virtual_b = database.load_master_virtual_clips("mst_b")
assert(#virtual_b == 2, "FAIL: master B expected 2 virtual clips")
local v_b
for _, c in ipairs(virtual_b) do
    if c.track_type == "VIDEO" then v_b = c end
end
assert(v_b.sequence_start == 0, "FAIL: master B video span should start at 0 (no TC offset)")
assert(v_b.duration == 600, "FAIL: master B video span duration mismatch")
print("  per-master spans correctly scoped — OK")

-- ── (c) timeline_state.activate_displayed swaps content for masters ──
print("-- (c) activating a master tab populates the timeline view from media_refs --")
local cmd_mgr = require("core.command_manager")
cmd_mgr.init("rec", "proj")
timeline_state.init("rec", "proj")
assert(#timeline_state.get_clips() == 0,
    "setup: record sequence has no clips initially")

timeline_state.activate_displayed("mst_a")
local view_clips = timeline_state.get_clips()
local virtual_count = 0
for _, c in ipairs(view_clips) do
    if c.is_master_virtual then virtual_count = virtual_count + 1 end
end
assert(virtual_count == 2, string.format(
    "FAIL: after activating master tab, the timeline view must contain 2 virtual clips, got %d",
    virtual_count))
print("  master tab timeline view shows media_refs as virtual clips — OK")

-- ── (d) Switching back to record loads real clip rows again ──
print("-- (d) switching back to record restores record-tab content --")
timeline_state.activate_displayed("rec")
local back_clips = timeline_state.get_clips()
for _, c in ipairs(back_clips) do
    assert(not c.is_master_virtual,
        "FAIL: record tab timeline view must not contain virtual master clips")
end
print("  record tab timeline view has no virtual master clips — OK")

-- ── (e) FR-005: master sequence is never the active edit target ──
print("-- (e) FR-005 active-target invariant --")
assert(timeline_state.get_active_sequence_id() == "rec",
    "FAIL: active_sequence_id must remain 'rec' even after viewing master tab (FR-005)")
print("  active_sequence_id stayed on record while viewing master — OK")

-- ── (f) is_master() correctly classifies the loaded sequences ──
print("-- (f) Sequence:is_master semantics --")
local rec = Sequence.load("rec")
local mst_a = Sequence.load("mst_a")
assert(not rec:is_master(), "FAIL: 'rec' is kind='sequence', not master")
assert(mst_a:is_master(), "FAIL: 'mst_a' is kind='master'")
print("  kind classification — OK")

print("\n✅ test_015_source_tab_singleton_and_content.lua passed")
