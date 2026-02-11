--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~482 LOC
-- Volatility: unknown
--
-- @file drp_importer.lua
-- Original intent (unreviewed):
-- - DaVinci Resolve .drp Project Importer
-- Parses Resolve's .drp export format (ZIP archive with XML files)
--
-- Format structure:
-- .drp file = ZIP archive containing:
-- - project.xml (project settings, users, timeline list)
-- - MediaPool/Master/MpFolder.xml (media bin organization)
-- - SeqContainer/*.xml (timeline sequences with tracks/clips)
--
-- Usage:
-- local drp_importer = require("importers.drp_importer")
-- local result = drp_importer.parse_drp_file("/path/to/project.drp")
-- if result.success then
-- print("Imported: " .. result.project.name)
-- end
local M = {}

local xml2 = require("xml2")

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
        project.settings.frame_rate = 30.0
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

    return {
        folders = folders,
        master_clips = master_clips,
        folder_map = folder_map,
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
local function build_timeline_metadata_map(tmp_dir)
    local metadata_map = {}

    -- Find all MpFolder.xml files recursively
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
            -- Find all Sm2Timeline elements (timelines can be in any folder)
            local timelines = find_all_elements(mp_root, "Sm2Timeline")
            for _, timeline_elem in ipairs(timelines) do
                -- Get the timeline's display name
                local name_elem = find_direct_child(timeline_elem, "Name")
                local timeline_name = name_elem and get_text(name_elem) or nil

                if timeline_name and timeline_name ~= "" then
                    -- Find the nested Sm2Sequence to get its DbId and FrameRate
                    -- Structure: <Sm2Timeline><Sequence><Sm2Sequence DbId="..."><FrameRate>hex</FrameRate>
                    local seq_wrapper = find_direct_child(timeline_elem, "Sequence")
                    if seq_wrapper then
                        local sm2_seq = find_direct_child(seq_wrapper, "Sm2Sequence")
                        if sm2_seq and sm2_seq.attrs and sm2_seq.attrs.DbId then
                            local seq_id = sm2_seq.attrs.DbId

                            -- Extract frame rate from hex-encoded double
                            local fps = nil
                            local frame_rate_elem = find_direct_child(sm2_seq, "FrameRate")
                            if frame_rate_elem then
                                local hex_str = get_text(frame_rate_elem)
                                fps = decode_hex_double(hex_str)
                            end

                            -- Extract resolution from hex-encoded double pair
                            local width, height = nil, nil
                            local resolution_elem = find_direct_child(sm2_seq, "Resolution")
                            if resolution_elem then
                                local hex_str = get_text(resolution_elem)
                                width, height = decode_hex_resolution(hex_str)
                            end

                            metadata_map[seq_id] = {
                                name = timeline_name,
                                fps = fps,
                                width = width,
                                height = height
                            }
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
        local clip_elements = find_all_elements(track_elem, clip_tag)
        local clip_count = 0

        for _, clip_elem in ipairs(clip_elements) do
            local file_path = get_text(find_element(clip_elem, "MediaFilePath"))
            local clip_name = get_text(find_element(clip_elem, "Name")) or file_path or "unnamed"

            -- NSF: Assert on missing required clip fields
            local start_elem = find_element(clip_elem, "Start")
            local duration_elem = find_element(clip_elem, "Duration")
            local media_start_elem = find_element(clip_elem, "MediaStartTime")

            assert(start_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Start element", clip_name))
            assert(duration_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Duration element", clip_name))
            -- MediaStartTime can be 0 for clips starting at media beginning, but element must exist
            assert(media_start_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing MediaStartTime element", clip_name))

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
            local media_start_frames = parse_drp_numeric(get_text(media_start_elem), "MediaStartTime")

            start_frames = math.floor(start_frames)
            duration_raw = math.floor(duration_raw)
            media_start_frames = math.floor(media_start_frames)

            -- DRP stores Start/Duration in TIMELINE FRAMES for both video and audio
            -- (confirmed: clips are contiguous with Start[n+1] = Start[n] + Duration[n])
            -- source_in/source_out are in native units (samples for audio @ 48kHz, frames for video)
            local duration_timeline_frames = duration_raw  -- already in timeline frames
            local source_duration  -- in native units (samples or frames)
            if track_type == "AUDIO" then
                -- Audio source_in/source_out are in samples (48kHz)
                -- Convert timeline duration (frames) to source duration (samples)
                source_duration = math.floor(duration_raw * 48000 / frame_rate + 0.5)
            else
                -- Video source coords are in frames (same as timeline)
                source_duration = duration_raw
            end

            local clip = {
                name = clip_name,
                start_value = start_frames,        -- timeline position (integer frames)
                duration = duration_timeline_frames,  -- duration on timeline (integer frames)
                -- Absolute timecode addressing for source selection:
                source_in_tc = media_start_frames, -- absolute TC (samples for audio, frames for video)
                source_length = source_duration,   -- duration in source units
                -- Legacy aliases (deprecated - use source_in_tc/source_length)
                source_in = media_start_frames,
                source_out = media_start_frames + source_duration,
                enabled = get_text(find_element(clip_elem, "WasDisbanded")) ~= "true",
                file_path = file_path,
                media_key = file_path,
                file_id = get_text(find_element(clip_elem, "MediaRef")),
                frame_rate = frame_rate
            }

            -- NSF: Assert on invalid duration (no silent fix to 1)
            assert(clip.duration > 0, string.format(
                "parse_resolve_tracks: clip '%s' has invalid duration=%d",
                clip_name, clip.duration))

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

                -- NSF: fps MUST come from DRP metadata - no fallbacks
                local fps_for_parsing = metadata and metadata.fps
                assert(fps_for_parsing and fps_for_parsing > 0, string.format(
                    "parse_drp_file: timeline '%s' (seq_ref_id=%s) missing fps in DRP metadata",
                    seq_file:match("([^/]+)%.xml$") or seq_file,
                    tostring(seq_ref_id)))
                local timeline = parse_sequence(seq_elem, fps_for_parsing)

                -- Apply timeline name from metadata
                if metadata and metadata.name then
                    timeline.name = metadata.name
                end

                -- Store the fps for downstream use
                timeline.fps = fps_for_parsing

                -- Store resolution from metadata (or use project defaults)
                timeline.width = (metadata and metadata.width) or project.settings.width
                timeline.height = (metadata and metadata.height) or project.settings.height

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

    -- Parse MediaPool folder hierarchy for bins and master clips
    local media_pool_hierarchy = parse_media_pool_hierarchy(tmp_dir)

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

return M
