#!/usr/bin/env luajit
--- Source-tab virtual clips honor the unified placement convention.
---
--- Domain contract (CLAUDE.md feedback_timecode_is_truth post-unification):
---   media_refs.timeline_start_frame and duration_frames are master.fps
---   frames for V AND A (uniformly). For dual-medium masters master.fps ==
---   video fps; for audio-only master.fps == sample_rate. The source-tab
---   body's virtual-clip synthesizer must use those columns AS-IS — no
---   per-track-type unit conversion.
---
--- Live symptom (TSO 2026-05-16):
---   Source tab on a V+A master shows V1 clip but A1/A2 lanes are empty.
---   load_master_virtual_clips was dividing audio MR's placement columns
---   by samples_per_frame, treating them as pre-unification samples.
---   Result: a 7124-frame audio MR became 7124 / 1920 = 3 frames near
---   frame 0 — invisible at the master's ruler position (frame 2236+).
---
--- This test builds a V+A master with matching V/A MR placement (same
--- ts, same dur in master.fps frames) and verifies the virtual clips
--- come out at the same ts/dur — V and A interchangeable for the renderer.

require("test_env")

print("=== test_load_master_virtual_clips_audio_unit.lua ===")

local database = require("core.database")
local uuid = require("uuid")

local TEST_DB = "/tmp/jve/test_load_master_virtual_clips_audio_unit.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local FPS, SR = 25, 48000
local TC_FRAMES = 2236          -- 01:29:24:11 @ 25fps — matches anamnesis A038
local DUR_FRAMES = 7124         -- ~285s @ 25fps
local TC_SAMPLES = TC_FRAMES * SR / FPS    -- 4293120
local DUR_SAMPLES = DUR_FRAMES * SR / FPS  -- 13678080

local proj = "p1"
local master_id = uuid.generate()
local v_track = uuid.generate()
local a_track = uuid.generate()
local media_id = uuid.generate()
local v_mref = uuid.generate()
local a_mref = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'P', 'resample', %d, %d, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        width, height, metadata, created_at, modified_at)
    VALUES ('%s', '%s', 'A038.mov', '/tmp/A038.mov', %d, %d, 1, %d, 2,
            1920, 1080,
            '{"start_tc_value":%d,"start_tc_rate":%d,"start_tc_audio_samples":%d,"start_tc_audio_rate":%d}',
            %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('%s', '%s', 'A038', 'master', %d, 1, %d, 1920, 1080,
            %d, %d, %d, %d, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1),
           ('%s', '%s', 'A1', 'AUDIO', 1, 1);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        timeline_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      -- V MR: ts/dur in master.fps frames; source range in V frames
      ('%s', '%s', '%s', '%s', '%s', %d, %d, %d, %d, 1, 1.0, 0, %d, %d),
      -- A MR: ts/dur ALSO in master.fps frames (post-unification);
      -- source range in file-natural samples
      ('%s', '%s', '%s', '%s', '%s', %d, %d, %d, %d, 1, 1.0, 0, %d, %d);
]], proj, now, now,
    media_id, proj, DUR_FRAMES, FPS, SR, TC_FRAMES, FPS, TC_SAMPLES, SR, now, now,
    master_id, proj, FPS, SR, TC_FRAMES, TC_FRAMES, 0, 300, now, now,
    v_track, master_id, a_track, master_id,
    v_mref, proj, master_id, v_track, media_id,
        TC_FRAMES, TC_FRAMES + DUR_FRAMES, TC_FRAMES, DUR_FRAMES, now, now,
    a_mref, proj, master_id, a_track, media_id,
        TC_SAMPLES, TC_SAMPLES + DUR_SAMPLES, TC_FRAMES, DUR_FRAMES, now, now))

local clips = database.load_master_virtual_clips(master_id)
assert(type(clips) == "table",
    "load_master_virtual_clips must return a table")
assert(#clips == 2, string.format(
    "expected 2 virtual clips (V+A), got %d — audio MR missing from "
    .. "source-tab body means user sees empty audio lanes", #clips))

local v_clip, a_clip
for _, c in ipairs(clips) do
    if c.track_type == "VIDEO" then v_clip = c
    elseif c.track_type == "AUDIO" then a_clip = c end
end
assert(v_clip, "VIDEO virtual clip missing")
assert(a_clip, "AUDIO virtual clip missing")

-- ── Core invariant: V and A virtual clips placed identically ──
-- For a dual-medium master where the audio extent matches the video
-- extent, the virtual clips should land at the SAME timeline position
-- and span the SAME duration. The renderer treats both lanes in master.fps
-- frame space; any per-track-type unit conversion at load time breaks this.
assert(v_clip.timeline_start == TC_FRAMES, string.format(
    "V virtual clip timeline_start: expected %d (master.fps frames), got %d",
    TC_FRAMES, v_clip.timeline_start))
assert(v_clip.duration == DUR_FRAMES, string.format(
    "V virtual clip duration: expected %d, got %d",
    DUR_FRAMES, v_clip.duration))
assert(a_clip.timeline_start == TC_FRAMES, string.format(
    "A virtual clip timeline_start: expected %d (master.fps frames, "
    .. "same as V), got %d — pre-unification samples÷spf divide would "
    .. "have produced %d, which is invisible at ruler %d",
    TC_FRAMES, a_clip.timeline_start,
    math.floor(TC_SAMPLES / (SR / FPS)), TC_FRAMES))
assert(a_clip.duration == DUR_FRAMES, string.format(
    "A virtual clip duration: expected %d (master.fps frames, same "
    .. "as V), got %d — divide-by-spf bug would produce %d",
    DUR_FRAMES, a_clip.duration, math.floor(DUR_SAMPLES / (SR / FPS))))

-- ── source range stays in file-natural units ──
assert(a_clip.source_in == TC_SAMPLES and a_clip.source_out == TC_SAMPLES + DUR_SAMPLES,
    "audio virtual clip's source range must be file-natural samples")
assert(v_clip.source_in == TC_FRAMES and v_clip.source_out == TC_FRAMES + DUR_FRAMES,
    "video virtual clip's source range must be file-natural V frames")

print(string.format("  ✓ V virtual clip: ts=%d dur=%d", v_clip.timeline_start, v_clip.duration))
print(string.format("  ✓ A virtual clip: ts=%d dur=%d (matches V, no spf divide)",
    a_clip.timeline_start, a_clip.duration))
print("✅ test_load_master_virtual_clips_audio_unit.lua passed")
