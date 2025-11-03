-- FCP7 XML (XMEML) Importer
-- Imports Final Cut Pro 7 XML sequences into JVE Editor
-- Supports: sequences, tracks, clips, media references

local M = {}
local uuid = require("uuid")

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

local function collect_children(node)
    local result = {}
    if not node then
        return result
    end
    for child in node:children() do
        table.insert(result, child)
    end
    return result
end

local function get_attr(node, name)
    if not node or not name then
        return nil
    end

    local ok, value = pcall(function()
        return node:attr(name)
    end)
    if ok and value and value ~= "" then
        return value
    end

    local attrs = node.attr or node.attrs
    if type(attrs) == "table" then
        local attr_value = attrs[name]
        if attr_value and attr_value ~= "" then
            return attr_value
        end
    end

    return nil
end

local function decode_url(url)
    if not url or url == "" then
        return url
    end
    local path = url:gsub("^file://", "")
    path = path:gsub("^localhost/", "")
    path = path:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return path
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
        id = get_attr(file_node, "id"),
        name = nil,
        path = nil,
        duration = 0,
        frame_rate = frame_rate,
        width = 1920,
        height = 1080,
        audio_channels = 0
    }

    local children = collect_children(file_node)
    for _, child in ipairs(children) do
        local name = child:name()

        if name == "id" then
            media_info.id = child:text()
        elseif name == "name" then
            media_info.name = child:text()
        elseif name == "pathurl" then
            media_info.path = decode_url(child:text())
        elseif name == "duration" then
            media_info.duration = parse_time(child:text(), frame_rate)
        elseif name == "rate" then
            media_info.frame_rate = extract_frame_rate(child)
        elseif name == "media" then
            -- Parse video characteristics
            local media_children = collect_children(child)
            for _, media_child in ipairs(media_children) do
                if media_child:name() == "video" then
                    local video_children = collect_children(media_child)
                    for _, video_child in ipairs(video_children) do
                        if video_child:name() == "samplecharacteristics" then
                            local char_children = collect_children(video_child)
                            for _, char_child in ipairs(char_children) do
                                if char_child:name() == "width" then
                                    media_info.width = tonumber(char_child:text()) or 1920
                                elseif char_child:name() == "height" then
                                    media_info.height = tonumber(char_child:text()) or 1080
                                end
                            end
                        end
                    end
                elseif media_child:name() == "audio" then
                    local audio_children = collect_children(media_child)
                    for _, audio_child in ipairs(audio_children) do
                        if audio_child:name() == "channelcount" then
                            media_info.audio_channels = tonumber(audio_child:text()) or 0
                        end
                    end
                end
            end
        end
    end

    if not media_info.name or media_info.name == "" then
        media_info.name = media_info.path or "Imported Media"
    end
    if media_info.frame_rate <= 0 then
        media_info.frame_rate = frame_rate
    end
    media_info.key = media_info.id or media_info.path

    return media_info
end

-- Parse clip item
local function parse_clipitem(clipitem_node, frame_rate, track_id, sequence_info)
    local clip_info = {
        original_id = get_attr(clipitem_node, "id"),
        id = get_attr(clipitem_node, "id"),
        name = nil,
        file_id = nil,
        media_key = nil,
        track_id = track_id,
        start_time = 0,
        duration = 0,
        source_in = 0,
        source_out = 0,
        enabled = true,
        frame_rate = frame_rate
    }

    local children = collect_children(clipitem_node)

    for _, child in ipairs(children) do
        if child:name() == "rate" then
            local clip_rate = extract_frame_rate(child)
            if clip_rate and clip_rate > 0 then
                clip_info.frame_rate = clip_rate
            end
        end
    end

    for _, child in ipairs(children) do
        local name = child:name()

        if name == "name" then
            clip_info.name = child:text()
        elseif name == "file" then
            local media_info = parse_file(child, clip_info.frame_rate)
            if media_info then
                clip_info.file_id = media_info.id
                clip_info.media_key = media_info.key
                if sequence_info and media_info.key then
                    local existing = sequence_info.media_files[media_info.key]
                    if existing then
                        local function copy_if_present(field, allow_zero)
                            local value = media_info[field]
                            local is_string = type(value) == "string"
                            local is_number = type(value) == "number"
                            local keep =
                                (is_string and value ~= nil and value ~= "") or
                                (is_number and (allow_zero or value ~= 0)) or
                                (value ~= nil and not is_string and not is_number)
                            if keep then
                                existing[field] = value
                            end
                        end
                        copy_if_present("path", false)
                        copy_if_present("name", false)
                        copy_if_present("duration", false)
                        copy_if_present("frame_rate", false)
                        copy_if_present("width", false)
                        copy_if_present("height", false)
                        copy_if_present("audio_channels", false)
                        media_info = existing
                    else
                        sequence_info.media_files[media_info.key] = media_info
                    end
                elseif sequence_info then
                    sequence_info.media_files[media_info.key] = media_info
                end
                clip_info.media = media_info
            end
        elseif name == "start" then
            clip_info.start_time = parse_time(child:text(), clip_info.frame_rate)
        elseif name == "end" then
            local end_time = parse_time(child:text(), clip_info.frame_rate)
            clip_info.duration = end_time - clip_info.start_time
        elseif name == "in" then
            clip_info.source_in = parse_time(child:text(), clip_info.frame_rate)
        elseif name == "out" then
            clip_info.source_out = parse_time(child:text(), clip_info.frame_rate)
        elseif name == "enabled" then
            clip_info.enabled = (child:text():upper() == "TRUE")
        end
    end

    if clip_info.duration <= 0 and clip_info.source_out > clip_info.source_in then
        clip_info.duration = clip_info.source_out - clip_info.source_in
    end

    return clip_info
end

-- Parse track
local function parse_track(track_node, frame_rate, track_type, track_index, sequence_info)
    local track_info = {
        original_id = get_attr(track_node, "id"),
        type = track_type,  -- "VIDEO" or "AUDIO"
        index = track_index,
        name = string.format("%s %d", track_type, track_index),
        enabled = true,
        locked = false,
        clips = {}
    }

    local children = collect_children(track_node)
    for _, child in ipairs(children) do
        if child:name() == "clipitem" then
            -- Generate track ID (will be created in database)
            local track_id = string.format("%s%d", track_type:sub(1,1):lower(), track_index)
            local clip = parse_clipitem(child, frame_rate, track_id, sequence_info)
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
        original_id = get_attr(sequence_node, "id"),
        name = "Untitled Sequence",
        frame_rate = 30.0,
        width = 1920,
        height = 1080,
        video_tracks = {},
        audio_tracks = {},
        media_files = {}  -- Map of file_id -> media_info
    }

    local children = collect_children(sequence_node)

    -- First pass: Extract basic info and timebase
    for _, child in ipairs(children) do
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
    for _, child in ipairs(children) do
        local name = child:name()

        if name == "media" then
            -- Media contains video and audio track groups
            local video_track_index = 1
            local audio_track_index = 1

            local media_children = collect_children(child)
            for _, media_child in ipairs(media_children) do
                if media_child:name() == "video" then
                    -- Video tracks
                    local video_children = collect_children(media_child)
                    for _, video_child in ipairs(video_children) do
                        if video_child:name() == "track" then
                            local track = parse_track(video_child, sequence_info.frame_rate, "VIDEO", video_track_index, sequence_info)
                            table.insert(sequence_info.video_tracks, track)
                            video_track_index = video_track_index + 1
                        end
                    end
                elseif media_child:name() == "audio" then
                    -- Audio tracks
                    local audio_children = collect_children(media_child)
                    for _, audio_child in ipairs(audio_children) do
                        if audio_child:name() == "track" then
                            local track = parse_track(audio_child, sequence_info.frame_rate, "AUDIO", audio_track_index, sequence_info)
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
function M.import_xml(xml_path, project_id, options)
    options = options or {}
    local xml_content = options.xml_content
    local source_label = xml_path or options.source_label or "<memory>"
    local xml2 = require('xml2')
    local result = {
        success = false,
        sequences = {},
        media_files = {},
        errors = {}
    }

    -- Read and parse XML
    if not xml_content or xml_content == "" then
        if not xml_path or xml_path == "" then
            table.insert(result.errors, "No XML content or file path provided")
            return result
        end

        local file = io.open(xml_path, "r")
        if not file then
            table.insert(result.errors, string.format("Failed to open file: %s", xml_path))
            return result
        end

        xml_content = file:read("*all")
        file:close()
    end

    local doc, err = xml2.parse(xml_content)
    if not doc then
        table.insert(result.errors, string.format("Failed to parse XML (%s): %s", source_label, err or "unknown error"))
        return result
    end
    result.xml_content = xml_content

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

    for _, sequence in ipairs(result.sequences) do
        if sequence.media_files then
            for key, info in pairs(sequence.media_files) do
                if key and info then
                    result.media_files[key] = info
                end
            end
        end
    end

    result.success = true
    return result
end

-- Create JVE database entities from parsed XML
-- parsed_result: output from import_xml()
-- db: database connection
-- Returns: {success, sequence_ids, error}
function M.create_entities(parsed_result, db, project_id, replay_context)
    if not parsed_result or not parsed_result.success then
        return {success = false, error = "Import failed"}
    end

    if not project_id or project_id == "" then
        return {success = false, error = "Project ID is required"}
    end

    replay_context = replay_context or {}

    local database = require("core.database")
    local Sequence = require("models.sequence")
    local Track = require("models.track")
    local Clip = require("models.clip")
    local Media = require("models.media")

    local conn = db or database.get_connection()
    if not conn then
        return {success = false, error = "No database connection available"}
    end

    local result = {
        success = true,
        sequence_ids = {},
        track_ids = {},
        clip_ids = {},
        media_ids = {},
        sequence_id_map = {},
        track_id_map = {},
        clip_id_map = {},
        media_id_map = {}
    }

    local reuse_maps = {
        sequences = replay_context.sequence_id_map or {},
        tracks = replay_context.track_id_map or {},
        clips = replay_context.clip_id_map or {},
        media = replay_context.media_id_map or {}
    }

    local reuse_queues = {
        sequences = replay_context.sequence_ids or {},
        tracks = replay_context.created_track_ids or replay_context.track_ids or {},
        clips = replay_context.created_clip_ids or replay_context.clip_ids or {},
        media = replay_context.created_media_ids or replay_context.media_ids or {}
    }

    local reuse_indices = {
        sequences = 1,
        tracks = 1,
        clips = 1,
        media = 1
    }

    local function next_from_queue(kind)
        local queue = reuse_queues[kind]
        local idx = reuse_indices[kind]
        if queue and idx and idx <= #queue then
            local value = queue[idx]
            reuse_indices[kind] = idx + 1
            return value
        end
        return nil
    end

    local function resolve_reuse_id(kind, key)
        key = key and tostring(key) or nil
        local map = reuse_maps[kind]
        if key and map and map[key] then
            return map[key]
        end
        return next_from_queue(kind)
    end

    local media_lookup = {}
    local recorded_media_ids = {}

    local function record_media_id(key, id)
        if not key or key == "" or not id then
            return
        end
        key = tostring(key)
        media_lookup[key] = id
        if not recorded_media_ids[id] then
            recorded_media_ids[id] = true
            table.insert(result.media_ids, id)
        end
        result.media_id_map[key] = id
    end

    local function find_existing_media_id(file_path)
        if not file_path or file_path == "" then
            return nil
        end
        local stmt = conn:prepare([[SELECT id FROM media WHERE project_id = ? AND file_path = ? LIMIT 1]])
        if not stmt then
            return nil
        end
        stmt:bind_value(1, project_id)
        stmt:bind_value(2, file_path)
        local media_id = nil
        if stmt:exec() and stmt:next() then
            media_id = stmt:value(0)
        end
        stmt:finalize()
        return media_id
    end

    local function ensure_media(clip_info)
        if not clip_info then
            return nil
        end

        local key = clip_info.media_key
            or clip_info.file_id
            or clip_info.original_id
            or clip_info.name
        if key and media_lookup[key] then
            return media_lookup[key]
        end

        local media_info = nil
        if key then
            media_info = parsed_result.media_files[key]
        end
        if not media_info then
            media_info = clip_info.media
        end
        if not media_info then
            local placeholder_id = key or clip_info.original_id or uuid.generate()
            local placeholder_path = string.format("synthetic://%s", tostring(placeholder_id))
            media_info = {
                id = placeholder_id,
                name = clip_info.name or tostring(key or clip_info.original_id or "Imported Media"),
                path = placeholder_path,
                duration = clip_info.duration,
                frame_rate = clip_info.frame_rate,
                width = clip_info.width,
                height = clip_info.height,
                audio_channels = 0
            }
            print(string.format("WARNING: create_entities: missing media info for key %s; generating synthetic placeholder", tostring(key)))
        end
        if not key or key == "" then
            key = media_info.key
                or media_info.id
                or media_info.path
                or uuid.generate()
        end
        if not media_info.key then
            media_info.key = key
        end
        if clip_info.media_key ~= key then
            clip_info.media_key = key
        end
        if clip_info.media ~= media_info then
            clip_info.media = media_info
        end
        if key and not parsed_result.media_files[key] then
            parsed_result.media_files[key] = media_info
        end

        local duration = media_info.duration
        if (not duration or duration <= 0) and clip_info.duration and clip_info.duration > 0 then
            duration = clip_info.duration
        end
        if not duration or duration <= 0 then
            duration = 1
        end

        local file_path = media_info.path
        if not file_path or file_path == "" then
            file_path = string.format("synthetic://%s", tostring(key or media_info.id or uuid.generate()))
            print(string.format("WARNING: create_entities: missing file path for media %s; using placeholder %s", tostring(key), file_path))
        end

        local frame_rate = media_info.frame_rate or clip_info.frame_rate or 30.0

        local reuse_id = nil
        if key then
            reuse_id = resolve_reuse_id('media', key)
            if not reuse_id then
                reuse_id = find_existing_media_id(file_path)
            end
        end

        local media = Media.create({
            id = reuse_id,
            project_id = project_id,
            file_path = file_path,
            name = media_info.name or tostring(key or file_path),
            duration = math.floor(duration),
            frame_rate = frame_rate,
            width = media_info.width,
            height = media_info.height,
            audio_channels = media_info.audio_channels or 0
        })

        if not media then
            return nil
        end

        if not media:save(conn) then
            -- If save fails because media already exists, attempt to load it
            local existing_id = find_existing_media_id(file_path)
            if existing_id then
                record_media_id(key, existing_id)
                return existing_id
            end
            return nil
        end

        record_media_id(key, media.id)
        return media.id
    end

    local function create_clip(track_id, clip_info, clip_key)
        local media_id = ensure_media(clip_info)
        local clip = Clip.create(clip_info.name or "Clip", media_id)
        if not clip then
            return false, "Failed to allocate clip"
        end

        local reuse_id = resolve_reuse_id('clips', clip_key)
        if not reuse_id and clip_info.original_id and clip_info.original_id ~= "" then
            reuse_id = clip_info.original_id
        end
        if reuse_id then
            clip.id = reuse_id
        end

        clip.track_id = track_id
        clip.start_time = math.floor(clip_info.start_time or 0)
        clip.duration = math.max(math.floor(clip_info.duration or 0), 1)
        clip.source_in = math.floor(clip_info.source_in or 0)
        clip.source_out = math.floor(clip_info.source_out or (clip.source_in + clip.duration))
        if clip.source_out <= clip.source_in then
            clip.source_out = clip.source_in + clip.duration
        end
        clip.enabled = clip_info.enabled ~= false

        if not clip:save(conn) then
            return false, "Failed to save clip"
        end

        table.insert(result.clip_ids, clip.id)
        if clip_key then
            result.clip_id_map[tostring(clip_key)] = clip.id
        end
        return true
    end

    local function create_clip_set(sequence_key, track_key, track_id, clips)
        for clip_index, clip_info in ipairs(clips or {}) do
            local clip_key = track_key .. "::" .. (clip_info.original_id or clip_index)
            local ok, err = create_clip(track_id, clip_info, clip_key)
            if not ok then
                return false, err
            end
        end
        return true
    end

    local function create_track(sequence_key, sequence_id, track_info, kind)
        local name = track_info.name
        if not name or name == "" then
            if kind == "VIDEO" then
                name = string.format("V%d", track_info.index or 1)
            else
                name = string.format("A%d", track_info.index or 1)
            end
        end

        local track_key = sequence_key .. "::" .. (track_info.original_id or (kind .. ":" .. tostring(track_info.index)))
        local reuse_id = resolve_reuse_id('tracks', track_key)
        local opts = {
            id = reuse_id or track_info.original_id,
            index = track_info.index,
            enabled = track_info.enabled ~= false,
            locked = track_info.locked == true,
            muted = track_info.muted == true,
            soloed = track_info.soloed == true,
            db = conn
        }

        local track
        if kind == "VIDEO" then
            track = Track.create_video(name, sequence_id, opts)
        else
            track = Track.create_audio(name, sequence_id, opts)
        end

        if not track then
            return false, "Failed to allocate track"
        end

        if not track:save(conn) then
            return false, "Failed to save track"
        end

        table.insert(result.track_ids, track.id)
        result.track_id_map[track_key] = track.id

        local ok, err = create_clip_set(sequence_key, track_key, track.id, track_info.clips)
        if not ok then
            return false, err
        end

        return true
    end

    local function rollback_partial()
        for _, clip_id in ipairs(result.clip_ids or {}) do
            local stmt = conn:prepare("DELETE FROM clips WHERE id = ?")
            if stmt then
                stmt:bind_value(1, clip_id)
                stmt:exec()
                stmt:finalize()
            end
        end

        for _, track_id in ipairs(result.track_ids or {}) do
            local stmt = conn:prepare("DELETE FROM tracks WHERE id = ?")
            if stmt then
                stmt:bind_value(1, track_id)
                stmt:exec()
                stmt:finalize()
            end
        end

        for _, sequence_id in ipairs(result.sequence_ids or {}) do
            local stmt = conn:prepare("DELETE FROM sequences WHERE id = ?")
            if stmt then
                stmt:bind_value(1, sequence_id)
                stmt:exec()
                stmt:finalize()
            end
        end

        for _, media_id in ipairs(result.media_ids or {}) do
            local stmt = conn:prepare("DELETE FROM media WHERE id = ?")
            if stmt then
                stmt:bind_value(1, media_id)
                stmt:exec()
                stmt:finalize()
            end
        end
    end

    local ok, err = pcall(function()
        for seq_index, seq_info in ipairs(parsed_result.sequences or {}) do
            local sequence_key = seq_info.original_id or ("sequence_" .. tostring(seq_index))
            local reuse_id = resolve_reuse_id('sequences', sequence_key)
            local sequence = Sequence.create(
                seq_info.name,
                project_id,
                seq_info.frame_rate,
                seq_info.width,
                seq_info.height,
                {id = reuse_id or seq_info.original_id}
            )
            if not sequence then
                error("Failed to allocate sequence")
            end

            if not sequence:save(conn) then
                error("Failed to save sequence")
            end

            table.insert(result.sequence_ids, sequence.id)
            result.sequence_id_map[sequence_key] = sequence.id

            for track_index, track_info in ipairs(seq_info.video_tracks or {}) do
                local success, track_err = create_track(sequence_key, sequence.id, track_info, "VIDEO")
                if not success then
                    error(track_err)
                end
            end

            for track_index, track_info in ipairs(seq_info.audio_tracks or {}) do
                local success, track_err = create_track(sequence_key, sequence.id, track_info, "AUDIO")
                if not success then
                    error(track_err)
                end
            end
        end
    end)

    if not ok then
        rollback_partial()
        return {success = false, error = err}
    end

    return result
end

return M
