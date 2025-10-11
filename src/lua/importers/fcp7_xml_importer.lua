-- FCP7 XML (XMEML) Importer
-- Imports Final Cut Pro 7 XML sequences into JVE Editor
-- Supports: sequences, tracks, clips, media references

local M = {}

-- Parse FCP7 time value (rational number like "900/30")
-- Returns milliseconds
local function parse_time(time_str, frame_rate)
    if not time_str or time_str == "" then
        return 0
    end

    -- Handle rational format "numerator/denominator"
    local numerator, denominator = time_str:match("(%d+)/(%d+)")
    if numerator and denominator then
        local frames = tonumber(numerator) / tonumber(denominator)
        return math.floor((frames / frame_rate) * 1000)
    end

    -- Handle plain integer frames
    local frames = tonumber(time_str)
    if frames then
        return math.floor((frames / frame_rate) * 1000)
    end

    return 0
end

-- Extract frame rate from sequence timebase
local function extract_frame_rate(timebase_node)
    if not timebase_node then
        return 30.0  -- Default
    end

    -- <ntsc>TRUE</ntsc> indicates drop-frame 29.97
    -- <timebase>30</timebase> is the base rate
    local ntsc = false
    local base_rate = 30.0

    for child in timebase_node:children() do
        if child:name() == "ntsc" then
            ntsc = (child:text():upper() == "TRUE")
        elseif child:name() == "timebase" then
            base_rate = tonumber(child:text()) or 30.0
        end
    end

    -- Apply NTSC adjustment
    if ntsc and base_rate == 30.0 then
        return 29.97
    elseif ntsc and base_rate == 24.0 then
        return 23.976
    end

    return base_rate
end

-- Parse media file reference
local function parse_file(file_node, frame_rate)
    local media_info = {
        id = nil,
        name = nil,
        path = nil,
        duration = 0,
        frame_rate = frame_rate,
        width = 1920,
        height = 1080
    }

    for child in file_node:children() do
        local name = child:name()

        if name == "id" then
            media_info.id = child:text()
        elseif name == "name" then
            media_info.name = child:text()
        elseif name == "pathurl" then
            -- file://localhost/path/to/file.mov
            local url = child:text()
            media_info.path = url:gsub("^file://localhost", "")
            media_info.path = media_info.path:gsub("%%20", " ")  -- Decode spaces
        elseif name == "duration" then
            media_info.duration = parse_time(child:text(), frame_rate)
        elseif name == "media" then
            -- Parse video characteristics
            for media_child in child:children() do
                if media_child:name() == "video" then
                    for video_child in media_child:children() do
                        if video_child:name() == "samplecharacteristics" then
                            for char_child in video_child:children() do
                                if char_child:name() == "width" then
                                    media_info.width = tonumber(char_child:text()) or 1920
                                elseif char_child:name() == "height" then
                                    media_info.height = tonumber(char_child:text()) or 1080
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return media_info
end

-- Parse clip item
local function parse_clipitem(clipitem_node, frame_rate, track_id)
    local clip_info = {
        name = nil,
        file_id = nil,
        track_id = track_id,
        start_time = 0,  -- Timeline position
        duration = 0,
        source_in = 0,   -- Source media in-point
        source_out = 0,  -- Source media out-point
        enabled = true
    }

    for child in clipitem_node:children() do
        local name = child:name()

        if name == "name" then
            clip_info.name = child:text()
        elseif name == "file" then
            -- Nested file reference
            for file_child in child:children() do
                if file_child:name() == "id" then
                    clip_info.file_id = file_child:text()
                    break
                end
            end
        elseif name == "start" then
            clip_info.start_time = parse_time(child:text(), frame_rate)
        elseif name == "end" then
            local end_time = parse_time(child:text(), frame_rate)
            clip_info.duration = end_time - clip_info.start_time
        elseif name == "in" then
            clip_info.source_in = parse_time(child:text(), frame_rate)
        elseif name == "out" then
            clip_info.source_out = parse_time(child:text(), frame_rate)
        elseif name == "enabled" then
            clip_info.enabled = (child:text():upper() == "TRUE")
        end
    end

    return clip_info
end

-- Parse track
local function parse_track(track_node, frame_rate, track_type, track_index)
    local track_info = {
        type = track_type,  -- "VIDEO" or "AUDIO"
        index = track_index,
        enabled = true,
        locked = false,
        clips = {}
    }

    for child in track_node:children() do
        if child:name() == "clipitem" then
            -- Generate track ID (will be created in database)
            local track_id = string.format("%s%d", track_type:sub(1,1):lower(), track_index)
            local clip = parse_clipitem(child, frame_rate, track_id)
            table.insert(track_info.clips, clip)
        elseif child:name() == "enabled" then
            track_info.enabled = (child:text():upper() == "TRUE")
        elseif child:name() == "locked" then
            track_info.locked = (child:text():upper() == "TRUE")
        end
    end

    return track_info
end

-- Parse sequence
local function parse_sequence(sequence_node)
    local sequence_info = {
        name = "Untitled Sequence",
        frame_rate = 30.0,
        width = 1920,
        height = 1080,
        video_tracks = {},
        audio_tracks = {},
        media_files = {}  -- Map of file_id -> media_info
    }

    -- First pass: Extract basic info and timebase
    for child in sequence_node:children() do
        local name = child:name()

        if name == "name" then
            sequence_info.name = child:text()
        elseif name == "rate" then
            for rate_child in child:children() do
                if rate_child:name() == "timebase" then
                    sequence_info.frame_rate = tonumber(rate_child:text()) or 30.0
                end
            end
        end
    end

    -- Second pass: Parse media and tracks
    for child in sequence_node:children() do
        local name = child:name()

        if name == "media" then
            -- Media contains video and audio track groups
            local video_track_index = 1
            local audio_track_index = 1

            for media_child in child:children() do
                if media_child:name() == "video" then
                    -- Video tracks
                    for video_child in media_child:children() do
                        if video_child:name() == "track" then
                            local track = parse_track(video_child, sequence_info.frame_rate, "VIDEO", video_track_index)
                            table.insert(sequence_info.video_tracks, track)
                            video_track_index = video_track_index + 1
                        end
                    end
                elseif media_child:name() == "audio" then
                    -- Audio tracks
                    for audio_child in media_child:children() do
                        if audio_child:name() == "track" then
                            local track = parse_track(audio_child, sequence_info.frame_rate, "AUDIO", audio_track_index)
                            table.insert(sequence_info.audio_tracks, track)
                            audio_track_index = audio_track_index + 1
                        end
                    end
                end
            end
        end
    end

    return sequence_info
end

-- Main import function
-- xml_path: path to FCP7 XML file
-- project_id: target JVE project ID
-- Returns: {success, sequences, errors}
function M.import_xml(xml_path, project_id)
    local xml2 = require('xml2')
    local result = {
        success = false,
        sequences = {},
        media_files = {},
        errors = {}
    }

    -- Read and parse XML
    local file = io.open(xml_path, "r")
    if not file then
        table.insert(result.errors, string.format("Failed to open file: %s", xml_path))
        return result
    end

    local xml_content = file:read("*all")
    file:close()

    local doc, err = xml2.parse(xml_content)
    if not doc then
        table.insert(result.errors, string.format("Failed to parse XML: %s", err or "unknown error"))
        return result
    end

    -- Verify root element
    local root = doc:root()
    if root:name() ~= "xmeml" then
        table.insert(result.errors, "Not a valid FCP7 XML file (missing <xmeml> root)")
        return result
    end

    -- Find sequences
    for child in root:children() do
        if child:name() == "sequence" then
            local sequence = parse_sequence(child)
            table.insert(result.sequences, sequence)
        elseif child:name() == "project" then
            -- Projects contain sequences
            for project_child in child:children() do
                if project_child:name() == "children" then
                    for children_child in project_child:children() do
                        if children_child:name() == "sequence" then
                            local sequence = parse_sequence(children_child)
                            table.insert(result.sequences, sequence)
                        end
                    end
                end
            end
        end
    end

    if #result.sequences == 0 then
        table.insert(result.errors, "No sequences found in XML")
        return result
    end

    result.success = true
    return result
end

-- Create JVE database entities from parsed XML
-- parsed_result: output from import_xml()
-- db: database connection
-- Returns: {success, sequence_ids, error}
function M.create_entities(parsed_result, db, project_id)
    if not parsed_result.success then
        return {success = false, error = "Import failed"}
    end

    local Sequence = require('models.sequence')
    local Track = require('models.track')
    local Clip = require('models.clip')
    local Media = require('models.media')
    local uuid = require('uuid')

    local result = {
        success = true,
        sequence_ids = {},
        track_ids = {},
        clip_ids = {},
        media_ids = {}
    }

    -- Create sequences
    for _, seq_info in ipairs(parsed_result.sequences) do
        local sequence = Sequence.create(
            seq_info.name,
            project_id,
            seq_info.frame_rate,
            seq_info.width,
            seq_info.height
        )

        if not sequence:save(db) then
            return {success = false, error = "Failed to create sequence"}
        end

        table.insert(result.sequence_ids, sequence.id)

        -- Create video tracks
        for _, track_info in ipairs(seq_info.video_tracks) do
            local track = Track.create(
                string.format("V%d", track_info.index),
                sequence.id,
                "VIDEO",
                track_info.index
            )
            track.enabled = track_info.enabled
            track.locked = track_info.locked

            if not track:save(db) then
                return {success = false, error = "Failed to create video track"}
            end

            table.insert(result.track_ids, track.id)

            -- Create clips on this track
            for _, clip_info in ipairs(track_info.clips) do
                -- TODO: Create media reference first
                -- For now, create clip without media
                local clip_id = uuid.generate()
                local clip = Clip.new(clip_id)
                clip.track_id = track.id
                clip.start_time = clip_info.start_time
                clip.duration = clip_info.duration
                clip.source_in = clip_info.source_in
                clip.source_out = clip_info.source_out
                clip.enabled = clip_info.enabled

                if not clip:save(db) then
                    return {success = false, error = "Failed to create clip"}
                end

                table.insert(result.clip_ids, clip.id)
            end
        end

        -- Create audio tracks
        for _, track_info in ipairs(seq_info.audio_tracks) do
            local track = Track.create(
                string.format("A%d", track_info.index),
                sequence.id,
                "AUDIO",
                track_info.index
            )
            track.enabled = track_info.enabled
            track.locked = track_info.locked

            if not track:save(db) then
                return {success = false, error = "Failed to create audio track"}
            end

            table.insert(result.track_ids, track.id)

            -- Create clips (similar to video)
            for _, clip_info in ipairs(track_info.clips) do
                local clip_id = uuid.generate()
                local clip = Clip.new(clip_id)
                clip.track_id = track.id
                clip.start_time = clip_info.start_time
                clip.duration = clip_info.duration
                clip.source_in = clip_info.source_in
                clip.source_out = clip_info.source_out
                clip.enabled = clip_info.enabled

                if not clip:save(db) then
                    return {success = false, error = "Failed to create clip"}
                end

                table.insert(result.clip_ids, clip.id)
            end
        end
    end

    return result
end

return M
