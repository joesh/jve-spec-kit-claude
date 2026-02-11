--- Shared logic for Insert and Overwrite commands
--
-- Responsibilities:
-- - Resolve parameters from UI context when not explicitly provided
-- - Create selected_clip objects with video/audio channel support
-- - Provide audio track resolution
--
-- @file clip_edit_helper.lua

local M = {}

local Clip = require('models.clip')
local Media = require('models.media')
local Track = require('models.track')
local command_helper = require('core.command_helper')
local rational_helpers = require('core.command_rational_helpers')

local function get_timeline_state()
    return require('ui.timeline.timeline_state')
end

--- Resolve media_id from UI state if not provided
-- @param media_id string|nil Current media_id value
-- @param command table Command object for setting parameters
-- @return string|nil Resolved media_id
function M.resolve_media_id_from_ui(media_id, command)
    if media_id and media_id ~= "" then
        return media_id
    end

    local ui_state = require("ui.ui_state")
    local project_browser = ui_state.get_project_browser and ui_state.get_project_browser()
    if project_browser and project_browser.get_selected_master_clip then
        local selected_clip = project_browser.get_selected_master_clip()
        if selected_clip and selected_clip.media_id then
            media_id = selected_clip.media_id
            if command then
                command:set_parameter("media_id", media_id)
            end
        end
    end

    return media_id
end

--- Resolve sequence_id from args, track_id, or timeline_state
-- @param args table Command arguments
-- @param track_id string|nil Track ID to resolve from
-- @param command table Command object for setting parameters
-- @return string|nil Resolved sequence_id
function M.resolve_sequence_id(args, track_id, command)
    local sequence_id = args.sequence_id

    if (not sequence_id or sequence_id == "") and track_id and track_id ~= "" then
        sequence_id = command_helper.resolve_sequence_for_track(nil, track_id)
    end

    if not sequence_id or sequence_id == "" then
        local timeline_state = get_timeline_state()
        if timeline_state then
            sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
        end
    end

    if sequence_id and sequence_id ~= "" and command then
        command:set_parameter("sequence_id", sequence_id)
    end

    return sequence_id
end

--- Resolve track_id from first video track in sequence if not provided
-- @param track_id string|nil Current track_id value
-- @param sequence_id string Sequence to find tracks in
-- @param command table Command object for setting parameters
-- @return string|nil Resolved track_id, string|nil error message
function M.resolve_track_id(track_id, sequence_id, command)
    if track_id and track_id ~= "" then
        return track_id, nil
    end

    local video_tracks = Track.find_by_sequence(sequence_id, "VIDEO")
    if #video_tracks == 0 then
        return nil, string.format("no VIDEO tracks found in sequence_id=%s", tostring(sequence_id))
    end

    track_id = video_tracks[1].id
    if command then
        command:set_parameter("track_id", track_id)
    end

    return track_id, nil
end

--- Resolve edit time (insert/overwrite position) from playhead if not provided
-- @param edit_time number|table|nil Current edit time value
-- @param command table Command object for setting parameters
-- @param param_name string Parameter name ("insert_time" or "overwrite_time")
-- @return number|table Resolved edit time
function M.resolve_edit_time(edit_time, command, param_name)
    -- Note: edit_time == 0 is a valid position (start of timeline), only fall back to playhead when nil
    if edit_time == nil then
        local timeline_state = get_timeline_state()
        if timeline_state then
            local playhead_pos = timeline_state.get_playhead_position and timeline_state.get_playhead_position()
            if playhead_pos then
                if command then
                    command:set_parameter(param_name, playhead_pos)
                end
                return playhead_pos
            end
        end
    end
    return edit_time
end

--- Resolve timing for video stream from source (masterclip sequence or legacy master clip)
-- Pulls source_in/out from the video stream clip in native video frame units
-- Duck-typed: works with any object that has :video_stream() method
-- @param source table Masterclip sequence or master clip with :video_stream() method
-- @param params table Optional overrides {source_in, source_out, duration}
-- @return table {source_in, source_out, duration, fps_numerator, fps_denominator}
-- @return string|nil Error message if failed
function M.resolve_video_stream_timing(source, params)
    params = params or {}
    local video = source:video_stream()
    if not video then
        return nil, "No video stream in source"
    end

    local source_in = params.source_in or video.source_in
    local source_out = params.source_out or video.source_out
    local duration = params.duration or (source_out - source_in)

    return {
        source_in = source_in,
        source_out = source_out,
        duration = duration,
        fps_numerator = video.rate.fps_numerator,
        fps_denominator = video.rate.fps_denominator,
    }, nil
end

--- Resolve timing for audio stream from source (masterclip sequence or legacy master clip)
-- Pulls source_in/out from the first audio stream clip in native sample units
-- Duck-typed: works with any object that has :audio_streams() and :frame_to_samples() methods
-- @param source table Masterclip sequence or master clip with stream methods
-- @param params table Optional overrides in VIDEO frames (will be converted)
-- @return table {source_in, source_out, duration, fps_numerator, fps_denominator}
-- @return string|nil Error message if failed
function M.resolve_audio_stream_timing(source, params)
    params = params or {}
    local audio_streams = source:audio_streams()
    if #audio_streams == 0 then
        return nil, "No audio streams in source"
    end

    local audio = audio_streams[1]

    -- If params provided, they're in video frames - convert to samples
    local source_in, source_out
    if params.source_in then
        source_in = source:frame_to_samples(params.source_in)
        assert(source_in, string.format(
            "clip_edit_helper.resolve_audio_stream_timing: frame_to_samples failed for source_in=%d",
            params.source_in))
    else
        source_in = audio.source_in
    end
    if params.source_out then
        source_out = source:frame_to_samples(params.source_out)
        assert(source_out, string.format(
            "clip_edit_helper.resolve_audio_stream_timing: frame_to_samples failed for source_out=%d",
            params.source_out))
    else
        source_out = audio.source_out
    end

    local duration = source_out - source_in

    return {
        source_in = source_in,
        source_out = source_out,
        duration = duration,
        fps_numerator = audio.rate.fps_numerator,
        fps_denominator = audio.rate.fps_denominator,
    }, nil
end

--- Resolve all timing parameters (duration, source_in, source_out) as integers
-- @param params table Parameters containing duration/source values (integers)
-- @param master_clip table|nil Master clip for fallback values
-- @param media table|nil Media for fallback duration
-- @return table Resolved timing {duration, source_in, source_out} as integers
-- @return string|nil Error message if invalid
function M.resolve_timing(params, master_clip, media)
    -- Extract integer values from params (support both _value suffix and direct)
    local function to_int(val, label)
        if val == nil then return nil end
        assert(type(val) == "number", string.format("clip_edit_helper.resolve_timing: %s must be integer, got %s", label, type(val)))
        return val
    end

    local duration = to_int(params.duration_value or params.duration, "duration")
    local source_in = to_int(params.source_in_value or params.source_in, "source_in")
    local source_out = to_int(params.source_out_value or params.source_out, "source_out")

    -- Fallback to master_clip values (already integers after model refactor)
    if master_clip then
        if source_in == nil then
            source_in = master_clip.source_in or 0
        end
        if (duration == nil or duration <= 0) and master_clip.duration and master_clip.duration > 0 then
            duration = master_clip.duration
        end
        if source_out == nil and (duration == nil or duration <= 0) and master_clip.source_out then
            source_out = master_clip.source_out
        end
    end

    -- Fallback to media duration (already integer after model refactor)
    if (duration == nil or duration <= 0) and media then
        if media.duration and media.duration > 0 then
            duration = media.duration
        end
    end

    -- Default source_in to 0 (start of media)
    if source_in == nil then
        source_in = 0
    end

    -- Calculate missing values from available ones
    if source_out and (duration == nil or duration <= 0) then
        duration = source_out - source_in
    end
    if source_out == nil and duration and duration > 0 then
        source_out = source_in + duration
    end

    if not duration or duration <= 0 then
        return nil, string.format("invalid duration=%s", tostring(duration))
    end

    return {
        duration = duration,
        source_in = source_in,
        source_out = source_out
    }, nil
end

--- Determine clip name from command args, master_clip, media, or explicit caller name
-- @param args table Command arguments
-- @param master_clip table|nil Master clip
-- @param media table|nil Media
-- @param caller_name string|nil Explicit name from caller (required if no other source)
-- @return string Clip name
function M.resolve_clip_name(args, master_clip, media, caller_name)
    local name = args.clip_name
        or (master_clip and master_clip.name)
        or (media and media.name)
        or caller_name
    assert(name, "clip_edit_helper.resolve_clip_name: unable to determine clip name from args, master_clip, media, or caller")
    return name
end

--- Resolve clip name from args or source sequence
-- @param args table Command args (may have clip_name)
-- @param source_sequence table Masterclip sequence
-- @param media table|nil Media for fallback name
-- @return string Resolved clip name
function M.resolve_clip_name_for_sequence(args, source_sequence, media)
    local name = args.clip_name
        or (source_sequence and source_sequence.name)
        or (media and media.name)
    assert(name, "clip_edit_helper.resolve_clip_name_for_sequence: unable to determine clip name from args, source_sequence, or media")
    return name
end

--- Create a selected_clip object with video and audio support
-- @param params table {media_id, master_clip_id, project_id, duration, source_in, source_out, clip_name, clip_id, audio_channels}
-- @return table selected_clip object with has_video, has_audio, audio_channel_count, audio methods
function M.create_selected_clip(params)
    local audio_channels = params.audio_channels or 0

    local clip_payload = {
        role = "video",
        media_id = params.media_id,
        master_clip_id = params.master_clip_id,
        project_id = params.project_id,
        duration = params.duration,
        source_in = params.source_in,
        source_out = params.source_out,
        clip_name = params.clip_name,
        clip_id = params.clip_id
    }

    local selected_clip = {
        video = clip_payload
    }

    function selected_clip:has_video()
        return true
    end

    function selected_clip:has_audio()
        return audio_channels > 0
    end

    function selected_clip:audio_channel_count()
        return audio_channels
    end

    function selected_clip:audio(ch)
        assert(ch >= 0 and ch < audio_channels, "invalid audio channel index " .. tostring(ch))
        return {
            role = "audio",
            media_id = params.media_id,
            master_clip_id = params.master_clip_id,
            project_id = params.project_id,
            duration = params.duration,
            source_in = params.source_in,
            source_out = params.source_out,
            clip_name = params.clip_name .. " (Audio)",
            channel = ch
        }
    end

    return selected_clip
end

--- Create an audio track resolver function
-- @param sequence_id string Sequence ID
-- @return function(self, index) Returns track object for audio channel index
function M.create_audio_track_resolver(sequence_id)
    -- Initial list of audio tracks
    local audio_tracks = {}
    local timeline_state = get_timeline_state()
    if timeline_state and timeline_state.get_audio_tracks then
        audio_tracks = timeline_state.get_audio_tracks() or {}
    else
        audio_tracks = Track.find_by_sequence(sequence_id, "AUDIO") or {}
    end

    return function(_, index)
        assert(index >= 0, "invalid audio track index " .. tostring(index))

        if index < #audio_tracks then
            return audio_tracks[index + 1]  -- Lua is 1-indexed
        end

        -- Need to create audio track - first refresh the track list from DB
        -- (handles redo case where tracks exist but weren't in our initial list)
        local fresh_tracks = Track.find_by_sequence(sequence_id, "AUDIO") or {}
        if #fresh_tracks > #audio_tracks then
            audio_tracks = fresh_tracks
            if index < #audio_tracks then
                return audio_tracks[index + 1]
            end
        end

        -- Still need to create - find the max existing track index
        local max_index = 0
        for _, t in ipairs(audio_tracks) do
            if t.track_index and t.track_index > max_index then
                max_index = t.track_index
            end
        end

        local new_index = max_index + 1 + (index - #audio_tracks)
        local track_name = string.format("A%d", new_index)
        local new_track = Track.create_audio(track_name, sequence_id, {index = new_index})
        assert(new_track:save(), "failed to create audio track")
        audio_tracks[#audio_tracks + 1] = new_track
        return new_track
    end
end

--- Get media FPS from master_clip or media
-- @param db table Database connection
-- @param master_clip table|nil Master clip
-- @param media_id string Media ID
-- @param seq_fps_num number Fallback FPS numerator
-- @param seq_fps_den number Fallback FPS denominator
-- @return number fps_num, number fps_den
function M.get_media_fps(db, master_clip, media_id, seq_fps_num, seq_fps_den)
    if master_clip then
        return rational_helpers.require_master_clip_rate(master_clip)
    elseif media_id and media_id ~= "" then
        return rational_helpers.require_media_rate(db, media_id)
    end
    -- No master_clip or media_id: use sequence fps (valid for timeline clips with no media)
    assert(seq_fps_num, "clip_edit_helper.get_media_fps: no master_clip, no media_id, and no seq_fps_num fallback")
    assert(seq_fps_den, "clip_edit_helper.get_media_fps: no master_clip, no media_id, and no seq_fps_den fallback")
    return seq_fps_num, seq_fps_den
end

return M
