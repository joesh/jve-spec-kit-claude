-- core/clip_position.lua — feature 018
--
-- DRY accessor for clip source positions (FR-009a). Every edit command and
-- other mutator of in-memory clip source positions goes through this module.
-- Direct field writes (`clip.source_in_frame = ...`) are forbidden outside
-- this module. INV-3 (subframe-presence by clip kind) and INV-4 (subframe
-- bound) are asserted at every mutation.
--
-- Sample/tick math is NOT in this module — callers compose subframe_math
-- primitives directly with numeric context they already hold
-- (master_clock_hz, source seq fps_num/den, mr.audio_sample_rate). See
-- specs/018-uniform-clip-source/contracts/clip_position.md (revised
-- 2026-05-18) for the rationale.

local subframe_math = require("core.subframe_math")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal asserts
-- ---------------------------------------------------------------------------

local function assert_clip(clip)
    assert(type(clip) == "table",
        "clip_position: clip must be a table")
    assert(clip.id ~= nil,
        "clip_position: clip.id missing — caller passed a malformed clip table")
    assert(clip.track_type == "VIDEO" or clip.track_type == "AUDIO",
        string.format(
            "clip_position: clip.track_type must be 'VIDEO' or 'AUDIO', got %s (clip=%s)",
            tostring(clip.track_type), tostring(clip.id)))
end

local function assert_int(name, v, clip_id)
    assert(type(v) == "number" and v == math.floor(v),
        string.format("clip_position: %s must be integer, got %s (clip=%s)",
            name, tostring(v), tostring(clip_id)))
end

local function assert_bound(name, frame_in, frame_out, clip_id)
    assert(frame_in <= frame_out, string.format(
        "clip_position.%s: source_in_frame (%d) must be <= source_out_frame (%d) (clip=%s)",
        name, frame_in, frame_out, tostring(clip_id)))
end

-- ---------------------------------------------------------------------------
-- Reads (defense-in-depth tripwires; the schema + load tripwire enforce
-- INV-3 already — this layer fails loud if any caller hands us a malformed
-- in-memory row).
-- ---------------------------------------------------------------------------

function M.read_audio_source(clip)
    assert_clip(clip)
    assert(clip.track_type == "AUDIO",
        string.format("clip_position.read_audio_source: clip %s is VIDEO, not AUDIO",
            tostring(clip.id)))
    assert(clip.source_in_subframe ~= nil and clip.source_out_subframe ~= nil,
        string.format(
            "clip_position.read_audio_source: audio clip %s has NULL subframe(s) — INV-3 violation",
            tostring(clip.id)))
    assert_int("source_in_frame", clip.source_in_frame, clip.id)
    assert_int("source_out_frame", clip.source_out_frame, clip.id)
    assert_int("source_in_subframe", clip.source_in_subframe, clip.id)
    assert_int("source_out_subframe", clip.source_out_subframe, clip.id)
    return clip.source_in_frame, clip.source_in_subframe,
           clip.source_out_frame, clip.source_out_subframe
end

function M.read_video_source(clip)
    assert_clip(clip)
    assert(clip.track_type == "VIDEO",
        string.format("clip_position.read_video_source: clip %s is AUDIO, not VIDEO",
            tostring(clip.id)))
    assert(clip.source_in_subframe == nil and clip.source_out_subframe == nil,
        string.format(
            "clip_position.read_video_source: video clip %s has non-NULL subframe — INV-3 violation",
            tostring(clip.id)))
    assert_int("source_in_frame", clip.source_in_frame, clip.id)
    assert_int("source_out_frame", clip.source_out_frame, clip.id)
    return clip.source_in_frame, clip.source_out_frame
end

-- ---------------------------------------------------------------------------
-- In-memory writes. The caller persists the mutated clip via the existing
-- apply_mutations / Clip.update pathway. No DB handle, no ctx grab-bag: tpf
-- is supplied as an integer that the caller derived once via
-- subframe_math.ticks_per_frame(master_clock_hz, fps_num, fps_den).
-- ---------------------------------------------------------------------------

function M.write_audio_source(clip, tpf, frame_in, subframe_in, frame_out, subframe_out)
    assert_clip(clip)
    assert(clip.track_type == "AUDIO",
        string.format("clip_position.write_audio_source: clip %s is VIDEO, not AUDIO",
            tostring(clip.id)))
    assert_int("tpf", tpf, clip.id)
    assert(tpf > 0, string.format(
        "clip_position.write_audio_source: tpf must be > 0 (got %d, clip=%s)",
        tpf, tostring(clip.id)))
    assert_int("frame_in", frame_in, clip.id)
    assert_int("subframe_in", subframe_in, clip.id)
    assert_int("frame_out", frame_out, clip.id)
    assert_int("subframe_out", subframe_out, clip.id)
    assert_bound("write_audio_source", frame_in, frame_out, clip.id)
    subframe_math.assert_canonical(frame_in, subframe_in, tpf,
        string.format("clip_position.write_audio_source: in (clip=%s)", tostring(clip.id)))
    subframe_math.assert_canonical(frame_out, subframe_out, tpf,
        string.format("clip_position.write_audio_source: out (clip=%s)", tostring(clip.id)))
    clip.source_in_frame     = frame_in
    clip.source_in_subframe  = subframe_in
    clip.source_out_frame    = frame_out
    clip.source_out_subframe = subframe_out
end

function M.write_video_source(clip, frame_in, frame_out)
    assert_clip(clip)
    assert(clip.track_type == "VIDEO",
        string.format("clip_position.write_video_source: clip %s is AUDIO, not VIDEO",
            tostring(clip.id)))
    assert_int("frame_in", frame_in, clip.id)
    assert_int("frame_out", frame_out, clip.id)
    assert_bound("write_video_source", frame_in, frame_out, clip.id)
    clip.source_in_frame  = frame_in
    clip.source_out_frame = frame_out
    -- Subframe columns remain NULL on video rows (INV-3).
end

-- Frame-aligned audio write (FR-013). subframe = 0 is canonical for any
-- tpf > 0, so no tpf parameter is required. Used by edit commands and
-- importers that write new audio clips on the frame-aligned mark UX.
function M.write_audio_source_frame_aligned(clip, frame_in, frame_out)
    assert_clip(clip)
    assert(clip.track_type == "AUDIO",
        string.format(
            "clip_position.write_audio_source_frame_aligned: clip %s is VIDEO, not AUDIO",
            tostring(clip.id)))
    assert_int("frame_in", frame_in, clip.id)
    assert_int("frame_out", frame_out, clip.id)
    assert_bound("write_audio_source_frame_aligned", frame_in, frame_out, clip.id)
    clip.source_in_frame     = frame_in
    clip.source_in_subframe  = 0
    clip.source_out_frame    = frame_out
    clip.source_out_subframe = 0
end

return M
