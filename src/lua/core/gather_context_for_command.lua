--- Context gathering for timeline edit commands
--
-- Responsibilities:
-- - Resolve UI state (selection, playhead, tracks) into command parameters
-- - Build clip groups from master clip selection (video + audio channels)
-- - Apply per-clip source marks (stored on master clip, not source viewer)
-- - Resolve target tracks for each group
--
-- Non-goals:
-- - Does not execute commands (only gathers context)
-- - Does not modify state
--
-- Invariants:
-- - All required parameters must be present (fail-fast, no defaults)
-- - Groups are always non-empty when returned successfully
--
-- @file gather_context_for_command.lua

local M = {}

local Rational = require("core.rational")
local Track = require("models.track")
local Media = require("models.media")
local clip_media = require("core.utils.clip_media")
local track_resolver = require("core.utils.track_resolver")
local logger = require("core.logger")

--- Get the clip's stored marks or fall back to full duration
-- @param clip table Master clip with source_in, source_out, duration fields
-- @param media table Media object for fallback duration
-- @param fps_num number FPS numerator for Rational construction
-- @param fps_den number FPS denominator for Rational construction
-- @return Rational source_in, Rational source_out, Rational duration
local function resolve_clip_marks(clip, media, fps_num, fps_den)
    assert(clip, "gather_context: clip required")
    assert(fps_num and fps_num > 0, "gather_context: fps_num required")
    assert(fps_den and fps_den > 0, "gather_context: fps_den required")

    local source_in = clip.source_in
    local source_out = clip.source_out
    local duration = clip.duration

    -- If clip has Rational marks, use them directly
    if source_in and getmetatable(source_in) == Rational.metatable then
        -- Already Rational, good
    elseif source_in and type(source_in) == "table" and source_in.frames ~= nil then
        source_in = Rational.new(source_in.frames, fps_num, fps_den)
    elseif source_in and type(source_in) == "number" then
        source_in = Rational.new(source_in, fps_num, fps_den)
    else
        -- Fall back to start of media
        source_in = Rational.new(0, fps_num, fps_den)
    end

    if source_out and getmetatable(source_out) == Rational.metatable then
        -- Already Rational, good
    elseif source_out and type(source_out) == "table" and source_out.frames ~= nil then
        source_out = Rational.new(source_out.frames, fps_num, fps_den)
    elseif source_out and type(source_out) == "number" then
        source_out = Rational.new(source_out, fps_num, fps_den)
    else
        -- Derive from duration or media duration
        if duration then
            local dur_frames
            if getmetatable(duration) == Rational.metatable then
                dur_frames = duration.frames
            elseif type(duration) == "table" and duration.frames then
                dur_frames = duration.frames
            elseif type(duration) == "number" then
                dur_frames = duration
            end
            if dur_frames then
                source_out = Rational.new(source_in.frames + dur_frames, fps_num, fps_den)
            end
        end
        if not source_out then
            assert(media and media.duration, "gather_context: no source_out and no media duration")
            local media_dur = media.duration
            if getmetatable(media_dur) == Rational.metatable then
                source_out = Rational.new(source_in.frames + media_dur.frames, fps_num, fps_den)
            elseif type(media_dur) == "table" and media_dur.frames then
                source_out = Rational.new(source_in.frames + media_dur.frames, fps_num, fps_den)
            elseif type(media_dur) == "number" then
                source_out = Rational.new(source_in.frames + media_dur, fps_num, fps_den)
            else
                error("gather_context: cannot resolve source_out from media duration")
            end
        end
    end

    -- Derive duration from marks
    duration = Rational.new(source_out.frames - source_in.frames, fps_num, fps_den)
    assert(duration.frames > 0, "gather_context: duration must be positive")

    return source_in, source_out, duration
end

--- Build a clip group from a master clip
-- A group contains video clip descriptor + audio clip descriptors for each channel
-- @param master_clip table Master clip from project browser
-- @param media table|nil Media object (loaded if not provided)
-- @param timeline_state table Timeline state module
-- @param seq_fps_num number Sequence FPS numerator
-- @param seq_fps_den number Sequence FPS denominator
-- @return table Group {clips = {...}, duration = Rational}
local function build_group_from_master_clip(master_clip, media, timeline_state, seq_fps_num, seq_fps_den)
    assert(master_clip, "gather_context: master_clip required")
    assert(timeline_state, "gather_context: timeline_state required")
    assert(seq_fps_num and seq_fps_num > 0, "gather_context: seq_fps_num required")
    assert(seq_fps_den and seq_fps_den > 0, "gather_context: seq_fps_den required")

    -- Load media if not provided
    if not media then
        assert(master_clip.media_id, "gather_context: master_clip missing media_id")
        media = Media.load(master_clip.media_id)
        assert(media, "gather_context: media not found for id " .. tostring(master_clip.media_id))
    end

    -- Get clip's FPS (prefer clip.rate, fallback to media.frame_rate)
    local clip_fps_num = (master_clip.rate and master_clip.rate.fps_numerator) or
                         (media.frame_rate and media.frame_rate.fps_numerator)
    local clip_fps_den = (master_clip.rate and master_clip.rate.fps_denominator) or
                         (media.frame_rate and media.frame_rate.fps_denominator)
    assert(clip_fps_num and clip_fps_num > 0, "gather_context: missing clip/media fps_numerator")
    assert(clip_fps_den and clip_fps_den > 0, "gather_context: missing clip/media fps_denominator")

    -- Resolve source marks (per-clip, not source viewer)
    local source_in, source_out, duration = resolve_clip_marks(master_clip, media, clip_fps_num, clip_fps_den)

    -- Determine channels (no pcall - let asserts propagate for missing dimensions)
    local has_video = clip_media.has_video(master_clip, media)
    local audio_channels = clip_media.audio_channel_count(master_clip, media)

    local clips = {}

    -- Video clip descriptor
    if has_video then
        local video_track = track_resolver.resolve_video_track(timeline_state, 0)
        table.insert(clips, {
            role = "video",
            media_id = master_clip.media_id or media.id,
            master_clip_id = master_clip.clip_id or master_clip.id,
            project_id = master_clip.project_id,
            name = master_clip.name or media.name,
            source_in = source_in,
            source_out = source_out,
            duration = duration,
            fps_numerator = clip_fps_num,
            fps_denominator = clip_fps_den,
            target_track_id = video_track.id,
        })
    end

    -- Audio clip descriptors (one per channel)
    for ch = 0, audio_channels - 1 do
        local audio_track = track_resolver.resolve_audio_track(timeline_state, ch)
        table.insert(clips, {
            role = "audio",
            channel = ch,
            media_id = master_clip.media_id or media.id,
            master_clip_id = master_clip.clip_id or master_clip.id,
            project_id = master_clip.project_id,
            name = (master_clip.name or media.name) .. " (Audio)",
            source_in = source_in,
            source_out = source_out,
            duration = duration,
            fps_numerator = clip_fps_num,
            fps_denominator = clip_fps_den,
            target_track_id = audio_track.id,
        })
    end

    assert(#clips > 0, "gather_context: master clip has neither video nor audio")

    return {
        clips = clips,
        duration = duration,
        master_clip_id = master_clip.clip_id or master_clip.id,
    }
end

--- Gather edit context from UI state
-- @param options table {
--   master_clips = list of master clips (optional if get_selected_master_clips provided)
--   get_selected_master_clips = function returning selected clips (optional)
--   timeline_state = timeline state module (required)
--   media_map = table mapping media_id -> media (optional)
--   arrangement = "serial"|"stacked" (default "serial")
-- }
-- @return table {
--   groups = {
--     {clips = {...}, duration = Rational, master_clip_id = "..."},
--     ...
--   },
--   position = Rational,
--   sequence_id = string,
--   project_id = string,
--   arrangement = "serial"|"stacked",
-- }
function M.gather_edit_context(options)
    assert(type(options) == "table", "gather_context: options table required")

    local timeline_state = assert(options.timeline_state, "gather_context: timeline_state required")

    -- Get sequence info
    local sequence_id = assert(
        timeline_state.get_sequence_id and timeline_state.get_sequence_id(),
        "gather_context: missing active sequence_id"
    )
    local project_id = assert(
        timeline_state.get_project_id and timeline_state.get_project_id(),
        "gather_context: missing active project_id"
    )

    -- Get playhead position
    local position = assert(
        timeline_state.get_playhead_position and timeline_state.get_playhead_position(),
        "gather_context: missing playhead position"
    )

    -- Get sequence FPS
    local Sequence = require("models.sequence")
    local sequence = assert(Sequence.load(sequence_id), "gather_context: sequence not found: " .. tostring(sequence_id))
    local seq_fps_num = assert(sequence.frame_rate and sequence.frame_rate.fps_numerator, "gather_context: sequence missing fps_numerator")
    local seq_fps_den = assert(sequence.frame_rate and sequence.frame_rate.fps_denominator, "gather_context: sequence missing fps_denominator")

    -- Get master clips
    local master_clips = options.master_clips
    if not master_clips and options.get_selected_master_clips then
        master_clips = options.get_selected_master_clips()
    end
    assert(master_clips and #master_clips > 0, "gather_context: no master clips selected")

    -- Build groups
    local groups = {}
    for _, master_clip in ipairs(master_clips) do
        local media = options.media_map and options.media_map[master_clip.media_id]
        local group = build_group_from_master_clip(master_clip, media, timeline_state, seq_fps_num, seq_fps_den)
        table.insert(groups, group)
    end

    assert(#groups > 0, "gather_context: no valid groups built from selection")

    local arrangement = options.arrangement or "serial"
    assert(arrangement == "serial" or arrangement == "stacked", "gather_context: arrangement must be serial or stacked")

    return {
        groups = groups,
        position = position,
        sequence_id = sequence_id,
        project_id = project_id,
        arrangement = arrangement,
        seq_fps_num = seq_fps_num,
        seq_fps_den = seq_fps_den,
    }
end

--- Gather context for a single master clip (convenience wrapper)
-- @param master_clip table Single master clip
-- @param timeline_state table Timeline state module
-- @param media table|nil Optional media object
-- @return table Same as gather_edit_context result
function M.gather_single_clip_context(master_clip, timeline_state, media)
    return M.gather_edit_context({
        master_clips = {master_clip},
        timeline_state = timeline_state,
        media_map = media and {[master_clip.media_id] = media} or nil,
    })
end

return M
