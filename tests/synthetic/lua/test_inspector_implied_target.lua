-- Inspector implied target picker.
--
-- When the inspector has no explicit selection, it inspects an IMPLIED
-- clip derived from what the user is currently looking at on the
-- displayed timeline tab. The picker is a pure function:
--
--   pick(tracks, clips_at_frame) -> clip | nil
--
-- Rule (per Joe, 2026-06-22):
--   * Prefer the video clip on the highest enabled video track at the
--     playhead. Highest = highest track_index.
--   * If no enabled video track has a clip at the playhead, fall through
--     to audio: the topmost (lowest track_index) enabled audio track
--     with a clip at the playhead.
--   * Disabled tracks are skipped entirely (track.enabled = false).
--   * Returns nil if no enabled track has a clip at the playhead.
--
-- Black-box: tests describe what the user expects to see in the inspector
-- given a configuration of tracks + clips under the playhead, not how
-- the picker walks them.

require("test_env")
local implied = require("ui.inspector.implied_target")

local function track(opts)
    return {
        id = opts.id,
        track_type = opts.track_type,
        track_index = opts.track_index,
        enabled = opts.enabled ~= false,
    }
end

local function clip(opts)
    return { id = opts.id, track_id = opts.track_id }
end

local function assert_pick(label, tracks, clips_at_frame, expected_clip_id)
    local got = implied.pick(tracks, clips_at_frame)
    local got_id = got and got.id or nil
    assert(got_id == expected_clip_id, string.format(
        "%s: expected clip_id=%s, got %s",
        label, tostring(expected_clip_id), tostring(got_id)))
end

-- ─── Video preference ──────────────────────────────────────────────────────

do
    -- V1 + V2 both present at playhead → pick V2 (higher track_index).
    local tracks = {
        track{ id = "tV1", track_type = "VIDEO", track_index = 1 },
        track{ id = "tV2", track_type = "VIDEO", track_index = 2 },
        track{ id = "tA1", track_type = "AUDIO", track_index = 1 },
    }
    local clips = {
        clip{ id = "cV1", track_id = "tV1" },
        clip{ id = "cV2", track_id = "tV2" },
        clip{ id = "cA1", track_id = "tA1" },
    }
    assert_pick("video prefers highest track_index", tracks, clips, "cV2")
end

do
    -- V3 disabled; V2 + V1 present. Should skip V3 and pick V2.
    local tracks = {
        track{ id = "tV1", track_type = "VIDEO", track_index = 1 },
        track{ id = "tV2", track_type = "VIDEO", track_index = 2 },
        track{ id = "tV3", track_type = "VIDEO", track_index = 3, enabled = false },
    }
    local clips = {
        clip{ id = "cV1", track_id = "tV1" },
        clip{ id = "cV2", track_id = "tV2" },
        clip{ id = "cV3", track_id = "tV3" },
    }
    assert_pick("disabled top video track is skipped", tracks, clips, "cV2")
end

do
    -- Highest enabled video track has NO clip at the playhead → fall to V1.
    -- (Highest enabled = V2, but no cV2 in candidates.)
    local tracks = {
        track{ id = "tV1", track_type = "VIDEO", track_index = 1 },
        track{ id = "tV2", track_type = "VIDEO", track_index = 2 },
    }
    local clips = {
        clip{ id = "cV1", track_id = "tV1" },
    }
    assert_pick("falls through to lower video when top is empty at playhead",
        tracks, clips, "cV1")
end

-- ─── Audio fallback ────────────────────────────────────────────────────────

do
    -- No video clips at playhead → topmost (lowest-index) enabled audio.
    local tracks = {
        track{ id = "tV1", track_type = "VIDEO", track_index = 1 },
        track{ id = "tA1", track_type = "AUDIO", track_index = 1 },
        track{ id = "tA2", track_type = "AUDIO", track_index = 2 },
    }
    local clips = {
        clip{ id = "cA1", track_id = "tA1" },
        clip{ id = "cA2", track_id = "tA2" },
    }
    assert_pick("audio fallback prefers lowest track_index", tracks, clips, "cA1")
end

do
    -- A1 enabled but has no clip at playhead; A2 enabled WITH clip. Should
    -- pick A2 — the audio walk skips empty enabled tracks the same way the
    -- video walk does.
    local tracks = {
        track{ id = "tA1", track_type = "AUDIO", track_index = 1 },
        track{ id = "tA2", track_type = "AUDIO", track_index = 2 },
    }
    local clips = {
        clip{ id = "cA2", track_id = "tA2" },
    }
    assert_pick("falls through to lower audio when top is empty at playhead",
        tracks, clips, "cA2")
end

do
    -- A1 disabled; A2 + A3 present. Should pick A2 (lowest enabled).
    local tracks = {
        track{ id = "tA1", track_type = "AUDIO", track_index = 1, enabled = false },
        track{ id = "tA2", track_type = "AUDIO", track_index = 2 },
        track{ id = "tA3", track_type = "AUDIO", track_index = 3 },
    }
    local clips = {
        clip{ id = "cA1", track_id = "tA1" },
        clip{ id = "cA2", track_id = "tA2" },
        clip{ id = "cA3", track_id = "tA3" },
    }
    assert_pick("disabled top audio track is skipped", tracks, clips, "cA2")
end

do
    -- Video tracks all disabled; only audio fires.
    local tracks = {
        track{ id = "tV1", track_type = "VIDEO", track_index = 1, enabled = false },
        track{ id = "tA1", track_type = "AUDIO", track_index = 1 },
    }
    local clips = {
        clip{ id = "cV1", track_id = "tV1" },
        clip{ id = "cA1", track_id = "tA1" },
    }
    assert_pick("disabled video falls through to audio", tracks, clips, "cA1")
end

-- ─── Empty cases ───────────────────────────────────────────────────────────

do
    -- No clips at all at the playhead → nil.
    local tracks = {
        track{ id = "tV1", track_type = "VIDEO", track_index = 1 },
        track{ id = "tA1", track_type = "AUDIO", track_index = 1 },
    }
    assert_pick("no clips at playhead → nil", tracks, {}, nil)
end

do
    -- Tracks exist but all are disabled → nil.
    local tracks = {
        track{ id = "tV1", track_type = "VIDEO", track_index = 1, enabled = false },
        track{ id = "tA1", track_type = "AUDIO", track_index = 1, enabled = false },
    }
    local clips = {
        clip{ id = "cV1", track_id = "tV1" },
        clip{ id = "cA1", track_id = "tA1" },
    }
    assert_pick("all tracks disabled → nil", tracks, clips, nil)
end

do
    -- No tracks at all → nil.
    assert_pick("no tracks → nil", {}, {}, nil)
end

print("✅ test_inspector_implied_target.lua passed")
