--- DaVinci Resolve .drp Project Importer
-- Parses Resolve's .drp export format (ZIP archive with XML files)
--
-- Format structure:
--   .drp file = ZIP archive containing:
--     - project.xml (project settings, users, timeline list)
--     - MediaPool/Master/MpFolder.xml (media bin organization)
--     - SeqContainer/*.xml (timeline sequences with tracks/clips)
--
-- Usage:
--   local drp_importer = require("importers.drp_importer")
--   local result = drp_importer.parse_drp_file("/path/to/project.drp")
--   if result.success then
--     print("Imported: " .. result.project.name)
--   end

local M = {}

local xml2 = require("xml2")
local Rational = require("core.rational")

--- Unzip .drp file to temporary directory
-- @param drp_path string: Path to .drp file
-- @return string|nil: Temp directory path, or nil on error
-- @return string|nil: Error message if failed
local function extract_drp(drp_path)
    local tmp_dir = os.tmpname()
    os.remove(tmp_dir)  -- Remove the file, we want a directory
    os.execute("mkdir -p " .. tmp_dir)

    local cmd = string.format('unzip -q "%s" -d "%s"', drp_path, tmp_dir)
    local result = os.execute(cmd)

    if result ~= 0 then
        return nil, "Failed to extract .drp archive"
    end

    return tmp_dir, nil
end

--- Parse XML file using LuaExpat
-- @param xml_path string: Path to XML file
-- @return table|nil: Parsed XML structure, or nil on error
-- @return string|nil: Error message if failed
local function convert_node(node)
    if not node then
        return nil
    end

    local element = {
        tag = node:name(),
        attrs = node:attributes(),
        children = {},
        text = node:text()
    }

    for child in node:children() do
        local converted = convert_node(child)
        if converted then
            table.insert(element.children, converted)
        end
    end

    return element
end

local function parse_xml_file(xml_path)
    local file = io.open(xml_path, "r")
    if not file then
        return nil, "Failed to open XML file: " .. xml_path
    end

    local content = file:read("*all")
    file:close()

    local doc, err = xml2.parse(content)
    if not doc then
        return nil, "XML parse error: " .. tostring(err)
    end

    local root = doc:root()
    if not root then
        return nil, "XML document has no root element"
    end

    return convert_node(root), nil
end

--- Find XML element by tag name (recursive search)
-- @param elem table: XML element to search
-- @param tag_name string: Tag name to find
-- @return table|nil: First matching element, or nil if not found
local function find_element(elem, tag_name)
    if elem.tag == tag_name then
        return elem
    end

    for _, child in ipairs(elem.children) do
        local found = find_element(child, tag_name)
        if found then return found end
    end

    return nil
end

--- Find all XML elements by tag name (recursive search)
-- @param elem table: XML element to search
-- @param tag_name string: Tag name to find
-- @return table: Array of matching elements
local function find_all_elements(elem, tag_name)
    local results = {}

    if elem.tag == tag_name then
        table.insert(results, elem)
    end

    for _, child in ipairs(elem.children) do
        local found = find_all_elements(child, tag_name)
        for _, item in ipairs(found) do
            table.insert(results, item)
        end
    end

    return results
end

--- Get text content from XML element
-- @param elem table: XML element
-- @return string: Trimmed text content
local function get_text(elem)
    if not elem then return "" end
    return elem.text:match("^%s*(.-)%s*$")  -- Trim whitespace
end

--- Parse Resolve timecode string to milliseconds
-- Resolve uses rational notation: "900/30" = frame 900 at 30fps
-- @param timecode_str string: Timecode string (e.g., "900/30")
-- @param frame_rate number: Timeline frame rate
-- @return number: Milliseconds
local function parse_resolve_timecode(timecode_str, frame_rate)
    local fps_num = math.floor(frame_rate * 1000)
    local fps_den = 1000

    if not timecode_str or timecode_str == "" then
        return Rational.new(0, fps_num, fps_den)
    end

    -- Handle rational notation (frames/divisor)
    local numerator, denominator = timecode_str:match("^(%d+)/(%d+)$")
    if numerator and denominator then
        local frames = tonumber(numerator)
        local divisor = tonumber(denominator)
        -- Resolve's rational format means: frames @ divisor FPS.
        -- We need to convert this to our internal fps_num/fps_den
        local temp_rational = Rational.new(frames, divisor, 1)
        return temp_rational:rescale(fps_num, fps_den)
    end

    -- Handle absolute frame count
    local frames = tonumber(timecode_str)
    if frames then
        return Rational.new(frames, fps_num, fps_den)
    end

    return Rational.new(0, fps_num, fps_den)
end

local function frames_to_rational(frames, frame_rate)
    local fr = frame_rate or 30.0
    if fr <= 0 then
        fr = 30.0
    end
    local fps_num = math.floor(fr * 1000)
    local fps_den = 1000
    return Rational.new(frames, fps_num, fps_den)
end

--- Parse project.xml to extract project metadata
-- @param project_elem table: XML element for <Project>
-- @return table: Project metadata
local function parse_project_metadata(project_elem)
    local project = {
        name = "Untitled Project",
        settings = {}
    }

    if not project_elem then
        project.settings.frame_rate = 30.0
        project.settings.width = 1920
        project.settings.height = 1080
        return project
    end

    local name_elem = find_element(project_elem, "ProjectName") or find_element(project_elem, "Name")
    if name_elem then
        local name = get_text(name_elem)
        if name and name ~= "" then
            project.name = name
        end
    end

    local function numeric_from(elem, default)
        if not elem then
            return default
        end
        local value = tonumber(get_text(elem))
        return value or default
    end

    local frame_rate_elem = find_element(project_elem, "TimelineFrameRate")
    local width_elem = find_element(project_elem, "TimelineResolutionWidth")
    local height_elem = find_element(project_elem, "TimelineResolutionHeight")

    if not frame_rate_elem or not width_elem or not height_elem then
        local settings_elem = find_element(project_elem, "ProjectSettings")
        if settings_elem then
            frame_rate_elem = frame_rate_elem or find_element(settings_elem, "TimelineFrameRate")
            width_elem = width_elem or find_element(settings_elem, "TimelineResolutionWidth")
            height_elem = height_elem or find_element(settings_elem, "TimelineResolutionHeight")
        end
    end

    project.settings.frame_rate = numeric_from(frame_rate_elem, 30.0)
    project.settings.width = numeric_from(width_elem, 1920)
    project.settings.height = numeric_from(height_elem, 1080)

    return project
end

--- Parse MediaPool XML to extract media items
-- @param media_pool_elem table: XML element for <MediaPool>
-- @return table: Array of media items
local function parse_media_pool(media_pool_elem)
    local media_items = {}

    local clips = find_all_elements(media_pool_elem, "Clip")
    for _, clip_elem in ipairs(clips) do
        local name_elem = find_element(clip_elem, "Name")
        local file_elem = find_element(clip_elem, "File")
        local duration_elem = find_element(clip_elem, "Duration")

        local media_item = {
            name = name_elem and get_text(name_elem) or "Untitled",
            file_path = file_elem and get_text(file_elem) or "",
            duration = duration_elem and tonumber(get_text(duration_elem)) or 0
        }

        -- Extract media ID if present
        if clip_elem.attrs and clip_elem.attrs.id then
            media_item.resolve_id = clip_elem.attrs.id
        end

        table.insert(media_items, media_item)
    end

    return media_items
end

local function parse_resolve_tracks(seq_elem, frame_rate)
    local video_tracks = {}
    local audio_tracks = {}
    local media_lookup = {}
    local video_index = 1
    local audio_index = 1

    local track_elements = find_all_elements(seq_elem, "Sm2TiTrack")
    for _, track_elem in ipairs(track_elements) do
        local type_value = tonumber(get_text(find_element(track_elem, "Type"))) or 0
        local track_type = (type_value == 1) and "AUDIO" or "VIDEO"
        local track_index = track_type == "AUDIO" and audio_index or video_index
        local track_info = {
            type = track_type,
            index = track_index,
            name = string.format("%s %d", track_type, track_index),
            enabled = true,
            locked = false,
            clips = {}
        }

        local clip_tag = track_type == "AUDIO" and "Sm2TiAudioClip" or "Sm2TiVideoClip"
        local clip_elements = find_all_elements(track_elem, clip_tag)
        local clip_count = 0

        for _, clip_elem in ipairs(clip_elements) do
            local file_path = get_text(find_element(clip_elem, "MediaFilePath"))
            local start_frames = tonumber(get_text(find_element(clip_elem, "Start"))) or 0
            local duration_frames = tonumber(get_text(find_element(clip_elem, "Duration"))) or 0
            local media_start_frames = tonumber(get_text(find_element(clip_elem, "MediaStartTime"))) or 0

            local clip = {
                name = get_text(find_element(clip_elem, "Name")),
                start_value = frames_to_rational(start_frames, frame_rate),
                duration = frames_to_rational(duration_frames, frame_rate),
                source_in = frames_to_rational(media_start_frames, frame_rate),
                enabled = get_text(find_element(clip_elem, "WasDisbanded")) ~= "true",
                file_path = file_path,
                media_key = file_path,
                file_id = get_text(find_element(clip_elem, "MediaRef")),
                frame_rate = frame_rate
            }

            if clip.duration.frames <= 0 then
                -- Ensure duration is at least 1 frame
                clip.duration = Rational.new(1, clip.duration.fps_numerator, clip.duration.fps_denominator)
            end

            clip.source_out = clip.source_in + clip.duration

            table.insert(track_info.clips, clip)
            clip_count = clip_count + 1

            if file_path and file_path ~= "" and not media_lookup[file_path] then
                media_lookup[file_path] = {
                    id = clip.file_id,
                    name = clip.name or file_path,
                    path = file_path,
                    duration = clip.duration,
                    frame_rate = frame_rate,
                    width = 1920,
                    height = 1080,
                    audio_channels = track_type == "AUDIO" and 2 or 0,
                    key = file_path
                }
            end
        end

        if clip_count > 0 then
            if track_type == "AUDIO" then
                table.insert(audio_tracks, track_info)
                audio_index = audio_index + 1
            else
                table.insert(video_tracks, track_info)
                video_index = video_index + 1
            end
        end
    end

    return video_tracks, audio_tracks, media_lookup
end

--- Parse sequence XML to extract timeline data
-- @param seq_elem table: XML element for <Sequence>
-- @param frame_rate number: Project frame rate
-- @return table: Timeline data
local function parse_sequence(seq_elem, frame_rate)
    local name_elem = find_element(seq_elem, "Name")
    local duration_elem = find_element(seq_elem, "Duration")

    local timeline = {
        name = name_elem and get_text(name_elem) or "Untitled Timeline",
        duration = duration_elem and tonumber(get_text(duration_elem)) or 0,
        tracks = {}
    }

    -- Parse video tracks
    local video_tracks = find_all_elements(seq_elem, "VideoTrack")
    for i, track_elem in ipairs(video_tracks) do
        local track = {
            type = "VIDEO",
            index = i,
            clips = {}
        }

        local clip_items = find_all_elements(track_elem, "ClipItem")
        for _, clip_elem in ipairs(clip_items) do
            local clip = parse_clip_item(clip_elem, frame_rate)
            if clip then
                table.insert(track.clips, clip)
            end
        end

        table.insert(timeline.tracks, track)
    end

    -- Parse audio tracks
    local audio_tracks = find_all_elements(seq_elem, "AudioTrack")
    for i, track_elem in ipairs(audio_tracks) do
        local track = {
            type = "AUDIO",
            index = i,
            clips = {}
        }

        local clip_items = find_all_elements(track_elem, "ClipItem")
        for _, clip_elem in ipairs(clip_items) do
            local clip = parse_clip_item(clip_elem, frame_rate)
            if clip then
                table.insert(track.clips, clip)
            end
        end

        table.insert(timeline.tracks, track)
    end

    if #timeline.tracks == 0 then
        local resolve_video_tracks, resolve_audio_tracks, media_map = parse_resolve_tracks(seq_elem, frame_rate)
        timeline.media_files = media_map

        for _, track in ipairs(resolve_video_tracks) do
            table.insert(timeline.tracks, track)
        end
        for _, track in ipairs(resolve_audio_tracks) do
            table.insert(timeline.tracks, track)
        end
    end

    if #timeline.tracks == 0 then
        local fallback_clips = {}
        local media_nodes = find_all_elements(seq_elem, "MediaFilePath")
        for _, node in ipairs(media_nodes) do
            local path = get_text(node)
            if path and path ~= "" then
                local clip = {
                    name = path:match("([^/\\]+)$") or path,
                    start_value = 0,
                    duration = 1000,
                    source_in = 0,
                    source_out = 1000,
                    file_path = path,
                    media_key = path,
                    frame_rate = frame_rate
                }
                table.insert(fallback_clips, clip)
            end
        end

        if #fallback_clips > 0 then
            local fps_num = math.floor(frame_rate * 1000)
            local fps_den = 1000
            local zero_rational = Rational.new(0, fps_num, fps_den)
            local default_duration_rational = Rational.new(1000, fps_num, fps_den)

            timeline.tracks = {
                {
                    type = "VIDEO",
                    index = 1,
                    name = "VIDEO 1",
                    enabled = true,
                    locked = false,
                    clips = fallback_clips
                }
            }
            timeline.media_files = timeline.media_files or {}
            for _, clip in ipairs(fallback_clips) do
                -- Ensure Rational types are correctly initialized in fallback clips
                clip.start_value = clip.start_value or zero_rational
                clip.duration = clip.duration or default_duration_rational
                clip.source_in = clip.source_in or zero_rational
                clip.source_out = clip.source_out or default_duration_rational

                if clip.media_key and not timeline.media_files[clip.media_key] then
                    timeline.media_files[clip.media_key] = {
                        name = clip.name,
                        path = clip.media_key,
                        duration = clip.duration, -- Use Rational duration
                        frame_rate = frame_rate,
                        width = 1920,
                        height = 1080,
                        audio_channels = 0,
                        key = clip.media_key
                    }
                end
            end
        end
    end

    return timeline
end

--- Parse ClipItem XML to extract clip data
-- @param clip_elem table: XML element for <ClipItem>
-- @param frame_rate number: Timeline frame rate
-- @return table|nil: Clip data, or nil if invalid
local function parse_clip_item(clip_elem, frame_rate)
    local name_elem = find_element(clip_elem, "Name")
    local start_elem = find_element(clip_elem, "Start")
    local end_elem = find_element(clip_elem, "End")
    local in_elem = find_element(clip_elem, "In")
    local out_elem = find_element(clip_elem, "Out")

    if not start_elem or not end_elem then
        return nil  -- Invalid clip
    end

    local start_value = parse_resolve_timecode(get_text(start_elem), frame_rate)
    local end_time = parse_resolve_timecode(get_text(end_elem), frame_rate)
    
    local fps_num = math.floor(frame_rate * 1000)
    local fps_den = 1000

    local source_in = in_elem and parse_resolve_timecode(get_text(in_elem), frame_rate) or Rational.new(0, fps_num, fps_den)
    local source_out = out_elem and parse_resolve_timecode(get_text(out_elem), frame_rate) or Rational.new(0, fps_num, fps_den)

    local clip = {
        name = name_elem and get_text(name_elem) or "Untitled Clip",
        start_value = start_value,
        duration = end_time - start_value,
        source_in = source_in,
        source_out = source_out
    }

    -- Extract media reference if present
    local file_elem = find_element(clip_elem, "File")
    if file_elem then
        local pathurl_elem = find_element(file_elem, "PathURL")
        if pathurl_elem then
            clip.file_path = get_text(pathurl_elem)
        end
    end

    return clip
end

--- Main entry point: Parse .drp file
-- @param drp_path string: Path to .drp file
-- @return table: Result with success flag and parsed data
--   {
--     success = true/false,
--     error = "error message" (if failed),
--     project = { name, settings },
--     media_items = { {name, file_path, duration}, ... },
--     timelines = { {name, duration, tracks}, ... }
--   }
function M.parse_drp_file(drp_path)
    -- Extract .drp archive
    local tmp_dir, err = extract_drp(drp_path)
    if not tmp_dir then
        return {success = false, error = err}
    end

    -- Parse project.xml
    local project_xml_path = tmp_dir .. "/project.xml"
    local project_root, err = parse_xml_file(project_xml_path)
    if not project_root then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "Failed to parse project.xml: " .. tostring(err)}
    end

    local project_elem = find_element(project_root, "Project")
    if not project_elem then
        if project_root.tag == "SM_Project" or project_root.tag == "Project" then
            project_elem = project_root
        else
            project_elem = find_element(project_root, "SM_Project")
        end
    end

    if not project_elem then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "No <Project> element found in project.xml"}
    end

    local project = parse_project_metadata(project_elem)

    -- Parse MediaPool XML
    local media_pool_path = tmp_dir .. "/MediaPool/Master/MpFolder.xml"
    local media_items = {}
    local media_pool_root, err = parse_xml_file(media_pool_path)
    if media_pool_root then
        media_items = parse_media_pool(media_pool_root)
    end

    -- Parse sequence XMLs
    local timelines = {}
    local seq_dir = tmp_dir .. "/SeqContainer"
    local seq_files_raw = io.popen("ls " .. seq_dir .. "/*.xml 2>/dev/null")
    local sequence_file_list = {}
    local seq_files = ""
    if seq_files_raw then
        seq_files = seq_files_raw:read("*all")
        seq_files_raw:close()
    end

    for seq_file in seq_files:gmatch("[^\n]+") do
        table.insert(sequence_file_list, seq_file)
        local seq_root, err = parse_xml_file(seq_file)
        if seq_root then
            local seq_elem = find_element(seq_root, "Sequence")
            if seq_elem then
                local has_classic_tracks = find_element(seq_elem, "VideoTrack") or find_element(seq_elem, "AudioTrack")
                local has_resolve_tracks = find_element(seq_elem, "Sm2TiTrack")
                if not has_classic_tracks and not has_resolve_tracks then
                    seq_elem = find_element(seq_root, "Sm2SequenceContainer") or seq_root
                end
            else
                seq_elem = find_element(seq_root, "Sm2SequenceContainer") or seq_root
            end
            if seq_elem then
                local timeline = parse_sequence(seq_elem, project.settings.frame_rate)
                table.insert(timelines, timeline)
            end
        end
    end

    local media_lookup = {}
    for _, item in ipairs(media_items) do
        if item.file_path and item.file_path ~= "" then
            media_lookup[item.file_path] = item
        end
    end

    for _, timeline in ipairs(timelines) do
        if timeline.media_files then
            for key, info in pairs(timeline.media_files) do
                local path = info.path or key
                if path and path ~= "" and not media_lookup[path] then
                    local entry = {
                        name = info.name or path,
                        file_path = path,
                        duration = info.duration or 0,
                        resolve_id = info.id
                    }
                    table.insert(media_items, entry)
                    media_lookup[path] = entry
                end
            end
        end
    end

    for _, seq_file in ipairs(sequence_file_list) do
        local handle = io.open(seq_file, "r")
        if handle then
            local content = handle:read("*all")
            handle:close()
            for raw_path in content:gmatch("<MediaFilePath>(.-)</MediaFilePath>") do
                local cleaned = raw_path:match("^%s*(.-)%s*$")
                if cleaned ~= "" and not media_lookup[cleaned] then
                    local entry = {
                        name = cleaned:match("([^/\\]+)$") or cleaned,
                        file_path = cleaned,
                        duration = 0
                    }
                    table.insert(media_items, entry)
                    media_lookup[cleaned] = entry
                end
            end
        end
    end

    -- Cleanup temp directory
    os.execute("rm -rf " .. tmp_dir)

    return {
        success = true,
        project = project,
        media_items = media_items,
        timelines = timelines
    }
end

return M
