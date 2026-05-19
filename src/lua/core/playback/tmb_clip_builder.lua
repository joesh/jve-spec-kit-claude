--- core/playback/tmb_clip_builder.lua — pure TMB-clip math (017/018).
--
-- Extracted from playback_engine.lua (2.6: short, single-responsibility
-- modules). Builds the row TMB consumes from a resolver-produced entry:
-- - clip_rate(entry):                rate paired with source_in's unit (FR-008)
-- - build_clip(entry, speed_ratio):  ClipInfo table for TMB_SET_TRACK_CLIPS
-- - compute_video_speed_ratio:       per-clip source-range / duration
-- - compute_audio_speed_ratio:       per-clip seq_fps / media_video_fps conform
--
-- Pure functions: every caller already holds the entry. The audio speed
-- ratio takes seq_fps explicitly so this module doesn't depend on the
-- engine object's lifecycle.

local media_status = require("core.media.media_status")

local M = {}

-- TMB rate must match source_in's unit (FR-008): video fps for VIDEO,
-- audio sample rate for AUDIO. Audio entries also carry video fps for
-- compute_audio_speed_ratio's seq-fps/media-fps conform — different role.
function M.clip_rate(entry)
    if entry.media_kind == "video" then
        return entry.fps_numerator, entry.fps_denominator
    end
    assert(type(entry.audio_sample_rate) == "number" and entry.audio_sample_rate > 0,
        string.format("tmb_clip_builder.clip_rate: audio entry %s missing audio_sample_rate",
            tostring(entry.clip_id)))
    return entry.audio_sample_rate, 1
end

function M.build_clip(entry, speed_ratio)
    assert(type(entry) == "table", string.format(
        "tmb_clip_builder.build_clip: entry must be table, got %s", type(entry)))
    assert(type(entry.media_path) == "string" and entry.media_path ~= "",
        "tmb_clip_builder.build_clip: entry.media_path must be non-empty string")
    assert(type(entry.fps_numerator) == "number"
        and type(entry.fps_denominator) == "number"
        and entry.fps_denominator > 0, string.format(
        "tmb_clip_builder.build_clip: clip %s missing fps_numerator / fps_denominator",
        tostring(entry.clip_id)))
    assert(type(speed_ratio) == "number" and speed_ratio ~= 0 and math.abs(speed_ratio) < 100, string.format(
        "tmb_clip_builder.build_clip: clip %s speed_ratio must be non-zero (|sr|<100), got %s",
        tostring(entry.clip_id), tostring(speed_ratio)))
    assert(entry.media_kind == "video" or entry.media_kind == "audio", string.format(
        "tmb_clip_builder.build_clip: clip %s missing media_kind (got %s)",
        tostring(entry.clip_id), tostring(entry.media_kind)))

    -- Resolve offline state from media_status — single source of truth.
    -- Was a direct io.open check here; that created two sources of truth
    -- for offline (this ad-hoc stat vs. the media_status cache bg probe
    -- + FS watcher maintain) and meant ClipInfo.offline could disagree
    -- with what the browser icon / timeline label displayed. If the path
    -- isn't registered yet (first clip build during sequence load, before
    -- bg probe lands), fall back to a one-shot stat so we don't default
    -- a legitimately-online clip to beeping on startup.
    local cached = media_status.get(entry.media_path)
    local is_offline
    if cached then
        is_offline = cached.offline
    else
        local f = io.open(entry.media_path, "r")
        is_offline = (f == nil)
        if f then f:close() end
    end

    local rate_num, rate_den = M.clip_rate(entry)
    return {
        clip_id        = entry.clip_id,
        media_path     = entry.media_path,
        sequence_start = entry.sequence_start,
        duration       = entry.duration,
        source_in      = entry.source_in,
        rate_num       = rate_num,
        rate_den       = rate_den,
        speed_ratio    = speed_ratio,
        offline        = is_offline,
        volume         = entry.volume,
    }
end

--- Compute video speed_ratio from clip's source range vs timeline duration.
-- When source_out - source_in == duration, speed is 1.0 (no change).
-- Otherwise, speed = source_range / sequence_duration (< 1.0 = slow motion).
-- source_range is signed: positive = forward, negative = reverse.
function M.compute_video_speed_ratio(entry)
    assert(entry.source_out ~= nil,
        "tmb_clip_builder.compute_video_speed_ratio: source_out is nil (clip_id="
        .. tostring(entry.clip_id) .. ")")
    assert(entry.source_in ~= nil,
        "tmb_clip_builder.compute_video_speed_ratio: source_in is nil (clip_id="
        .. tostring(entry.clip_id) .. ")")
    assert(entry.duration ~= nil,
        "tmb_clip_builder.compute_video_speed_ratio: duration is nil (clip_id="
        .. tostring(entry.clip_id) .. ")")
    local source_range = entry.source_out - entry.source_in
    assert(source_range ~= 0, string.format(
        "tmb_clip_builder.compute_video_speed_ratio: source_range must be non-zero, got %d "
        .. "(clip_id=%s, source_out=%d, source_in=%d)",
        source_range, tostring(entry.clip_id),
        entry.source_out, entry.source_in))
    assert(entry.duration > 0, string.format(
        "tmb_clip_builder.compute_video_speed_ratio: duration must be positive, got %d "
        .. "(clip_id=%s)", entry.duration, tostring(entry.clip_id)))
    local ratio = source_range / entry.duration
    assert(math.abs(ratio) > 0 and math.abs(ratio) < 100, string.format(
        "tmb_clip_builder.compute_video_speed_ratio: ratio out of sane range: %.4f "
        .. "(clip_id=%s, source_range=%d, duration=%d)",
        ratio, tostring(entry.clip_id), source_range, entry.duration))
    if math.abs(ratio - 1.0) < 0.001 then return 1.0 end
    if math.abs(ratio + 1.0) < 0.001 then return -1.0 end
    return ratio
end

--- Compute audio conform speed_ratio: seq_fps / media_video_fps.
-- When media_video_fps >= 1000 (audio-only) or matches seq_fps, returns 1.0.
function M.compute_audio_speed_ratio(entry, seq_fps_num, seq_fps_den)
    assert(type(entry.fps_numerator) == "number", string.format(
        "tmb_clip_builder.compute_audio_speed_ratio: missing fps_numerator (got %s)",
        type(entry.fps_numerator)))
    assert(type(entry.fps_denominator) == "number" and entry.fps_denominator > 0,
        string.format(
        "tmb_clip_builder.compute_audio_speed_ratio: invalid fps_denominator=%s",
        tostring(entry.fps_denominator)))
    assert(type(seq_fps_num) == "number" and type(seq_fps_den) == "number"
        and seq_fps_den > 0, string.format(
        "tmb_clip_builder.compute_audio_speed_ratio: invalid sequence fps (%s/%s)",
        tostring(seq_fps_num), tostring(seq_fps_den)))
    local media_video_fps = entry.fps_numerator / entry.fps_denominator
    if media_video_fps >= 1000 then return 1.0 end
    local seq_fps = seq_fps_num / seq_fps_den
    if math.abs(media_video_fps - seq_fps) < 0.01 then return 1.0 end
    return seq_fps / media_video_fps
end

return M
