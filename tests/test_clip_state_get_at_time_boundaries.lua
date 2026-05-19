#!/usr/bin/env luajit
-- Regression: clip_state.get_at_time uses half-open [start, start+duration).
--
-- Domain: in NLE convention, the clip starting at frame N owns boundary N
-- (its first frame). The clip ending at N+duration does NOT own that
-- boundary — the next clip (or empty space) does. So:
--   * playhead == clip.sequence_start            → clip is at playhead (IN edge inclusive)
--   * clip.sequence_start < playhead < clip_end  → clip is at playhead (interior)
--   * playhead == clip_end                       → clip is NOT at playhead (next owns it)
--
-- The previous strict-open `>`/`<` interval excluded BOTH boundaries,
-- silently dropping the first frame of every clip — caught downstream as
-- "MatchFrame on the first frame of a clip doesn't work, audio sneaks in
-- because its sub-frame-rounded sequence_start lands one frame earlier."

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local clip_state = require("ui.timeline.state.clip_state")
local data = require("ui.timeline.state.timeline_state_data")

local function reset_with_clip(opts)
    data.reset()
    data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
    data.state.clips = {
        {
            id = opts.id or "c1",
            track_id = opts.track_id or "v1",
            sequence_start = opts.sequence_start,
            duration = opts.duration,
            enabled = true,
        },
    }
    clip_state.invalidate_indexes()
end

local function ids_at(time)
    local matches = clip_state.get_at_time(time)
    local out = {}
    for _, c in ipairs(matches) do out[#out + 1] = c.id end
    return out
end

-- Use non-trivial coordinates so off-by-one bugs in either direction
-- can't accidentally line up with zero.
local START = 100
local DURATION = 10
local LAST_FRAME = START + DURATION - 1   -- 109
local NEXT_BOUNDARY = START + DURATION    -- 110

reset_with_clip({ sequence_start = START, duration = DURATION })

-- IN edge: clip MUST be at playhead.
local at_start = ids_at(START)
assert(#at_start == 1 and at_start[1] == "c1",
    string.format("clip must be present at its IN edge (playhead=%d, start=%d); got %d clips",
        START, START, #at_start))

-- Interior: clip is at playhead.
local at_mid = ids_at(START + 5)
assert(#at_mid == 1 and at_mid[1] == "c1",
    "clip must be present in its interior")

-- Last frame still belongs to this clip (the OUT boundary is at start+duration).
local at_last = ids_at(LAST_FRAME)
assert(#at_last == 1 and at_last[1] == "c1",
    "clip must be present on its last frame (one before next boundary)")

-- OUT boundary: clip MUST NOT be at playhead — the next clip (or empty
-- space) owns this boundary. Otherwise overlapping clips at edges all
-- claim the same frame.
local at_end = ids_at(NEXT_BOUNDARY)
assert(#at_end == 0,
    string.format("clip must NOT be present at its OUT boundary (playhead=%d); got %d clips",
        NEXT_BOUNDARY, #at_end))

-- Before IN edge: not at playhead.
local at_before = ids_at(START - 1)
assert(#at_before == 0, "clip must not be present before its IN edge")

-- Multi-clip boundary: when clip A ends at frame N and clip B starts at N,
-- only clip B is at playhead N. Models the real-world "two adjacent clips
-- on the same track" case.
data.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.clips = {
    { id = "a", track_id = "v1", sequence_start = 50,  duration = 10, enabled = true },
    { id = "b", track_id = "v1", sequence_start = 60,  duration = 10, enabled = true },
}
clip_state.invalidate_indexes()

local at_60 = ids_at(60)
assert(#at_60 == 1 and at_60[1] == "b",
    string.format("at the shared boundary (60), only clip B owns it; got %s",
        table.concat(at_60, ",")))

-- Sub-frame rounding cross-track case (audio.start = video.start - 1 due to
-- BWF offset rounding). Without the fix, audio matched at video's first
-- frame because audio.start < playhead but video.start == playhead, so
-- pick_best_clip got audio-only. The fix means video is also at playhead,
-- so the video-trumps-audio rule in pick_best_clip can do its job.
data.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.clips = {
    { id = "video", track_id = "v1", sequence_start = 200, duration = 24, enabled = true },
    { id = "audio", track_id = "a1", sequence_start = 199, duration = 26, enabled = true },
}
clip_state.invalidate_indexes()

local first_frame = ids_at(200)
local has_video, has_audio = false, false
for _, id in ipairs(first_frame) do
    if id == "video" then has_video = true end
    if id == "audio" then has_audio = true end
end
assert(has_video,
    "video clip must be at its first frame so MatchFrame can pick it over audio")
assert(has_audio,
    "audio clip is also present at this frame (it actually started one frame earlier)")

print("✅ clip_state.get_at_time uses half-open [start, end) boundaries")
