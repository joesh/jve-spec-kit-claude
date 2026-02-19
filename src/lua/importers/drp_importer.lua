--- DaVinci Resolve .drp Importer — parse, convert, and import
--
-- Responsibilities:
-- - parse_drp_file(): Parse .drp ZIP archive to structured Lua tables
-- - show_conversion_dialog(): Modal dialog to choose save location
-- - convert(): Parse .drp and create new .jvp database (Open verb)
-- - import_into_project(): Import parsed DRP data into existing project (Import verb)
--
-- Non-goals:
-- - Opening the converted project (caller handles that)
-- - Resolve DB peer mode (that's direct open, not conversion)
--
-- Invariants:
-- - Conversion creates a NEW .jvp file (never modifies existing)
-- - All media items use duration_frames (not duration in ms)
-- - fps MUST come from DRP metadata — no silent fallbacks
--
-- @file drp_importer.lua
local M = {}

local xml2 = require("xml2")
local logger = require("core.logger")

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

--- Find direct child element by tag name (non-recursive)
-- Use this for properties that belong to the element itself (Name, Duration, etc.)
-- @param elem table: XML element to search
-- @param tag_name string: Tag name to find
-- @return table|nil: First matching direct child, or nil if not found
local function find_direct_child(elem, tag_name)
    if not elem or not elem.children then return nil end

    for _, child in ipairs(elem.children) do
        if child.tag == tag_name then
            return child
        end
    end

    return nil
end

--- Find XML element by tag name (recursive search)
-- Use this for finding nested structures (tracks, clips, etc.)
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

--- Find top-level clips within an Sm2TiTrack element.
-- DRP structure: Track > Items > Element > Sm2TiVideoClip/Sm2TiAudioClip
-- Must NOT recurse into clip internals (Fusion/compound clips nest source clips inside)
--
-- TODO: Nested clips (Fusion comps, compound clips) contain source material refs inside
-- the parent clip. We currently ignore these. To properly import them we'd need to:
--   1. Detect nested Sm2TiVideoClip/Sm2TiAudioClip within a parent clip
--   2. Determine if the parent is a compound clip or Fusion comp
--   3. Import the parent as a single clip (the rendered result)
--   4. Optionally import the nested structure as a compound clip sequence
--
-- @param track_elem table: Sm2TiTrack element
-- @param clip_tag string: "Sm2TiVideoClip" or "Sm2TiAudioClip"
-- @return table: Array of clip elements at the Items/Element level only
local function find_track_clips(track_elem, clip_tag)
    local results = {}
    local items = find_direct_child(track_elem, "Items")
    if not items then return results end

    for _, wrapper in ipairs(items.children) do
        -- Each Element wrapper contains one clip
        if wrapper.tag == "Element" then
            for _, child in ipairs(wrapper.children) do
                if child.tag == clip_tag then
                    table.insert(results, child)
                end
            end
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

--- Decode a big-endian IEEE 754 double from hex string at given offset
-- @param hex_str string: Hex string containing doubles
-- @param offset number: Character offset (0 = first double, 16 = second double)
-- @return number|nil: Decoded double value, or nil if invalid
local function decode_hex_double_at(hex_str, offset)
    if not hex_str or #hex_str < offset + 16 then return nil end

    local ffi = require("ffi")

    -- Parse 16 hex chars (8 bytes) into byte array starting at offset
    -- DRP stores doubles in little-endian byte order (x86 native), no reversal needed
    local bytes = ffi.new("uint8_t[8]")
    for i = 0, 7 do
        local hex_byte = hex_str:sub(offset + i * 2 + 1, offset + i * 2 + 2)
        local byte_val = tonumber(hex_byte, 16)
        if not byte_val then return nil end
        bytes[i] = byte_val
    end

    -- Cast directly to double (already little-endian)
    local double_ptr = ffi.cast("double*", bytes)
    return double_ptr[0]
end

--- Decode a big-endian IEEE 754 double from 16-char hex string
-- DRP stores fps/resolution as 128-bit hex: two doubles, we take the first
-- Example: "00000000000038400000000000000000" = 24.0 (fps)
-- @param hex_str string: 32-char hex string (first 16 chars used)
-- @return number|nil: Decoded double value, or nil if invalid
local function decode_hex_double(hex_str)
    return decode_hex_double_at(hex_str, 0)
end

--- Decode resolution from 32-char hex string (two doubles: width, height)
-- Example: "00000000000087400000000000e08640" = 1920×1080
-- @param hex_str string: 32-char hex string
-- @return number|nil, number|nil: width, height (or nil if invalid)
local function decode_hex_resolution(hex_str)
    if not hex_str or #hex_str < 32 then return nil, nil end
    local width = decode_hex_double_at(hex_str, 0)
    local height = decode_hex_double_at(hex_str, 16)
    return width, height
end

--- Parse Resolve timecode string to integer frames
-- Resolve uses rational notation: "900/30" = frame 900 at 30fps
-- @param timecode_str string: Timecode string (e.g., "900/30")
-- @param frame_rate number: Timeline frame rate
-- @return number: Integer frames at sequence frame rate
local function parse_resolve_timecode(timecode_str, frame_rate)
    if not timecode_str or timecode_str == "" then
        return 0
    end

    -- Handle rational notation (frames/divisor)
    local numerator, denominator = timecode_str:match("^(%d+)/(%d+)$")
    if numerator and denominator then
        local src_frames = tonumber(numerator)
        local src_fps = tonumber(denominator)
        -- Resolve's rational format means: src_frames @ src_fps FPS.
        -- Rescale to sequence fps: (src_frames / src_fps) * frame_rate
        return math.floor(src_frames * frame_rate / src_fps + 0.5)
    end

    -- Handle absolute frame count
    local frames = tonumber(timecode_str)
    if frames then
        return math.floor(frames + 0.5)
    end

    return 0
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
        -- No <Project> element — will be overridden by fps inference in converter.
        -- Use nil to signal "unknown"; converter must infer or fail.
        project.settings.frame_rate = nil
        project.settings.width = 1920
        project.settings.height = 1080
        return project
    end

    -- Use find_direct_child for project-level properties to avoid nested elements
    local name_elem = find_direct_child(project_elem, "ProjectName") or find_direct_child(project_elem, "Name")
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

    -- Look for timeline settings as direct children first, then fall back to recursive
    local frame_rate_elem = find_direct_child(project_elem, "TimelineFrameRate") or find_element(project_elem, "TimelineFrameRate")
    local width_elem = find_direct_child(project_elem, "TimelineResolutionWidth") or find_element(project_elem, "TimelineResolutionWidth")
    local height_elem = find_direct_child(project_elem, "TimelineResolutionHeight") or find_element(project_elem, "TimelineResolutionHeight")

    if not frame_rate_elem or not width_elem or not height_elem then
        local settings_elem = find_element(project_elem, "ProjectSettings")
        if settings_elem then
            frame_rate_elem = frame_rate_elem or find_element(settings_elem, "TimelineFrameRate")
            width_elem = width_elem or find_element(settings_elem, "TimelineResolutionWidth")
            height_elem = height_elem or find_element(settings_elem, "TimelineResolutionHeight")
        end
    end

    if frame_rate_elem then
        local fr = tonumber(get_text(frame_rate_elem))
        assert(fr, string.format(
            "parse_project_metadata: <TimelineFrameRate> is not numeric: '%s'",
            tostring(get_text(frame_rate_elem))))
        project.settings.frame_rate = fr
    else
        -- No frame rate in project element — converter will infer from clip positions
        project.settings.frame_rate = nil
    end
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

-- ---------------------------------------------------------------------------
-- MediaPool Folder/Bin Hierarchy Parsing
-- ---------------------------------------------------------------------------
--
-- Resolve's MediaPool stores master clips in a folder hierarchy:
--
--   MediaPool/Master/MpFolder.xml              → Root "Master" folder
--   MediaPool/Master/000_02 Footage/MpFolder.xml → "02 Footage" subfolder
--   MediaPool/Master/001_03 Sound/MpFolder.xml   → "03 Sound" subfolder
--
-- Each MpFolder.xml contains:
--   <Sm2MpFolder DbId="...">
--     <Name>Folder Name</Name>
--     <MpFolder>parent-folder-id</MpFolder>   (reference to parent)
--     <MediaVec>
--       <Element><Sm2MpVideoClip>...</Sm2MpVideoClip></Element>
--       <Element><Sm2MpAudioClip>...</Sm2MpAudioClip></Element>
--     </MediaVec>
--   </Sm2MpFolder>
--
-- Master clips have marks and media references:
--   <Sm2MpVideoClip DbId="...">
--     <Name>Clip Name</Name>
--     <MpFolder>parent-folder-id</MpFolder>
--     <MarkIn>frame-value</MarkIn>
--     <MarkOut>frame-value</MarkOut>
--     <CurPlayheadPosition>frame-value</CurPlayheadPosition>
--     <Video><BtVideoInfo>...</BtVideoInfo></Video>
--   </Sm2MpVideoClip>

--- Parse a master clip element (Sm2MpVideoClip or Sm2MpAudioClip)
-- @param clip_elem table: XML element for master clip
-- @param folder_id string: Parent folder ID
-- @return table: Master clip data
local function parse_master_clip_element(clip_elem, folder_id)
    local db_id = clip_elem.attrs and clip_elem.attrs.DbId
    if not db_id then return nil end

    local name_elem = find_direct_child(clip_elem, "Name")
    local mark_in_elem = find_direct_child(clip_elem, "MarkIn")
    local mark_out_elem = find_direct_child(clip_elem, "MarkOut")
    local playhead_elem = find_direct_child(clip_elem, "CurPlayheadPosition")

    -- TODO: Extract file path from Video/BtVideoInfo or embedded audio
    -- Video clips have path encoded in Clip field (binary) - we'll match by name later
    -- For now, we rely on the name matching the media file

    -- TODO: Parse duration from Video/BtVideoInfo/Time if available

    local master_clip = {
        id = db_id,
        name = name_elem and get_text(name_elem) or "Untitled",
        folder_id = folder_id,
        mark_in = mark_in_elem and tonumber(get_text(mark_in_elem)) or nil,
        mark_out = mark_out_elem and tonumber(get_text(mark_out_elem)) or nil,
        playhead = playhead_elem and tonumber(get_text(playhead_elem)) or nil,
        clip_type = clip_elem.tag == "Sm2MpVideoClip" and "video" or "audio",
    }

    return master_clip
end

--- Parse a single MpFolder.xml file
-- @param mp_file_path string: Path to MpFolder.xml
-- @param parent_folder_path string: Filesystem parent path (for deriving hierarchy)
-- @return table: { folder = {...}, master_clips = {...} }
local function parse_mp_folder_file(mp_file_path, parent_folder_path)
    local mp_root = parse_xml_file(mp_file_path)
    if not mp_root then
        return { folder = nil, master_clips = {} }
    end

    local result = { folder = nil, master_clips = {} }

    -- Find the Sm2MpFolder element
    local folder_elem = find_element(mp_root, "Sm2MpFolder")
    if folder_elem then
        local db_id = folder_elem.attrs and folder_elem.attrs.DbId
        local name_elem = find_direct_child(folder_elem, "Name")
        local parent_ref_elem = find_direct_child(folder_elem, "MpFolder")
        local color_elem = find_direct_child(folder_elem, "ColorTag")

        result.folder = {
            id = db_id,
            name = name_elem and get_text(name_elem) or "Untitled",
            parent_ref = parent_ref_elem and get_text(parent_ref_elem) or nil,
            color = color_elem and get_text(color_elem) or nil,
            path = parent_folder_path,
        }

        -- Find master clips in MediaVec
        local media_vec = find_direct_child(folder_elem, "MediaVec")
        if media_vec then
            for _, element in ipairs(media_vec.children or {}) do
                if element.tag == "Element" then
                    for _, child in ipairs(element.children or {}) do
                        if child.tag == "Sm2MpVideoClip" or child.tag == "Sm2MpAudioClip" then
                            local master_clip = parse_master_clip_element(child, db_id)
                            if master_clip then
                                table.insert(result.master_clips, master_clip)
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end

--- Parse full MediaPool hierarchy recursively
-- @param tmp_dir string: Extracted .drp temp directory
-- @return table: { folders = {...}, master_clips = {...}, folder_map = {...} }
local function parse_media_pool_hierarchy(tmp_dir)
    local folders = {}
    local master_clips = {}
    local folder_map = {}  -- id -> folder

    -- Find all MpFolder.xml files recursively
    local find_cmd = string.format('find "%s/MediaPool" -name "MpFolder.xml" 2>/dev/null', tmp_dir)
    local find_handle = io.popen(find_cmd)
    if not find_handle then
        return { folders = folders, master_clips = master_clips, folder_map = folder_map }
    end

    local mp_files = find_handle:read("*all")
    find_handle:close()

    -- Parse each MpFolder.xml
    for mp_file in mp_files:gmatch("[^\n]+") do
        -- Derive parent path from file location
        local parent_path = mp_file:match("^(.+)/MpFolder%.xml$") or ""
        local relative_path = parent_path:gsub(tmp_dir .. "/MediaPool/Master/?", "")

        local parsed = parse_mp_folder_file(mp_file, relative_path)

        if parsed.folder then
            table.insert(folders, parsed.folder)
            folder_map[parsed.folder.id] = parsed.folder
        end

        for _, clip in ipairs(parsed.master_clips) do
            table.insert(master_clips, clip)
        end
    end

    -- Resolve parent relationships using folder_map
    -- Each folder has parent_ref pointing to parent's DbId
    for _, folder in ipairs(folders) do
        if folder.parent_ref and folder_map[folder.parent_ref] then
            folder.parent_id = folder.parent_ref
            folder.parent_name = folder_map[folder.parent_ref].name
        else
            folder.parent_id = nil  -- Root folder
        end
    end

    -- Exclude "Master" root — it's the DRP MediaPool root, not a user bin.
    -- Reparent its children to root (nil).
    local master_root_id = nil
    for _, folder in ipairs(folders) do
        if folder.parent_id == nil and folder.name == "Master" then
            master_root_id = folder.id
            break
        end
    end

    if master_root_id then
        -- Reparent children of Master to root
        for _, folder in ipairs(folders) do
            if folder.parent_id == master_root_id then
                folder.parent_id = nil
                folder.parent_name = nil
            end
        end
        -- Reparent pool master clips whose folder_id == Master root
        for _, clip in ipairs(master_clips) do
            if clip.folder_id == master_root_id then
                clip.folder_id = nil
            end
        end
        -- Remove Master from folders list
        for i, folder in ipairs(folders) do
            if folder.id == master_root_id then
                table.remove(folders, i)
                break
            end
        end
        folder_map[master_root_id] = nil
    end

    return {
        folders = folders,
        master_clips = master_clips,
        folder_map = folder_map,
        excluded_root_id = master_root_id,
    }
end

-- ---------------------------------------------------------------------------
-- Timeline Metadata Resolution
-- ---------------------------------------------------------------------------
--
-- Resolve's .drp format stores timeline metadata separately from sequence data:
--
--   SeqContainer/*.xml     → Contains tracks and clips (Sm2SequenceContainer)
--                            Each track has a <Sequence> reference ID
--
--   MediaPool/**/*.xml     → Contains Sm2Timeline elements with:
--                            - <Name> (the timeline's display name)
--                            - <Sequence><Sm2Sequence DbId="..."> (the sequence ID)
--                            - <Sequence><Sm2Sequence><FrameRate> (hex-encoded fps)
--
-- To get timeline metadata, we must:
-- 1. Recursively scan all MpFolder.xml files in MediaPool/
-- 2. Find all <Sm2Timeline> elements
-- 3. Extract <Name>, <Sm2Sequence DbId>, and <FrameRate>
-- 4. Build a map: Sequence ID → {name, fps}
-- 5. When parsing SeqContainer, look up metadata using track's <Sequence> ref
--
-- @param tmp_dir string: Extracted .drp temp directory
-- @return table: Map of sequence_id → {name=string, fps=number|nil}
--
--- Extract metadata from an Sm2Timeline element into metadata_map.
-- @param metadata_map table: seq_id → {name, fps, width, height, folder_id}
-- @param timeline_elem table: <Sm2Timeline> XML element
-- @param folder_id string|nil: parent folder DbId (from Sm2MpTimelineClip)
local function extract_timeline_metadata(metadata_map, timeline_elem, folder_id)
    local name_elem = find_direct_child(timeline_elem, "Name")
    local timeline_name = name_elem and get_text(name_elem) or nil
    if not timeline_name or timeline_name == "" then return end

    -- Structure: <Sm2Timeline><Sequence><Sm2Sequence DbId="..."><FrameRate>hex
    local seq_wrapper = find_direct_child(timeline_elem, "Sequence")
    if not seq_wrapper then return end

    local sm2_seq = find_direct_child(seq_wrapper, "Sm2Sequence")
    if not sm2_seq or not sm2_seq.attrs or not sm2_seq.attrs.DbId then return end

    local seq_id = sm2_seq.attrs.DbId

    local fps = nil
    local frame_rate_elem = find_direct_child(sm2_seq, "FrameRate")
    if frame_rate_elem then
        fps = decode_hex_double(get_text(frame_rate_elem))
    end

    local width, height = nil, nil
    local resolution_elem = find_direct_child(sm2_seq, "Resolution")
    if resolution_elem then
        width, height = decode_hex_resolution(get_text(resolution_elem))
        if width then width = math.floor(width) end
        if height then height = math.floor(height) end
    end

    metadata_map[seq_id] = {
        name = timeline_name,
        fps = fps,
        width = width,
        height = height,
        folder_id = folder_id,
    }
end

local function build_timeline_metadata_map(tmp_dir)
    local metadata_map = {}

    local find_cmd = string.format('find "%s/MediaPool" -name "MpFolder.xml" 2>/dev/null', tmp_dir)
    local find_handle = io.popen(find_cmd)
    if not find_handle then
        return metadata_map
    end

    local mp_files = find_handle:read("*all")
    find_handle:close()

    for mp_file in mp_files:gmatch("[^\n]+") do
        local mp_root = parse_xml_file(mp_file)
        if mp_root then
            -- Primary: find Sm2MpTimelineClip elements (contain folder ref + nested Sm2Timeline)
            local timeline_clips = find_all_elements(mp_root, "Sm2MpTimelineClip")
            for _, tc_elem in ipairs(timeline_clips) do
                local folder_ref_elem = find_direct_child(tc_elem, "MpFolder")
                local tc_folder_id = folder_ref_elem and get_text(folder_ref_elem) or nil

                local nested_timeline = find_element(tc_elem, "Sm2Timeline")
                if nested_timeline then
                    extract_timeline_metadata(metadata_map, nested_timeline, tc_folder_id)
                end
            end

            -- Fallback: bare Sm2Timeline elements not inside Sm2MpTimelineClip
            local all_timelines = find_all_elements(mp_root, "Sm2Timeline")
            for _, timeline_elem in ipairs(all_timelines) do
                local seq_wrapper = find_direct_child(timeline_elem, "Sequence")
                if seq_wrapper then
                    local sm2_seq = find_direct_child(seq_wrapper, "Sm2Sequence")
                    if sm2_seq and sm2_seq.attrs and sm2_seq.attrs.DbId then
                        if not metadata_map[sm2_seq.attrs.DbId] then
                            extract_timeline_metadata(metadata_map, timeline_elem, nil)
                        end
                    end
                end
            end
        end
    end

    return metadata_map
end

-- Extract the sequence reference ID from a SeqContainer
-- Tracks reference their parent sequence via <Sequence>...</Sequence>
-- @param seq_container_elem table: The Sm2SequenceContainer element
-- @return string|nil: The sequence reference ID, or nil if not found
local function extract_sequence_ref_id(seq_container_elem)
    -- Look in tracks for the <Sequence> reference
    -- All tracks in a container reference the same sequence
    local track = find_element(seq_container_elem, "Sm2TiTrack")
    if track then
        local seq_ref = find_direct_child(track, "Sequence")
        if seq_ref then
            return get_text(seq_ref)
        end
    end
    return nil
end

--- Parse Resolve tracks from sequence element
-- NSF: frame_rate is REQUIRED - DRP reliably encodes fps in metadata
-- @param seq_elem table: XML sequence element
-- @param frame_rate number: Frame rate from DRP metadata (required)
-- @return video_tracks, audio_tracks, media_lookup
local function parse_resolve_tracks(seq_elem, frame_rate)
    -- NSF: frame_rate is required, no fallbacks
    assert(type(frame_rate) == "number" and frame_rate > 0, string.format(
        "parse_resolve_tracks: frame_rate is required (got %s) - DRP must provide fps metadata",
        tostring(frame_rate)))

    local video_tracks = {}
    local audio_tracks = {}
    local media_lookup = {}
    local video_index = 1
    local audio_index = 1

    local track_elements = find_all_elements(seq_elem, "Sm2TiTrack")

    for _, track_elem in ipairs(track_elements) do
        local type_elem = find_element(track_elem, "Type")
        assert(type_elem, "parse_resolve_tracks: track missing Type element")
        local type_value = tonumber(get_text(type_elem))
        assert(type_value, "parse_resolve_tracks: track Type element has no numeric value")
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
        local clip_elements = find_track_clips(track_elem, clip_tag)
        local clip_count = 0

        for _, clip_elem in ipairs(clip_elements) do
            local file_path = get_text(find_element(clip_elem, "MediaFilePath"))
            local clip_name = get_text(find_element(clip_elem, "Name")) or file_path or "unnamed"

            -- NSF: Assert on missing required clip fields
            local start_elem = find_element(clip_elem, "Start")
            local duration_elem = find_element(clip_elem, "Duration")
            local in_elem = find_element(clip_elem, "In")

            assert(start_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Start element", clip_name))
            assert(duration_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Duration element", clip_name))

            -- DRP format: some values use "frames|metadata" format (e.g., "2699|00e0401cd451d83f")
            -- Extract numeric portion before pipe
            local function parse_drp_numeric(text, field_name)
                if not text then return nil end
                local num_str = text:match("^(%d+)") -- extract leading digits
                local num = tonumber(num_str)
                assert(num, string.format(
                    "parse_resolve_tracks: clip '%s' %s has no numeric value (raw='%s')",
                    clip_name, field_name, text))
                return num
            end

            local start_frames = parse_drp_numeric(get_text(start_elem), "Start")
            local duration_raw = parse_drp_numeric(get_text(duration_elem), "Duration")

            start_frames = math.floor(start_frames)
            duration_raw = math.floor(duration_raw)

            -- DRP field meanings (confirmed from real DRP XML analysis):
            --   <MediaStartTime> = file's TC origin in SECONDS since midnight (not per-clip)
            --   <In>             = source mark-in offset in TIMELINE FRAMES
            --   <Start>          = timeline position (frames)
            --   <Duration>       = timeline duration (frames)
            --
            -- source_in comes from <In>, NOT <MediaStartTime>.
            -- Empty/missing <In> means untrimmed (source_in = 0).
            local in_text = in_elem and get_text(in_elem) or ""
            local in_value
            if in_text == "" then
                in_value = 0  -- empty/missing <In> = untrimmed
            else
                -- DRP <In> can be "12345" or "12345|hexdata" (pipe-delimited
                -- with hex-encoded speed ratio). Extract integer before pipe.
                local num_part = in_text:match("^(%d+)")
                in_value = assert(num_part and tonumber(num_part), string.format(
                    "parse_resolve_tracks: clip '%s' <In> has no numeric prefix: '%s'",
                    clip_name, in_text))
            end

            local duration_timeline_frames = duration_raw
            local source_in_native
            local source_duration
            if track_type == "AUDIO" then
                -- Audio: convert <In> from timeline frames to samples (48kHz)
                source_in_native = math.floor(in_value * 48000 / frame_rate + 0.5)
                source_duration = math.floor(duration_raw * 48000 / frame_rate + 0.5)
            else
                -- Video: <In> is already in video frames
                source_in_native = math.floor(in_value)
                source_duration = duration_raw
            end

            local clip = {
                name = clip_name,
                start_value = start_frames,        -- timeline position (integer frames)
                duration = duration_timeline_frames,  -- duration on timeline (integer frames)
                -- Absolute timecode addressing for source selection:
                source_in_tc = source_in_native,   -- native units (samples for audio, frames for video)
                source_length = source_duration,   -- duration in source units
                -- Legacy aliases (deprecated - use source_in_tc/source_length)
                source_in = source_in_native,
                source_out = source_in_native + source_duration,
                enabled = get_text(find_element(clip_elem, "WasDisbanded")) ~= "true",
                file_path = file_path,
                media_key = file_path,
                file_id = get_text(find_element(clip_elem, "MediaRef")),
                frame_rate = frame_rate
            }

            -- Skip degenerate zero-duration clips (Resolve artifacts: speed changes, disabled items)
            if clip.duration <= 0 then
                logger.warn("drp_importer", string.format("Skipping zero-duration clip '%s' (duration=%d)", clip_name, clip.duration))
            else
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

-- Forward declaration (defined below parse_sequence)
local parse_clip_item

--- Parse sequence XML to extract timeline data
-- NSF: frame_rate is REQUIRED - DRP reliably encodes fps
-- @param seq_elem table: XML element for <Sequence>
-- @param frame_rate number: Frame rate from DRP metadata (required)
-- @return table: Timeline data
local function parse_sequence(seq_elem, frame_rate)
    -- NSF: frame_rate is required
    assert(type(frame_rate) == "number" and frame_rate > 0, string.format(
        "parse_sequence: frame_rate is required (got %s) - DRP must provide fps metadata",
        tostring(frame_rate)))

    -- Use find_direct_child for sequence properties to avoid picking up
    -- nested <Name>/<Duration> elements from clips
    local name_elem = find_direct_child(seq_elem, "Name")
    local duration_elem = find_direct_child(seq_elem, "Duration")

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

    -- NSF: If no tracks were parsed, that's an error - no silent fallback with dummy data
    -- (Empty timeline with 0 tracks is valid - it means the timeline exists but has no content)

    return timeline
end

--- Parse ClipItem XML to extract clip data
-- @param clip_elem table: XML element for <ClipItem>
-- @param frame_rate number: Timeline frame rate
-- @return table|nil: Clip data, or nil if invalid
parse_clip_item = function(clip_elem, frame_rate)
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

    -- All coordinates are integer frames
    local source_in = in_elem and parse_resolve_timecode(get_text(in_elem), frame_rate) or 0
    local source_out = out_elem and parse_resolve_timecode(get_text(out_elem), frame_rate) or 0

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
--     timelines = { {name, duration, tracks}, ... },
--     folders = { {id, name, parent_id, color}, ... },  -- MediaPool bin hierarchy
--     pool_master_clips = { {id, name, folder_id, mark_in, mark_out, playhead}, ... },
--     folder_map = { [folder_id] = folder, ... },  -- Lookup by ID
--   }
function M.parse_drp_file(drp_path)
    -- Extract .drp archive
    local tmp_dir, err = extract_drp(drp_path)
    if not tmp_dir then
        return {success = false, error = err}
    end

    -- Parse project.xml
    local project_xml_path = tmp_dir .. "/project.xml"
    local project_root, parse_err = parse_xml_file(project_xml_path)
    if not project_root then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "Failed to parse project.xml: " .. tostring(parse_err)}
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

    -- Parse MediaPool XML for master clips
    local media_pool_path = tmp_dir .. "/MediaPool/Master/MpFolder.xml"
    local media_items = {}
    local media_pool_root = parse_xml_file(media_pool_path)
    if media_pool_root then
        media_items = parse_media_pool(media_pool_root)
    end

    -- Build timeline metadata map by scanning all MediaPool folders
    -- This maps Sequence IDs to {name, fps} from Sm2Timeline/Sm2Sequence elements
    local timeline_metadata_map = build_timeline_metadata_map(tmp_dir)

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
        local seq_root = parse_xml_file(seq_file)
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
                -- Look up the timeline's metadata (name + fps) using the sequence reference
                local seq_ref_id = extract_sequence_ref_id(seq_elem)
                local metadata = seq_ref_id and timeline_metadata_map[seq_ref_id]

                -- Skip orphan sequences with no MediaPool metadata (compound clips, deleted timelines)
                local fps_for_parsing = metadata and metadata.fps
                if not fps_for_parsing or fps_for_parsing <= 0 then
                    logger.warn("drp_importer", string.format(
                        "Skipping sequence '%s' (seq_ref_id=%s) - no fps in MediaPool metadata",
                        seq_file:match("([^/]+)%.xml$") or seq_file,
                        tostring(seq_ref_id)))
                    goto continue_seq
                end
                local timeline = parse_sequence(seq_elem, fps_for_parsing)

                -- Apply timeline name from metadata
                if metadata and metadata.name then
                    timeline.name = metadata.name
                end

                -- Store the fps for downstream use
                timeline.fps = fps_for_parsing

                -- Store resolution from metadata (or use project defaults)
                -- NOTE: Lua truthy-zero — `0 or fallback` == 0, so check > 0 explicitly
                local meta_w = metadata and metadata.width
                local meta_h = metadata and metadata.height
                timeline.width = (meta_w and meta_w > 0) and meta_w or project.settings.width
                timeline.height = (meta_h and meta_h > 0) and meta_h or project.settings.height

                -- Store folder_id for bin hierarchy import
                timeline.folder_id = metadata and metadata.folder_id or nil

                table.insert(timelines, timeline)
                ::continue_seq::
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

    -- Propagate first timeline fps to project settings when DRP lacks TimelineFrameRate.
    -- Media items need a frame_rate; the first timeline's metadata-derived fps is the
    -- best approximation available from DRP.
    if not project.settings.frame_rate and #timelines > 0 then
        assert(timelines[1].fps, "parse_drp_file: first timeline has no fps")
        project.settings.frame_rate = timelines[1].fps
    end

    -- Parse MediaPool folder hierarchy for bins and master clips
    local media_pool_hierarchy = parse_media_pool_hierarchy(tmp_dir)

    -- Nil out timeline folder_ids that referenced the excluded Master root
    if media_pool_hierarchy.excluded_root_id then
        for _, timeline in ipairs(timelines) do
            if timeline.folder_id == media_pool_hierarchy.excluded_root_id then
                timeline.folder_id = nil
            end
        end
    end

    -- Cleanup temp directory
    os.execute("rm -rf " .. tmp_dir)

    return {
        success = true,
        project = project,
        media_items = media_items,
        timelines = timelines,
        -- New: folder/bin hierarchy and master clips from MediaPool
        folders = media_pool_hierarchy.folders,
        pool_master_clips = media_pool_hierarchy.master_clips,
        folder_map = media_pool_hierarchy.folder_map,
    }
end

-- Test-only export (underscore-prefixed convention)
M._parse_resolve_tracks = parse_resolve_tracks

-- ===========================================================================
-- Conversion + Import
-- ===========================================================================
--
-- Two verbs use the same entity-creation logic:
--   Open  → convert() → parse + init DB + create project + import_into_project()
--   Import → command executor → import_into_project() with existing project
--
-- import_into_project() is the single source of truth for DRP entity creation:
-- media records, sequences, tracks, clips, A/V link groups.

-- Models (SQL isolation: all DB access goes through models)
local Project = require("models.project")
local Media = require("models.media")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local clip_link = require("models.clip_link")

-- ---------------------------------------------------------------------------
-- Helper: Infer frame rate from 1-hour timecode start position
-- ---------------------------------------------------------------------------
--
-- HEURISTIC: Professional video workflows typically use 1-hour timecode start
-- (01:00:00:00). Different frame rates produce different frame counts:
--
--   Frame Rate    | Frames in 1 Hour | Rational (num/den)
--   23.976 fps    | ~86,314          | 24000/1001
--   24 fps        |  86,400          | 24/1
--   25 fps        |  90,000          | 25/1
--   29.97 fps     | ~107,892         | 30000/1001
--   30 fps        | 108,000          | 30/1
--   50 fps        | 180,000          | 50/1
--   59.94 fps     | ~215,784         | 60000/1001
--   60 fps        | 216,000          | 60/1
--
local function infer_fps_from_one_hour_start(min_start_frame)
    if not min_start_frame or min_start_frame <= 0 then
        return nil
    end

    local one_hour_markers = {
        { 86314,  23.976, 24000, 1001 },
        { 86400,  24,     24,    1    },
        { 90000,  25,     25,    1    },
        { 107892, 29.97,  30000, 1001 },
        { 108000, 30,     30,    1    },
        { 180000, 50,     50,    1    },
        { 215784, 59.94,  60000, 1001 },
        { 216000, 60,     60,    1    },
    }

    local tolerance = 0.01

    for _, marker in ipairs(one_hour_markers) do
        local expected = marker[1]
        local lower = expected * (1 - tolerance)
        local upper = expected * (1 + tolerance)

        if min_start_frame >= lower and min_start_frame <= upper then
            logger.info("drp_importer",
                string.format("Inferred %.3f fps from 1-hour TC start (frame %d ~ %d)",
                    marker[2], min_start_frame, expected))
            return marker[2], marker[3], marker[4]
        end
    end

    logger.debug("drp_importer",
        string.format("Could not infer fps from start frame %d (not near 1-hour TC)", min_start_frame))
    return nil
end

-- ---------------------------------------------------------------------------
-- Helper: Frame rate to rational
-- ---------------------------------------------------------------------------

local function frame_rate_to_rational(frame_rate)
    local fps = tonumber(frame_rate)
    assert(fps and fps > 0, "drp_importer: invalid frame_rate: " .. tostring(frame_rate))

    if math.abs(fps - 23.976) < 0.01 then
        return 24000, 1001
    elseif math.abs(fps - 29.97) < 0.01 then
        return 30000, 1001
    elseif math.abs(fps - 59.94) < 0.01 then
        return 60000, 1001
    end

    return math.floor(fps + 0.5), 1
end

-- ---------------------------------------------------------------------------
-- Conversion Dialog
-- ---------------------------------------------------------------------------

--- Show conversion dialog for .drp file
-- @param drp_path string: Path to source .drp file
-- @param parent widget: Parent window for dialog
-- @return string|nil: Chosen save path, or nil if cancelled
function M.show_conversion_dialog(drp_path, parent)
    assert(drp_path and drp_path ~= "", "drp_importer.show_conversion_dialog: drp_path required")

    local file_browser = require("core.file_browser")

    local default_name = "Converted Project.jvp"
    local parse_result = M.parse_drp_file(drp_path)
    if parse_result.success and parse_result.project and parse_result.project.name then
        default_name = parse_result.project.name .. ".jvp"
    end

    local home = os.getenv("HOME") or ""
    local default_dir = home ~= "" and (home .. "/Documents/JVE Projects") or ""

    local save_path = file_browser.save_file(
        "convert_drp_project",
        parent,
        "Save Converted Project",
        "JVE Project Files (*.jvp)",
        default_dir,
        default_name
    )

    return save_path
end

-- ---------------------------------------------------------------------------
-- import_into_project: Shared entity-creation for both Open and Import verbs
-- ---------------------------------------------------------------------------

--- Apply pool master clip marks (mark_in, mark_out, playhead) to JVE master clips.
-- DRP stores per-clip marks in MediaPool master clip elements. After import creates
-- masterclip sequences, this function matches by media name and applies the marks
-- to the corresponding stream clips (video/audio) in each masterclip sequence.
-- Uses model APIs only (SQL isolation: no database.get_connection() in importers).
-- @param pool_master_clips table: Array from parse_drp_file().pool_master_clips
-- @param media_by_path table: file_path → Media record (from import loop)
local function apply_pool_master_clip_marks(pool_master_clips, media_by_path)
    if not pool_master_clips or #pool_master_clips == 0 then return end

    -- Build name → marks map, keyed by (media_name, clip_type)
    -- clip_type is "video" or "audio" from pool master clip parsing
    local marks_by_name = {}  -- name → { video = {mark_in, mark_out, playhead}, audio = {...} }
    for _, pmc in ipairs(pool_master_clips) do
        if pmc.mark_in or pmc.mark_out or (pmc.playhead and pmc.playhead > 0) then
            if not marks_by_name[pmc.name] then
                marks_by_name[pmc.name] = {}
            end
            marks_by_name[pmc.name][pmc.clip_type] = {
                mark_in = pmc.mark_in,
                mark_out = pmc.mark_out,
                playhead = pmc.playhead or 0,
            }
        end
    end

    local applied_count = 0
    for _, media in pairs(media_by_path) do
        local name_marks = marks_by_name[media.name]
        if not name_marks then goto next_media end

        -- Find the masterclip sequence for this media (via Sequence model)
        local mc_seq_id = Sequence.find_masterclip_for_media(media.id)
        if not mc_seq_id then
            logger.warn("drp_importer", string.format(
                "apply_marks: no masterclip sequence for media '%s' (id=%s)",
                media.name, media.id))
            goto next_media
        end

        local mc_seq = Sequence.load(mc_seq_id)
        assert(mc_seq, string.format(
            "apply_marks: Sequence.load failed for masterclip %s (media=%s)",
            mc_seq_id, media.name))

        -- Apply video marks to video stream clip
        if name_marks.video then
            local video_clip = mc_seq:video_stream()
            if video_clip then
                video_clip.mark_in = name_marks.video.mark_in
                video_clip.mark_out = name_marks.video.mark_out
                video_clip.playhead_frame = name_marks.video.playhead
                assert(video_clip:save({skip_occlusion = true}), string.format(
                    "apply_marks: save failed for video clip %s (media=%s)",
                    video_clip.id, media.name))
                applied_count = applied_count + 1
            end
        end

        -- Apply audio marks to all audio stream clips
        if name_marks.audio then
            for _, audio_clip in ipairs(mc_seq:audio_streams()) do
                audio_clip.mark_in = name_marks.audio.mark_in
                audio_clip.mark_out = name_marks.audio.mark_out
                audio_clip.playhead_frame = name_marks.audio.playhead
                assert(audio_clip:save({skip_occlusion = true}), string.format(
                    "apply_marks: save failed for audio clip %s (media=%s)",
                    audio_clip.id, media.name))
                applied_count = applied_count + 1
            end
        end

        ::next_media::
    end

    if applied_count > 0 then
        logger.info("drp_importer", string.format(
            "Applied marks to %d master clip stream(s)", applied_count))
    end
end

--- Mark clips offline whose media files don't exist on disk.
-- Loads each clip, checks its media path, sets offline=true and saves.
-- @param clip_ids table: list of clip IDs to check
-- @return number: count of clips marked offline
local function mark_offline_clips(clip_ids)
    local Clip_model = require("models.clip")
    local Media_model = require("models.media")

    -- Collect unique media paths → file existence
    local path_exists_cache = {}
    local offline_count = 0

    for _, clip_id in ipairs(clip_ids) do
        local clip = Clip_model.load(clip_id)
        assert(clip, string.format(
            "mark_offline_clips: Clip.load failed for just-created clip %s", clip_id))

        -- Master clips (clip_kind="master") may not have media_id — skip
        if not clip.media_id then goto next_clip end

        local media = Media_model.load(clip.media_id)
        assert(media, string.format(
            "mark_offline_clips: Media.load failed for clip %s media_id %s",
            clip_id, tostring(clip.media_id)))
        assert(media.file_path, string.format(
            "mark_offline_clips: media %s has nil file_path", media.id))

        local path = media.file_path
        if path_exists_cache[path] == nil then
            local f = io.open(path, "r")
            if f then
                f:close()
                path_exists_cache[path] = true
            else
                path_exists_cache[path] = false
                logger.warn("drp_importer", string.format(
                    "Media file not found: %s", path))
            end
        end

        if not path_exists_cache[path] and not clip.offline then
            clip.offline = true
            assert(clip:save({skip_occlusion = true}), string.format(
                "mark_offline_clips: save failed for clip %s", clip_id))
            offline_count = offline_count + 1
        end

        ::next_clip::
    end

    return offline_count
end

--- Import parsed DRP data into an existing project.
-- Creates: media records, sequences, tracks, clips, A/V link groups.
-- @param project_id string: Target project ID (must already exist)
-- @param parse_result table: Output of parse_drp_file()
-- @param opts table: Optional settings
--   opts.project_settings table: {frame_rate, width, height} project defaults
-- @return table: {media_ids, sequence_ids, track_ids, clip_ids} for undo
function M.import_into_project(project_id, parse_result, opts)
    assert(project_id and project_id ~= "", "drp_importer.import_into_project: project_id required")
    assert(parse_result and parse_result.success, "drp_importer.import_into_project: parse_result must be successful")
    opts = opts or {}
    local project_settings = opts.project_settings or parse_result.project.settings

    local tag_service = require("core.tag_service")
    local uuid = require("uuid")

    -- Track created entity IDs for undo
    local result = {
        media_ids = {},
        sequence_ids = {},
        track_ids = {},
        clip_ids = {},
    }

    -- Import DRP folder hierarchy as bins
    local drp_folder_to_bin = {}  -- DRP folder DbId → JVE bin_id
    for _, folder in ipairs(parse_result.folders or {}) do
        -- Map DRP parent_ref to JVE parent_id (already-created bin)
        local parent_bin_id = folder.parent_id and drp_folder_to_bin[folder.parent_id] or nil
        local bin_id = uuid.generate_with_prefix("bin")
        local ok, def = tag_service.create_bin(project_id, {
            id = bin_id,
            name = folder.name,
            parent_id = parent_bin_id,
        })
        if ok and def then
            drp_folder_to_bin[folder.id] = def.id
            logger.debug("drp_importer", string.format("  Created bin: %s (parent=%s)", folder.name, tostring(parent_bin_id)))
        else
            logger.warn("drp_importer", string.format("Failed to create bin: %s", folder.name))
        end
    end

    -- Build pool master clip name → DRP folder bin mapping
    -- pool_master_clips have {name, folder_id} from MediaPool hierarchy
    -- Two indexes: by exact name and by filename (for audio-from-video matching)
    local pool_name_to_drp_bin = {}
    for _, pmc in ipairs(parse_result.pool_master_clips or {}) do
        if pmc.folder_id and drp_folder_to_bin[pmc.folder_id] then
            pool_name_to_drp_bin[pmc.name] = drp_folder_to_bin[pmc.folder_id]
        end
    end

    -- Import media items
    local media_by_path = {}
    for _, media_item in ipairs(parse_result.media_items) do
        local dur = media_item.duration or 0
        if dur <= 0 then
            logger.warn("drp_importer", string.format("Skipping zero-duration media: %s", media_item.name))
        else
            local media = Media.create({
                project_id = project_id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration_frames = dur,
                frame_rate = assert(media_item.frame_rate or project_settings.frame_rate,
                    string.format("drp_importer: no frame_rate for media '%s'", media_item.name)),
                width = project_settings.width,
                height = project_settings.height,
            })

            if media:save() then
                media_by_path[media_item.file_path] = media
                table.insert(result.media_ids, media.id)
                logger.debug("drp_importer", string.format("  Imported media: %s", media.name))
            else
                logger.warn("drp_importer", string.format("Failed to import media: %s", media_item.name))
            end
        end
    end

    -- Import timelines
    for _, timeline_data in ipairs(parse_result.timelines) do
        -- STEP 1: Analyze clip positions for viewport + fps inference
        local min_start_frame = nil
        local max_end_frame = 0
        for _, track_data in ipairs(timeline_data.tracks) do
            for _, clip_data in ipairs(track_data.clips) do
                local start = clip_data.start_value or 0
                local dur = clip_data.duration or 0
                if not min_start_frame or start < min_start_frame then
                    min_start_frame = start
                end
                if (start + dur) > max_end_frame then
                    max_end_frame = start + dur
                end
            end
        end

        -- STEP 2: Determine frame rate
        local fps_num, fps_den

        if timeline_data.fps and timeline_data.fps > 0 then
            fps_num, fps_den = frame_rate_to_rational(timeline_data.fps)
            logger.info("drp_importer",
                string.format("Using explicit fps from DRP metadata: %.3f (%d/%d)",
                    timeline_data.fps, fps_num, fps_den))
        else
            local inferred_fps, inferred_num, inferred_den = infer_fps_from_one_hour_start(min_start_frame)

            if inferred_fps then
                fps_num, fps_den = inferred_num, inferred_den
                logger.info("drp_importer",
                    string.format("Inferred fps from 1-hour TC: %.3f (%d/%d)",
                        inferred_fps, fps_num, fps_den))
            else
                fps_num, fps_den = frame_rate_to_rational(project_settings.frame_rate)
                logger.warn("drp_importer",
                    string.format("No fps metadata, no 1-hour TC; using project default: %d/%d",
                        fps_num, fps_den))
            end
        end

        -- STEP 3: Zoom-to-fit viewport
        local view_start = min_start_frame or 0
        local content_duration = max_end_frame - view_start
        local view_duration

        if content_duration > 0 then
            local margin = math.floor(content_duration * 0.05)
            view_start = math.max(0, view_start - margin)
            view_duration = content_duration + (margin * 2)
        else
            local effective_fps = fps_num / fps_den
            view_duration = math.floor(10 * effective_fps)
        end

        -- STEP 4: Create Sequence
        local seq_width = (timeline_data.width and timeline_data.width > 0)
            and timeline_data.width or project_settings.width
        local seq_height = (timeline_data.height and timeline_data.height > 0)
            and timeline_data.height or project_settings.height

        local sequence = Sequence.create(
            timeline_data.name,
            project_id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            seq_width,
            seq_height,
            {
                audio_rate = 48000,
                view_start_frame = view_start,
                view_duration_frames = view_duration,
                playhead_frame = min_start_frame or 0,
            }
        )

        if not sequence:save() then
            logger.warn("drp_importer", string.format("Failed to create timeline: %s", timeline_data.name))
        else
            table.insert(result.sequence_ids, sequence.id)
            logger.info("drp_importer",
                string.format("  Created timeline: %s @ %d/%d fps, %dx%d, viewport [%d..%d]",
                    timeline_data.name, fps_num, fps_den, seq_width, seq_height, view_start, view_start + view_duration))

            -- Assign timeline sequence to DRP folder bin
            local timeline_folder_bin = timeline_data.folder_id and drp_folder_to_bin[timeline_data.folder_id] or nil
            if timeline_folder_bin then
                tag_service.add_to_bin(project_id, {sequence.id}, timeline_folder_bin, "sequence")
            end

            -- Create per-sequence master clip bin: "{seq_name} Master Clips"
            -- Parent = timeline's folder bin (from DRP hierarchy), or nil (root)
            local parent_bin_id = timeline_folder_bin
            local mc_bin_label = string.format("%s Master Clips", timeline_data.name)
            local mc_bin_id = uuid.generate_with_prefix("bin")
            local mc_ok, mc_def = tag_service.create_bin(project_id, {
                id = mc_bin_id,
                name = mc_bin_label,
                parent_id = parent_bin_id,
            })
            local master_bin_id = (mc_ok and mc_def) and mc_def.id or nil
            if master_bin_id then
                logger.debug("drp_importer", string.format("  Created master clip bin: %s", mc_bin_label))
            end

            local clips_for_linking = {}

            -- STEP 5: Import tracks + clips
            for _, track_data in ipairs(timeline_data.tracks) do
                local track_prefix = track_data.type == "VIDEO" and "V" or "A"
                local track_name = string.format("%s%d", track_prefix, track_data.index)

                local track
                if track_data.type == "VIDEO" then
                    track = Track.create_video(track_name, sequence.id, { index = track_data.index })
                else
                    track = Track.create_audio(track_name, sequence.id, { index = track_data.index })
                end

                if not track:save() then
                    logger.warn("drp_importer", string.format("Failed to create track: %s", track_name))
                else
                    table.insert(result.track_ids, track.id)

                    for _, clip_data in ipairs(track_data.clips) do
                        local media_id = nil
                        if clip_data.file_path and media_by_path[clip_data.file_path] then
                            media_id = media_by_path[clip_data.file_path].id
                        end

                        -- Skip clips with no resolvable media (generated clips, titles, removed media)
                        if not media_id then
                            logger.warn("drp_importer", string.format(
                                "Skipping clip '%s' - no media record for path: %s",
                                clip_data.name or "unnamed", tostring(clip_data.file_path)))
                            goto continue_clip
                        end

                        local clip_rate_num, clip_rate_den
                        if track_data.type == "VIDEO" then
                            clip_rate_num, clip_rate_den = fps_num, fps_den
                        else
                            clip_rate_num, clip_rate_den = 48000, 1
                        end

                        local source_out = clip_data.source_out
                        if not source_out and clip_data.source_in and clip_data.duration then
                            source_out = clip_data.source_in + clip_data.duration
                        end

                        local clip = Clip.create(clip_data.name or "Untitled Clip", media_id, {
                            project_id = project_id,
                            owner_sequence_id = sequence.id,
                            track_id = track.id,
                            timeline_start = clip_data.start_value,
                            duration = clip_data.duration,
                            source_in = clip_data.source_in,
                            source_out = source_out,
                            fps_numerator = clip_rate_num,
                            fps_denominator = clip_rate_den,
                            bin_id = master_bin_id,
                        })

                        if clip:save() then
                            table.insert(result.clip_ids, clip.id)

                            -- Assign masterclip sequence to DRP folder bin (many-to-many safe)
                            -- Match by media name first, then by file path basename
                            -- (audio-from-video clips have different names than pool master clips)
                            if clip.master_clip_id and clip_data.file_path then
                                local media = media_by_path[clip_data.file_path]
                                local drp_bin = media and pool_name_to_drp_bin[media.name]
                                if not drp_bin then
                                    local basename = clip_data.file_path:match("([^/\\]+)$")
                                    drp_bin = basename and pool_name_to_drp_bin[basename]
                                end
                                if drp_bin then
                                    tag_service.add_to_bin(project_id, {clip.master_clip_id}, drp_bin, "master_clip")
                                end
                            end

                            if clip_data.file_path then
                                table.insert(clips_for_linking, {
                                    clip_id = clip.id,
                                    file_path = clip_data.file_path,
                                    timeline_start = clip_data.start_value,
                                    role = track_data.type == "VIDEO" and "video" or "audio",
                                })
                            end
                        else
                            logger.warn("drp_importer", string.format("Failed to import clip: %s", clip_data.name))
                        end
                        ::continue_clip::
                    end
                end
            end

            -- STEP 6: Create A/V link groups
            local link_groups_by_key = {}
            for _, clip_info in ipairs(clips_for_linking) do
                local key = clip_info.file_path .. ":" .. tostring(clip_info.timeline_start)
                link_groups_by_key[key] = link_groups_by_key[key] or {}
                table.insert(link_groups_by_key[key], clip_info)
            end

            local link_count = 0
            for _, group in pairs(link_groups_by_key) do
                if #group >= 2 then
                    local clips_to_link = {}
                    for _, info in ipairs(group) do
                        table.insert(clips_to_link, {
                            clip_id = info.clip_id,
                            role = info.role,
                            time_offset = 0,
                        })
                    end

                    local link_id, link_err = clip_link.create_link_group(clips_to_link)
                    if link_id then
                        link_count = link_count + 1
                    else
                        logger.warn("drp_importer",
                            string.format("Failed to create link group: %s", link_err or "unknown error"))
                    end
                end
            end

            if link_count > 0 then
                logger.info("drp_importer",
                    string.format("Created %d A/V link groups for timeline: %s", link_count, timeline_data.name))
            end
        end
    end

    -- STEP 7: Apply pool master clip marks to JVE master clips
    apply_pool_master_clip_marks(parse_result.pool_master_clips, media_by_path)

    -- STEP 8: Mark clips offline for missing media files
    local offline_count = mark_offline_clips(result.clip_ids)
    if offline_count > 0 then
        logger.warn("drp_importer", string.format(
            "%d clip(s) marked offline (media files not found)", offline_count))
    end

    logger.info("drp_importer", string.format("Import complete: %d media, %d sequences, %d tracks, %d clips (%d offline)",
        #result.media_ids, #result.sequence_ids, #result.track_ids, #result.clip_ids, offline_count))

    return result
end

-- ---------------------------------------------------------------------------
-- convert: Parse .drp and create new .jvp at target path (Open verb)
-- ---------------------------------------------------------------------------

--- Convert .drp file to .jvp at target path
-- @param drp_path string: Path to source .drp file
-- @param jvp_path string: Path for new .jvp file
-- @return boolean: success
-- @return string|nil: error message if failed
function M.convert(drp_path, jvp_path)
    assert(drp_path and drp_path ~= "", "drp_importer.convert: drp_path required")
    assert(jvp_path and jvp_path ~= "", "drp_importer.convert: jvp_path required")

    logger.info("drp_importer", string.format("Converting %s -> %s", drp_path, jvp_path))

    local parse_result = M.parse_drp_file(drp_path)
    if not parse_result.success then
        return false, "Failed to parse .drp file: " .. tostring(parse_result.error)
    end

    -- Remove existing file if present (user confirmed overwrite in save dialog)
    os.remove(jvp_path)
    os.remove(jvp_path .. "-shm")
    os.remove(jvp_path .. "-wal")

    local database = require("core.database")
    local ok, err = pcall(function()
        database.init(jvp_path)
    end)

    if not ok then
        return false, "Failed to create database: " .. tostring(err)
    end

    local json = require("dkjson")
    local settings = {
        frame_rate = parse_result.project.settings.frame_rate,
        width = parse_result.project.settings.width,
        height = parse_result.project.settings.height,
    }

    local project = Project.create(parse_result.project.name, {
        settings = json.encode(settings),
    })

    if not project:save() then
        return false, "Failed to save project record"
    end

    logger.info("drp_importer", string.format("Created project: %s (%dx%d @ %sfps)",
        project.name, settings.width, settings.height, tostring(settings.frame_rate)))

    M.import_into_project(project.id, parse_result, {
        project_settings = settings,
    })

    return true
end

-- Test-only export for frame_rate_to_rational
M._frame_rate_to_rational = frame_rate_to_rational

return M
