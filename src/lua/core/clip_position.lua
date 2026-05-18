-- core/clip_position.lua — feature 018
--
-- DRY accessor for clip source positions (FR-009a). Every importer, edit
-- command, resolver, and other reader/writer of clip source positions goes
-- through this module. Direct field access (`clip.source_in_frame = ...`) is
-- forbidden outside this module and `core/database.lua` (the load path).
--
-- See specs/018-uniform-clip-source/contracts/clip_position.md for the full
-- contract.

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
        string.format("clip_position: clip.track_type must be 'VIDEO' or 'AUDIO', got %s (clip=%s)",
            tostring(clip.track_type), tostring(clip.id)))
end

local function assert_int(name, v, clip_id)
    assert(type(v) == "number" and v == math.floor(v),
        string.format("clip_position: %s must be integer, got %s (clip=%s)",
            name, tostring(v), tostring(clip_id)))
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

function M.read_audio_source(clip)
    assert_clip(clip)
    assert(clip.track_type == "AUDIO",
        string.format("clip_position.read_audio_source: clip %s is VIDEO, not AUDIO",
            tostring(clip.id)))
    assert(clip.source_in_subframe ~= nil and clip.source_out_subframe ~= nil,
        string.format("clip_position.read_audio_source: audio clip %s has NULL subframe(s) — INV-3 violation",
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
        string.format("clip_position.read_video_source: video clip %s has non-NULL subframe — INV-3 violation",
            tostring(clip.id)))
    assert_int("source_in_frame", clip.source_in_frame, clip.id)
    assert_int("source_out_frame", clip.source_out_frame, clip.id)
    return clip.source_in_frame, clip.source_out_frame
end

-- ---------------------------------------------------------------------------
-- In-memory writes (the in-memory clip table is mutated; persisting is the
-- caller's responsibility via the existing apply_mutations pathway).
-- ---------------------------------------------------------------------------

local function assert_bound(name, frame_in, frame_out, clip_id)
    assert(frame_in <= frame_out, string.format(
        "clip_position.%s: source_in_frame (%d) must be <= source_out_frame (%d) (clip=%s)",
        name, frame_in, frame_out, tostring(clip_id)))
end

-- Compute ticks_per_frame for a clip's source sequence, using project's
-- master_clock_hz. Caller provides both numbers (no DB access from this module).
local function tpf(master_clock_hz, fps_num, fps_den)
    return subframe_math.ticks_per_frame(master_clock_hz, fps_num, fps_den)
end

function M.write_audio_source(clip, ctx, frame_in, subframe_in, frame_out, subframe_out)
    assert_clip(clip)
    assert(clip.track_type == "AUDIO",
        string.format("clip_position.write_audio_source: clip %s is VIDEO, not AUDIO",
            tostring(clip.id)))
    assert(type(ctx) == "table",
        "clip_position.write_audio_source: ctx table required (must contain master_clock_hz, source_fps_num, source_fps_den)")
    assert_int("master_clock_hz", ctx.master_clock_hz, clip.id)
    assert_int("source_fps_num", ctx.source_fps_num, clip.id)
    assert_int("source_fps_den", ctx.source_fps_den, clip.id)
    assert_int("frame_in", frame_in, clip.id)
    assert_int("subframe_in", subframe_in, clip.id)
    assert_int("frame_out", frame_out, clip.id)
    assert_int("subframe_out", subframe_out, clip.id)
    assert_bound("write_audio_source", frame_in, frame_out, clip.id)

    local tpf_val = tpf(ctx.master_clock_hz, ctx.source_fps_num, ctx.source_fps_den)
    subframe_math.assert_canonical(frame_in, subframe_in, tpf_val,
        "clip_position.write_audio_source: in")
    subframe_math.assert_canonical(frame_out, subframe_out, tpf_val,
        "clip_position.write_audio_source: out")

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

-- Convenience for the common edit-command case (FR-013): a frame-aligned audio
-- write where both subframes are zero. Asserts the call is intentional (caller
-- says ":frame_aligned" explicitly rather than passing nil for subframes).
function M.write_audio_source_frame_aligned(clip, ctx, frame_in, frame_out)
    M.write_audio_source(clip, ctx, frame_in, 0, frame_out, 0)
end

-- ---------------------------------------------------------------------------
-- Sample ↔ (frame, subframe) helpers (used by importers + resolver).
-- ---------------------------------------------------------------------------

-- Convert a file-natural sample position to (frame, subframe) under the given
-- source-sequence fps and project clock + the file's native sample rate.
function M.samples_to_frame_subframe(ctx, file_sample_rate, file_sample)
    assert(type(ctx) == "table",
        "clip_position.samples_to_frame_subframe: ctx required")
    local total_ticks = subframe_math.samples_to_ticks(
        file_sample, file_sample_rate, ctx.master_clock_hz)
    local tpf_val = tpf(ctx.master_clock_hz, ctx.source_fps_num, ctx.source_fps_den)
    return subframe_math.unpack(total_ticks, tpf_val)
end

-- Inverse: (frame, subframe) → file-natural sample.
function M.frame_subframe_to_samples(ctx, file_sample_rate, frame, subframe)
    assert(type(ctx) == "table",
        "clip_position.frame_subframe_to_samples: ctx required")
    local tpf_val = tpf(ctx.master_clock_hz, ctx.source_fps_num, ctx.source_fps_den)
    local total_ticks = subframe_math.pack(frame, subframe, tpf_val)
    return subframe_math.ticks_to_samples(
        total_ticks, file_sample_rate, ctx.master_clock_hz)
end

return M
