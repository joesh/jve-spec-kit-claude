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

local lxp = require("lxp")  -- LuaExpat XML parser

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
local function parse_xml_file(xml_path)
    local file = io.open(xml_path, "r")
    if not file then
        return nil, "Failed to open XML file: " .. xml_path
    end

    local content = file:read("*all")
    file:close()

    -- Simple XML parser state machine
    local stack = {{tag = "root", children = {}, attrs = {}}}
    local current = stack[1]

    local parser = lxp.new({
        StartElement = function(parser, name, attrs)
            local elem = {tag = name, attrs = attrs, children = {}, text = ""}
            table.insert(current.children, elem)
            table.insert(stack, elem)
            current = elem
        end,
        EndElement = function(parser, name)
            table.remove(stack)
            current = stack[#stack]
        end,
        CharacterData = function(parser, text)
            if current then
                current.text = current.text .. text
            end
        end
    })

    local success, err = parser:parse(content)
    if not success then
        return nil, "XML parse error: " .. tostring(err)
    end

    parser:parse()  -- Finalize parsing
    parser:close()

    return stack[1], nil
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
    if not timecode_str or timecode_str == "" then
        return 0
    end

    -- Handle rational notation (frames/divisor)
    local numerator, denominator = timecode_str:match("^(%d+)/(%d+)$")
    if numerator and denominator then
        local frames = tonumber(numerator)
        local divisor = tonumber(denominator)
        return math.floor((frames / divisor) * (1000.0 / frame_rate))
    end

    -- Handle absolute frame count
    local frames = tonumber(timecode_str)
    if frames then
        return math.floor(frames * (1000.0 / frame_rate))
    end

    return 0
end

--- Parse project.xml to extract project metadata
-- @param project_elem table: XML element for <Project>
-- @return table: Project metadata
local function parse_project_metadata(project_elem)
    local name_elem = find_element(project_elem, "Name")
    local settings_elem = find_element(project_elem, "ProjectSettings")

    local project = {
        name = name_elem and get_text(name_elem) or "Untitled Project",
        settings = {}
    }

    if settings_elem then
        local frame_rate_elem = find_element(settings_elem, "TimelineFrameRate")
        local width_elem = find_element(settings_elem, "TimelineResolutionWidth")
        local height_elem = find_element(settings_elem, "TimelineResolutionHeight")

        project.settings.frame_rate = frame_rate_elem and tonumber(get_text(frame_rate_elem)) or 30.0
        project.settings.width = width_elem and tonumber(get_text(width_elem)) or 1920
        project.settings.height = height_elem and tonumber(get_text(height_elem)) or 1080
    end

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

    local start_time = parse_resolve_timecode(get_text(start_elem), frame_rate)
    local end_time = parse_resolve_timecode(get_text(end_elem), frame_rate)
    local source_in = in_elem and parse_resolve_timecode(get_text(in_elem), frame_rate) or 0
    local source_out = out_elem and parse_resolve_timecode(get_text(out_elem), frame_rate) or 0

    local clip = {
        name = name_elem and get_text(name_elem) or "Untitled Clip",
        start_time = start_time,
        duration = end_time - start_time,
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
    local seq_files = io.popen("ls " .. seq_dir .. "/*.xml 2>/dev/null"):read("*all")
    for seq_file in seq_files:gmatch("[^\n]+") do
        local seq_root, err = parse_xml_file(seq_file)
        if seq_root then
            local seq_elem = find_element(seq_root, "Sequence")
            if seq_elem then
                local timeline = parse_sequence(seq_elem, project.settings.frame_rate)
                table.insert(timelines, timeline)
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
