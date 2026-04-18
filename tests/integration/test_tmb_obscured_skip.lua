require("test_env")
--[[
  Domain contract: when a higher video track's clip fully covers a lower
  track's clip at a timeline position, the lower track's frame is not
  visible to the viewer and is not required for playback. Querying the
  lower track at that position must therefore communicate a terminal
  state — not a "waiting for decode" state — so that preroll / wait paths
  do not block on a frame that will never be decoded and would not be
  displayed if it were.

  Motivating scenario: preroll stalls 3s every Play when the playhead
  lands in a covered region of a lower track, because the wait path
  treats the covered-but-undecoded position as pending.
]]

local EMP = qt_constants.EMP

print("=== test_tmb_obscured_skip.lua ===")

-- Any non-empty media_path is fine: this test is metadata-only (cache_only
-- queries, no decode). TMB_SET_TRACK_CLIPS accepts any path; we never
-- attempt acquire_reader.
local FAKE_PATH = "/tmp/jve_obscured_test.mov"

local tmb = assert(EMP.TMB_CREATE(3))
EMP.TMB_SET_SEQUENCE_RATE(tmb, 24, 1)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb, 1920, 1080)

-- V1: timeline frames [0..200)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, {{
    clip_id = "lower-track-clip",
    media_path = FAKE_PATH,
    timeline_start = 0,
    duration = 200,
    source_in = 0,
    rate_num = 24,
    rate_den = 1,
    speed_ratio = 1.0,
}})

-- V5: timeline frames [50..150) — partially covers V1
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 5, {{
    clip_id = "higher-track-clip",
    media_path = FAKE_PATH,
    timeline_start = 50,
    duration = 100,
    source_in = 0,
    rate_num = 24,
    rate_den = 1,
    speed_ratio = 1.0,
}})

-- ------------------------------------------------------------------
-- Contract 1: at a position where V5 covers V1, V1 is reported as
-- not-needed-for-display (terminal, not pending).
-- ------------------------------------------------------------------
local COVERED_FRAME = 100  -- inside V5's span [50..150)
local frame, meta = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, COVERED_FRAME, true)

-- V1 has a clip at this position
assert(meta.clip_id == "lower-track-clip",
    string.format("expected lower-track-clip at frame %d, got %q",
        COVERED_FRAME, tostring(meta.clip_id)))

-- Cache-only with no decode queued: no frame
assert(frame == nil,
    string.format("expected no cached frame at %d (cache_only, no decode)", COVERED_FRAME))

-- Not offline (file doesn't exist but we haven't tried to open it)
assert(meta.offline == false,
    "expected offline=false (no open attempted via cache_only)")

-- The contract: V1 at this frame is OBSCURED — a wait path must treat
-- this as a terminal state and not block.
assert(meta.obscured == true, string.format(
    "V1 at frame %d is covered by V5's clip [50..150), so the result must "..
    "indicate the frame is not needed for display. Got obscured=%s",
    COVERED_FRAME, tostring(meta.obscured)))

print("  OK: lower track reports obscured=true under higher track's clip")

-- ------------------------------------------------------------------
-- Contract 2: the higher (covering) track is never reported as obscured.
-- ------------------------------------------------------------------
local _, meta_v5 = EMP.TMB_GET_VIDEO_FRAME(tmb, 5, COVERED_FRAME, true)
assert(meta_v5.clip_id == "higher-track-clip",
    "expected higher-track-clip on V5 at COVERED_FRAME")
assert(meta_v5.obscured == false,
    string.format("V5 is the highest track; nothing can obscure it. Got obscured=%s",
        tostring(meta_v5.obscured)))

print("  OK: top track reports obscured=false")

-- ------------------------------------------------------------------
-- Contract 3: outside the higher track's span, the lower track is not
-- obscured (normal display).
-- ------------------------------------------------------------------
local UNCOVERED_FRAME = 10  -- V1 has clip, V5 does not
local _, meta_uncovered = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, UNCOVERED_FRAME, true)
assert(meta_uncovered.clip_id == "lower-track-clip",
    "expected lower-track-clip on V1 at UNCOVERED_FRAME")
assert(meta_uncovered.obscured == false, string.format(
    "V1 at frame %d is outside V5's span — it is the visible track. Got obscured=%s",
    UNCOVERED_FRAME, tostring(meta_uncovered.obscured)))

print("  OK: lower track reports obscured=false outside higher track's span")

-- ------------------------------------------------------------------
-- Contract 4: gap position reports nothing (no clip on either track).
-- ------------------------------------------------------------------
local GAP_FRAME = 500  -- past end of both clips
local _, meta_gap = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, GAP_FRAME, true)
assert(meta_gap.clip_id == "", "expected empty clip_id at gap")
-- obscured is meaningless when there's no clip — but a default of false
-- matches "no display work needed here from this track's perspective"
assert(meta_gap.obscured == false,
    "gap position: obscured should be false (there's nothing to obscure)")

print("  OK: gap position reports no clip")

EMP.TMB_CLOSE(tmb)
print("  test_tmb_obscured_skip.lua passed")
