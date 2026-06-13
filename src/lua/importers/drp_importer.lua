--- DaVinci Resolve .drp Importer — parse, convert, and import
--
-- Responsibilities:
-- - parse_drp_file(): Parse .drp ZIP archive to structured Lua tables
-- - quick_metadata(): Lightweight name extraction (no full parse)
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

local log = require("core.logger").for_area("media")
local importer_core = require("importers.importer_core")
local subframe_math = require("core.subframe_math")
local drp_binary = require("importers.drp_binary")
local fs_utils = require("core.fs_utils")
local shell_capture = fs_utils.shell_capture

-- 018 Helen drift fix: DRP MediaStartTime arrives as a decimal-seconds
-- float64. Multiplying by native_rate to land on a TC-origin integer can
-- yield two distinct cases:
--   (a) Camera / frame-aligned TC: the true value IS an integer, but
--       float64 representation of the decimal MST string produces noise
--       like 1856918.9999… instead of 1856919. Resolve treats these as
--       integer-aligned; snap-to-nearest is correct.
--   (b) BWF sub-frame TC (Helen): the true value is genuinely fractional
--       (e.g. 2731.84 frames — BWF time_reference is sample-precise and
--       can land between video frames). Resolve EDL takes the floor;
--       snap-to-nearest produces the wrong frame.
--
-- Discriminator: if (mst*rate) lands within float64-roundoff (epsilon
-- below) of an integer, treat as case (a) and round-to-nearest. Else
-- treat as case (b) and floor. The epsilon must be small enough to
-- never false-flag a genuine sub-frame TC as float64 noise, and large
-- enough to absorb the noise from a 5-digit-decimal MST times a 5-digit
-- native_rate. 1e-4 is conservative: float64 ULP at 10^9 is ~10^-7,
-- well below 10^-4; no real audio/video sub-frame TC lands within 1/10000
-- of a frame boundary by accident.
local MST_FLOAT_EPSILON = 1e-4

function M.mst_to_tc_origin(mst_seconds, native_rate)
    assert(type(mst_seconds) == "number" and mst_seconds >= 0, string.format(
        "drp_importer.mst_to_tc_origin: mst_seconds must be non-negative number; got %s",
        tostring(mst_seconds)))
    assert(type(native_rate) == "number" and native_rate > 0, string.format(
        "drp_importer.mst_to_tc_origin: native_rate must be positive number; got %s",
        tostring(native_rate)))
    local product = mst_seconds * native_rate
    local floor_val = math.floor(product)
    local frac = product - floor_val
    if frac < MST_FLOAT_EPSILON then
        return floor_val
    end
    if frac > 1 - MST_FLOAT_EPSILON then
        return floor_val + 1
    end
    -- Genuinely sub-integer TC origin (e.g. Helen BWF). Floor matches
    -- Resolve EDL semantics; the sub-integer residual is recovered
    -- downstream via the source_in/clip-subframe machinery.
    return floor_val
end

--- Read all data from a local file handle (io.open), asserting on failure.
-- @param handle file: open file handle from io.open
-- @param context string: caller name for assert message
-- @return string: file contents
local function file_read_all(handle, context)
    local data, err = handle:read("*all")
    assert(data, string.format("%s: read(*all) failed: %s", context, tostring(err)))
    return data
end

--- Unzip .drp file to temporary directory
-- @param drp_path string: Path to .drp file
-- @return string|nil: Temp directory path, or nil on error
-- @return string|nil: Error message if failed
local function extract_drp(drp_path)
    local tmp_dir = os.tmpname()
    os.remove(tmp_dir)  -- Remove the file, we want a directory
    local ok_mkdir, mkdir_err = qt_fs_mkdir_p(tmp_dir)
    assert(ok_mkdir, "drp_importer: mkdir " .. tmp_dir .. " failed: " .. tostring(mkdir_err))

    local cmd = string.format('unzip -q "%s" -d "%s"', drp_path, tmp_dir)
    local result = os.execute(cmd)

    if result ~= 0 then
        return nil, "Failed to extract .drp archive"
    end

    return tmp_dir, nil
end

--- Parse XML file using C++ QXmlStreamReader.
-- Returns {tag, text, attrs, children} table tree.
-- @param xml_path string: Path to XML file
-- @return table|nil: Root element table, or nil on error
-- @return string|nil: Error message if failed
local function parse_xml_file(xml_path)
    assert(qt_xml_parse, "qt_xml_parse not available (requires C++ bindings)")
    return qt_xml_parse(xml_path)
end

--- Parse XML from string using C++ QXmlStreamReader.
-- @param content string: XML content
-- @return table|nil: Root element table, or nil on error
-- @return string|nil: Error message if failed
local function parse_xml_string(content)
    assert(qt_xml_parse_string, "qt_xml_parse_string not available (requires C++ bindings)")
    if not content or content == "" then
        return nil, "Empty XML content"
    end
    return qt_xml_parse_string(content)
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

-- Read a numeric XML element's text. nil element → 0 (missing is a valid
-- "absent" signal). Element present but text non-numeric → assert (rule
-- 2.13: missing data fails loud, doesn't silently become 0). `label` is
-- surfaced in the error message so a bad fixture is diagnosable.
local function get_number_or_assert(elem, label)
    if not elem then return 0 end
    local txt = get_text(elem)
    local n = tonumber(txt)
    assert(n, string.format(
        "DRP: <%s> text is not numeric: %q (parser bug or malformed input)",
        tostring(label), tostring(txt)))
    return n
end

-- Local aliases for frequently-used drp_binary functions
local decode_hex_double_at = drp_binary.decode_hex_double_at
local decode_hex_double = drp_binary.decode_hex_double
local decode_hex_resolution = drp_binary.decode_hex_resolution
local extract_ui_state_double = drp_binary.extract_ui_state_double
local decode_bt_video_time = drp_binary.decode_bt_video_time
local decode_bt_audio_duration = drp_binary.decode_bt_audio_duration
local decode_effect_filters_volume_db = drp_binary.decode_effect_filters_volume_db
local decode_media_timemap = drp_binary.decode_media_timemap
local decode_bt_clip_path = drp_binary.decode_bt_clip_path
local eval_curve = drp_binary.eval_curve




--- Extract original source file path from a MediaPool master clip element.
-- Searches BtVideoInfo and BtAudioInfo children for Clip binary blobs.
-- @param clip_elem table: Sm2MpVideoClip or Sm2MpAudioClip XML element
-- @return string|nil: decoded original path, or nil if no blob found/parseable
local function extract_original_path(clip_elem)
    -- Get XML name for fallback (blob filename can be garbled for audio clips)
    local name_elem = find_element(clip_elem, "Name")
    local xml_name = name_elem and get_text(name_elem)

    -- Try BtVideoInfo first (video master clips — blob filename is reliable)
    local bt_video = find_element(clip_elem, "BtVideoInfo")
    if bt_video then
        local blob_elem = find_direct_child(bt_video, "Clip")
        if blob_elem then
            local path, directory = decode_bt_clip_path(get_text(blob_elem))
            if path then return path end
            if directory and xml_name then return directory .. "/" .. xml_name end
        end
    end

    -- Try BtAudioInfo (audio master clips). Trust the blob's full path when
    -- decode_bt_clip_path returns a non-nil path — it already rejects blobs
    -- where the filename contains control characters (the "unreliable" case).
    -- The blob preserves filename whitespace that the XML parser strips from
    -- <Name>, so paths like '/…/Temp Tracks/ Return 2 - Max Richter.mp3' only
    -- survive the import when sourced from the blob.
    local bt_audio = find_element(clip_elem, "BtAudioInfo")
    if bt_audio then
        local blob_elem = find_direct_child(bt_audio, "Clip")
        if blob_elem then
            local path, directory = decode_bt_clip_path(get_text(blob_elem))
            if path then return path end
            if directory and xml_name then return directory .. "/" .. xml_name end
        end
    end

    return nil
end

--- Extract <OriginalClip> substitution history attached to a timeline clip.
-- Resolve records the pre-substitution state (e.g., pre-relink path, pre-
-- replace clip) as a nested <OriginalClip> containing an Sm2Ti*Clip element.
-- These aren't playable on the timeline — they're archival — so the data is
-- captured here as structured metadata for the active clip rather than
-- promoted into the media list.
-- @param clip_elem table: the active clip XML element
-- @return table|nil: {name, file_path, file_uuid, media_start_time} or nil
local function extract_original_clip(clip_elem)
    local oc = find_direct_child(clip_elem, "OriginalClip")
    if not oc then return nil end

    -- The OriginalClip wraps a single Sm2TiVideoClip or Sm2TiAudioClip child
    -- describing the previous state. Its fields use the same tag names as a
    -- regular clip.
    local inner = find_direct_child(oc, "Sm2TiVideoClip")
        or find_direct_child(oc, "Sm2TiAudioClip")
    if not inner then return nil end

    local function text_or_nil(tag)
        local s = get_text(find_direct_child(inner, tag))
        return (s and s ~= "") and s or nil
    end

    local file_path = text_or_nil("MediaFilePath")
    local file_uuid = text_or_nil("MediaRef")
    if not file_path and not file_uuid then return nil end  -- nothing to record

    return {
        name = text_or_nil("Name"),
        file_path = file_path,
        file_uuid = file_uuid,
        media_start_time = tonumber(get_text(find_direct_child(inner, "MediaStartTime"))),
    }
end

--- Extract media duration from a MediaPool master clip's binary blobs.
-- Video master clips: BtVideoInfo > Time → NumFrames (video frame count)
-- Audio-only clips: BtAudioInfo > TracksBA or EmbeddedAudioVec > ... > TracksBA
-- Video MCs with embedded audio: Time blob takes priority (already in frames)
--
-- For video MCs: returns {num_frames = N} (already in video frames)
-- For audio-only MCs: returns {audio_duration = {samples=N, sample_rate=N}}
--   (caller converts to frames using project fps)
-- @param clip_elem table: Sm2MpVideoClip or Sm2MpAudioClip XML element
-- @return table|nil: duration info, or nil if no blob found/parseable
local function extract_media_duration(clip_elem)
    local info = {}

    -- Video: BtVideoInfo > Time
    local bt_video = find_element(clip_elem, "BtVideoInfo")
    if bt_video then
        local time_elem = find_direct_child(bt_video, "Time")
        if time_elem then
            local result = decode_bt_video_time(get_text(time_elem))
            if result and result.num_frames and result.num_frames > 0 then
                info.num_frames = result.num_frames
                info.frame_rate = result.frame_rate
            end
        end
    end

    -- Audio: BtAudioInfo > TracksBA (also under EmbeddedAudioVec for BRAW/MOV)
    local bt_audio = find_element(clip_elem, "BtAudioInfo")
    if bt_audio then
        local tracks_elem = find_direct_child(bt_audio, "TracksBA")
        if tracks_elem then
            local result = decode_bt_audio_duration(get_text(tracks_elem))
            if result and result.duration_samples and result.duration_samples > 0 then
                info.audio_duration = {
                    samples      = result.duration_samples,
                    sample_rate  = result.sample_rate,
                    num_channels = result.num_channels,
                }
            end
        end
    end

    if not info.num_frames and not info.audio_duration then
        return nil
    end
    return info
end

--- Extract the file's original container TC origin from BtAudioInfo.TracksBA.StartTime.
-- This is the file's real TC, unaffected by Resolve's Set Timecode override.
-- Returns seconds since midnight, or nil if TracksBA is missing/unparseable.
-- @param clip_elem table: Sm2MpVideoClip or Sm2MpAudioClip XML element
-- @return number|nil: start_time in seconds, or nil
local function extract_file_tc_seconds(clip_elem)
    local bt_audio = find_element(clip_elem, "BtAudioInfo")
    if not bt_audio then return nil end
    local tracks_elem = find_direct_child(bt_audio, "TracksBA")
    if not tracks_elem then return nil end
    local result = decode_bt_audio_duration(get_text(tracks_elem))
    if not result then return nil end
    return result.start_time_seconds  -- nil if StartTime field absent from TLV
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

    -- Unparseable input: fail loud rather than masking as frame 0 (which is a
    -- legitimate source-start value). Empty/missing input is handled at the
    -- top of this function; reaching here means a tag was present with a
    -- non-empty, non-rational, non-numeric body.
    error(string.format(
        "parse_resolve_timecode: unparseable timecode %q (frame_rate=%s)",
        tostring(timecode_str), tostring(frame_rate)))
end

--- Parse SequenceTabsData from a Resolve FieldsBlob hex string.
-- The FieldsBlob stores binary fields; SequenceTabsData contains the ACTUALLY
-- open timeline tabs (not the full MRU/history in TimelineHandleVec).
--
-- Binary layout after the ASCII "SequenceTabsData" field name:
--   3 padding bytes, then N+2 UUID slots:
--   [active_uuid] [count as 3-byte BE int] [uuid_1] ... [uuid_N] [active_uuid_again]
--   Each UUID: 0x00 0x48 (length=72) + 36 chars UTF-16-BE
--
-- @param hex_str string|nil: hex-encoded FieldsBlob content
-- @return table: { tab_ids = {uuid, ...}, active_id = uuid|nil }
local function parse_fields_blob_tabs(hex_str)
    local empty = { tab_ids = {}, active_id = nil }
    if not hex_str or hex_str == "" then return empty end

    -- Convert hex to byte string
    local bytes = {}
    for i = 1, #hex_str - 1, 2 do
        local byte = tonumber(hex_str:sub(i, i + 1), 16)
        if not byte then return empty end
        bytes[#bytes + 1] = string.char(byte)
    end
    local data = table.concat(bytes)

    -- Find ASCII "SequenceTabsData" (17 bytes, preceded by length byte 0x11)
    local marker = "SequenceTabsData"
    local pos = data:find(marker, 1, true)
    if not pos then return empty end

    -- Helper: scan forward from offset, skip zero padding, read UUID.
    -- UUID format: 0x48 length byte (=72), then 72 bytes of UTF-16-BE (36 chars).
    -- Returns uuid_string, next_offset or nil, offset.
    local function read_uuid(offset)
        -- Skip zero padding (up to 8 bytes)
        local skipped = 0
        while offset <= #data and data:byte(offset) == 0 and skipped < 8 do
            offset = offset + 1
            skipped = skipped + 1
        end
        -- Expect length byte 0x48 (72)
        if offset > #data or data:byte(offset) ~= 0x48 then
            return nil, offset
        end
        offset = offset + 1  -- skip length byte

        -- Read 36 UTF-16-BE characters (72 bytes)
        if offset + 71 > #data then return nil, offset end
        local chars = {}
        for i = 0, 35 do
            local hi = data:byte(offset + i * 2)
            local lo = data:byte(offset + i * 2 + 1)
            if not hi or not lo then return nil, offset end
            if hi ~= 0 then return nil, offset end  -- ASCII range only
            chars[#chars + 1] = string.char(lo)
        end
        local uuid = table.concat(chars)
        offset = offset + 72

        -- Validate UUID format (8-4-4-4-12 hex)
        if not uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
            return nil, offset
        end
        return uuid, offset
    end

    -- Skip past field name (variable padding follows)
    local offset = pos + #marker

    -- Read active UUID (first UUID after field name, preceded by padding)
    local active_uuid, next_offset = read_uuid(offset)
    if not active_uuid then return empty end
    offset = next_offset

    -- Read 3-byte BE count (preceded by zero padding)
    while offset <= #data and data:byte(offset) == 0 do offset = offset + 1 end
    if offset + 2 > #data then return empty end
    -- The count byte is non-zero (we skipped zeros). Read as single byte.
    local count = data:byte(offset)
    offset = offset + 1
    if count > 100 then return empty end  -- sanity: can't have 100+ tabs

    -- Read tab UUIDs
    local tab_ids = {}
    for _ = 1, count do
        local uuid
        uuid, offset = read_uuid(offset)
        if not uuid then break end
        tab_ids[#tab_ids + 1] = uuid
    end

    return { tab_ids = tab_ids, active_id = active_uuid }
end

--- Parse project.xml to extract project metadata
-- @param project_elem table: XML element for <Project>
-- @return table: Project metadata
local function parse_project_metadata(project_elem)
    local project = {
        name = "Untitled Project",
        settings = {
            master_clock_hz = subframe_math.MASTER_CLOCK_HZ,
            default_fps = { num = 24, den = 1 },
        }
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

    -- Collect raw inputs for tab/active-timeline resolution. Final resolution
    -- happens in parse_drp_file after build_timeline_metadata_map exists,
    -- because priority 2 (TimelineHandleVec) needs Sm2Timeline → Sm2Sequence
    -- translation via the metadata map.
    --
    -- Priority 1 input: FieldsBlob > SequenceTabsData — authoritative tab
    -- workspace saved by some Resolve versions. UUIDs are Sm2Sequence.DbIds.
    local fields_blob_elem = find_direct_child(project_elem, "FieldsBlob")
    local blob_hex = fields_blob_elem and get_text(fields_blob_elem) or nil
    project.sequence_tabs_data = parse_fields_blob_tabs(blob_hex)

    -- Priority 2 input: <TimelineHandleVec> + <CurrentTimelineIndex>.
    -- Element UUIDs are Sm2Timeline.DbIds (NOT Sm2Sequence.DbIds) — they must
    -- be mapped through timeline_id_map to get the sequence id.
    project.timeline_handle_vec_ids = {}
    local handle_vec_elem = find_direct_child(project_elem, "TimelineHandleVec")
    if handle_vec_elem then
        for _, child in ipairs(handle_vec_elem.children or {}) do
            if child.tag == "Element" then
                local id = get_text(child)
                if id and id ~= "" then
                    table.insert(project.timeline_handle_vec_ids, id)
                end
            end
        end
    end
    local cti_elem = find_direct_child(project_elem, "CurrentTimelineIndex")
    if cti_elem then
        project.current_timeline_index = tonumber(get_text(cti_elem))
        assert(project.current_timeline_index,
            "parse_project_metadata: non-numeric <CurrentTimelineIndex>: "
            .. tostring(get_text(cti_elem)))
    end

    -- Final resolved outputs (populated by resolve_project_tab_ids).
    project.open_timeline_ids = {}
    project.active_timeline_id = nil

    return project
end

--- Resolve which sequence ids are open tabs / which is active, using the
-- inputs collected during parse_project_metadata plus the Sm2Timeline-to-
-- Sm2Sequence map built from the MediaPool XML.
--
-- Priority:
--   1. FieldsBlob SequenceTabsData non-empty (newer Resolve saves)
--   2. TimelineHandleVec[CurrentTimelineIndex] via timeline_id_map
--      (older / archive-export saves; yields a single active tab)
-- If neither is available, leaves project.open_timeline_ids empty and the
-- import settles for whatever find_most_recent produces at open time.
--
-- @param project table: project produced by parse_project_metadata
-- @param timeline_id_map table: Sm2Timeline.DbId → {name, seq_id}
local function resolve_project_tab_ids(project, timeline_id_map)
    local tabs_data = project.sequence_tabs_data
    if tabs_data and tabs_data.tab_ids and #tabs_data.tab_ids > 0 then
        project.open_timeline_ids = tabs_data.tab_ids
        project.active_timeline_id = tabs_data.active_id
        return
    end

    local handle_ids = project.timeline_handle_vec_ids
    local cti = project.current_timeline_index

    -- Case 1 (legitimate empty): neither source present.
    if not handle_ids or #handle_ids == 0 then
        return
    end

    -- Case 4: handle_vec non-empty but CurrentTimelineIndex missing.
    assert(cti, string.format(
        "drp_importer.resolve_project_tab_ids: TimelineHandleVec has %d entries "
        .. "but <CurrentTimelineIndex> is missing — DRP file corruption",
        #handle_ids))

    -- Case 2: CTI out of range for handle vec.
    assert(cti >= 0 and cti < #handle_ids, string.format(
        "drp_importer.resolve_project_tab_ids: CurrentTimelineIndex=%d out of "
        .. "range for TimelineHandleVec of length %d — DRP file corruption",
        cti, #handle_ids))

    -- Lua arrays are 1-based; CurrentTimelineIndex is 0-based.
    local tl_db_id = handle_ids[cti + 1]
    local mapped = tl_db_id and timeline_id_map[tl_db_id]

    -- Case 3: handle id has no corresponding Sm2Sequence in MediaPool.
    assert(mapped and mapped.seq_id, string.format(
        "drp_importer.resolve_project_tab_ids: TimelineHandleVec[%d]=%s has no "
        .. "corresponding Sm2Sequence in MediaPool — DRP file corruption or "
        .. "parser bug", cti, tostring(tl_db_id)))

    project.open_timeline_ids = { mapped.seq_id }
    project.active_timeline_id = mapped.seq_id
end

-- Exported for black-box testing of the case-1..case-4 assertion set.
M._resolve_project_tab_ids = resolve_project_tab_ids

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
            duration = get_number_or_assert(duration_elem, "Duration"),
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
--- Parse a single master clip element from MediaPool XML.
-- NOTE on <Name>: Always contains the original filename, NOT the user's display rename.
-- Resolve stores MC renames in FieldsBlob, which is encrypted when grading data is present
-- (format flag fd60 = encrypted, fd20 = plaintext without grading). Renames don't survive
-- DRP import. Reversing FieldsBlob encryption would be needed to support this.
local function parse_master_clip_element(clip_elem, folder_id)
    local db_id = clip_elem.attrs and clip_elem.attrs.DbId
    if not db_id then return nil end

    local name_elem = find_direct_child(clip_elem, "Name")
    local mark_in_elem = find_direct_child(clip_elem, "MarkIn")
    local mark_out_elem = find_direct_child(clip_elem, "MarkOut")
    local playhead_elem = find_direct_child(clip_elem, "CurPlayheadPosition")

    -- Decode original source path from BtVideoInfo/BtAudioInfo binary blob
    local original_path = extract_original_path(clip_elem)

    -- Parse authoritative media duration from Time/TracksBA blobs
    local duration_info = extract_media_duration(clip_elem)

    -- Extract file's original container TC from TracksBA.StartTime (FR-001)
    local file_tc_seconds = extract_file_tc_seconds(clip_elem)

    local master_clip = {
        id = db_id,
        name = name_elem and get_text(name_elem) or "Untitled",
        folder_id = folder_id,
        mark_in = mark_in_elem and tonumber(get_text(mark_in_elem)) or nil,
        mark_out = mark_out_elem and tonumber(get_text(mark_out_elem)) or nil,
        playhead = playhead_elem and tonumber(get_text(playhead_elem)) or nil,
        clip_type = clip_elem.tag == "Sm2MpVideoClip" and "video" or "audio",
        file_path = original_path,
        file_tc_seconds = file_tc_seconds,  -- file's container TC origin (seconds since midnight)
    }

    -- Store duration + rate info from blob
    if duration_info then
        if duration_info.num_frames then
            master_clip.num_frames = duration_info.num_frames
            master_clip.frame_rate = duration_info.frame_rate
        end
        if duration_info.audio_duration then
            master_clip.audio_duration = duration_info.audio_duration
        end
    end

    -- Collect BtAudioInfo DbIds this pool item OWNS (so callers can
    -- reverse-index btai_dbid → owning pool item). A video pool item
    -- owns the BtAudioInfo(s) under its EmbeddedAudioVec (camera-scratch
    -- audio); an audio pool item owns the BtAudioInfo(s) under its own
    -- EmbeddedAudioVec (the external WAV's audio info).
    master_clip.own_bt_audio_info_ids = {}
    for _, bai in ipairs(find_all_elements(clip_elem, "BtAudioInfo")) do
        if bai.attrs and bai.attrs.DbId then
            master_clip.own_bt_audio_info_ids[#master_clip.own_bt_audio_info_ids + 1]
                = bai.attrs.DbId
        end
    end

    -- Synced-clip linkage (video pool items only).
    --
    -- <AudioSource> tells us whether the pool item plays its own
    -- embedded audio (EMBEDDED) or external synced audio (CUSTOM).
    -- The FieldsBlob's decompressed payload embeds an ordered list of
    -- MediaRef UUIDs — each one is a BtAudioInfo DbId that this pool
    -- item references. For unsynced, all refs land on own_bt_audio_info_ids.
    -- For synced, refs split between the external WAV's BtAudioInfo and
    -- the video's own embedded. Callers walk audio_refs + the
    -- btai_dbid→pool_item index to resolve external audio pool items.
    if clip_elem.tag == "Sm2MpVideoClip" then
        local audio_source_elem = find_direct_child(clip_elem, "AudioSource")
        if audio_source_elem then
            master_clip.audio_source = get_text(audio_source_elem)
        end

        local fb_elem = find_direct_child(clip_elem, "FieldsBlob")
        local fb_hex = fb_elem and get_text(fb_elem)
        if fb_hex and fb_hex ~= "" then
            local decoded, fb_err = drp_binary.decode_fields_blob(fb_hex)
            if decoded then
                master_clip.audio_refs = drp_binary.extract_media_refs(decoded)
            else
                -- Missing zstd binding or malformed blob: surface via log,
                -- continue without audio_refs so the importer can still
                -- produce basic (non-synced-aware) media records.
                log.warn("drp_importer: FieldsBlob decode failed for %s (%s): %s",
                    master_clip.name or "?", db_id, tostring(fb_err))
            end
        end
    end

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
            local elem_count = 0
            local clip_count = 0
            for _, element in ipairs(media_vec.children or {}) do
                if element.tag == "Element" then
                    elem_count = elem_count + 1
                    for _, child in ipairs(element.children or {}) do
                        if child.tag == "Sm2MpVideoClip" or child.tag == "Sm2MpAudioClip" then
                            local master_clip = parse_master_clip_element(child, db_id)
                            if master_clip then
                                clip_count = clip_count + 1
                                table.insert(result.master_clips, master_clip)
                            end
                        end
                    end
                end
            end
            if elem_count > 0 then
                log.detail("parse_mp_folder: %s — %d elements, %d clips parsed",
                    mp_file_path:match("([^/]+/MpFolder%.xml)$") or mp_file_path,
                    elem_count, clip_count)
            end
        end
    end

    return result
end

--- Parse full MediaPool hierarchy recursively
-- @param tmp_dir string: Extracted .drp temp directory
-- @return table: { folders = {...}, master_clips = {...}, folder_map = {...} }
local function parse_media_pool_hierarchy(tmp_dir, pump)
    pump = pump or function() end
    local folders = {}
    local master_clips = {}
    local folder_map = {}  -- id -> folder

    -- Find all MpFolder.xml files recursively
    local find_cmd = string.format('find "%s/MediaPool" -name "MpFolder.xml" 2>/dev/null', tmp_dir)
    local mp_files_raw = shell_capture(find_cmd, "parse_media_pool_hierarchy")

    local mp_file_list = {}
    for f in mp_files_raw:gmatch("[^\n]+") do
        mp_file_list[#mp_file_list + 1] = f
    end

    -- Parse each MpFolder.xml
    for file_idx, mp_file in ipairs(mp_file_list) do
        if file_idx % 5 == 0 then
            pump(math.floor(file_idx / #mp_file_list * 100))
        end
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
-- @param timeline_id_map table: Sm2Timeline DbId → {name, seq_id} (for TimelineHandleVec)
-- @param timeline_elem table: <Sm2Timeline> XML element
-- @param folder_id string|nil: parent folder DbId (from Sm2MpTimelineClip)
local function extract_timeline_metadata(metadata_map, timeline_id_map, timeline_elem, folder_id, mp_clip_elem)
    local name_elem = find_direct_child(timeline_elem, "Name")
    local timeline_name = name_elem and get_text(name_elem) or nil
    if not timeline_name or timeline_name == "" then return end

    -- Structure: <Sm2Timeline DbId="..."><Sequence><Sm2Sequence DbId="..."><FrameRate>hex
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

    -- MediaExtents: two LE doubles [start_tc_seconds, end_tc_seconds]
    local start_tc_seconds = nil
    local media_extents_elem = find_direct_child(sm2_seq, "MediaExtents")
    if media_extents_elem then
        start_tc_seconds = decode_hex_double(get_text(media_extents_elem))
    end

    -- UIElementsState on Sm2Sequence: timeline viewport scale (pixels per frame)
    local ui_scale = nil
    local ui_state_elem = find_direct_child(sm2_seq, "UIElementsState")
    if ui_state_elem then
        ui_scale = extract_ui_state_double(get_text(ui_state_elem), "UI_SEQUENCE_SCALE")
    end

    -- CurPlayheadPosition on Sm2MpTimelineClip: playhead in frames relative to start TC
    local cur_playhead = nil
    if mp_clip_elem then
        local ph_elem = find_direct_child(mp_clip_elem, "CurPlayheadPosition")
        if ph_elem then
            cur_playhead = tonumber(get_text(ph_elem))
        end
    end

    metadata_map[seq_id] = {
        name = timeline_name,
        fps = fps,
        width = width,
        height = height,
        folder_id = folder_id,
        start_tc_seconds = start_tc_seconds,
        ui_scale = ui_scale,
        cur_playhead_relative = cur_playhead,
    }

    -- Map Sm2Timeline DbId → name (for resolving TimelineHandleVec)
    local timeline_db_id = timeline_elem.attrs and timeline_elem.attrs.DbId
    if timeline_db_id and timeline_id_map then
        timeline_id_map[timeline_db_id] = {
            name = timeline_name,
            seq_id = seq_id,
        }
    end
end

local function build_timeline_metadata_map(tmp_dir, pump)
    pump = pump or function() end
    local metadata_map = {}
    local timeline_id_map = {}  -- Sm2Timeline DbId → {name, seq_id}

    local find_cmd = string.format('find "%s/MediaPool" -name "MpFolder.xml" 2>/dev/null', tmp_dir)
    local mp_files_raw = shell_capture(find_cmd, "build_timeline_metadata_map")

    local mp_file_list = {}
    for f in mp_files_raw:gmatch("[^\n]+") do
        mp_file_list[#mp_file_list + 1] = f
    end

    for file_idx, mp_file in ipairs(mp_file_list) do
        if file_idx % 5 == 0 then
            pump(math.floor(file_idx / #mp_file_list * 100))
        end
        local mp_root = parse_xml_file(mp_file)
        if mp_root then
            -- Primary: find Sm2MpTimelineClip elements (contain folder ref + nested Sm2Timeline)
            local timeline_clips = find_all_elements(mp_root, "Sm2MpTimelineClip")
            for _, tc_elem in ipairs(timeline_clips) do
                local folder_ref_elem = find_direct_child(tc_elem, "MpFolder")
                local tc_folder_id = folder_ref_elem and get_text(folder_ref_elem) or nil

                local nested_timeline = find_element(tc_elem, "Sm2Timeline")
                if nested_timeline then
                    extract_timeline_metadata(metadata_map, timeline_id_map, nested_timeline, tc_folder_id, tc_elem)
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
                            extract_timeline_metadata(metadata_map, timeline_id_map, timeline_elem, nil)
                        end
                    end
                end
            end
        end
    end

    return metadata_map, timeline_id_map
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

--- Parse a DRP frame value string: "frames" or "frames|hex_subframe".
-- The hex suffix is an LE IEEE 754 double encoding a fractional-frame
-- offset (0.0–1.0), used for sub-frame audio positioning on the timeline.
-- @param text string|nil: raw DRP field text
-- @param clip_name string: clip name for error messages
-- @param field_name string: field name for error messages
-- @return number|nil: integer frames
-- @return number: subframe fraction (0.0 if no hex suffix)
local function parse_drp_frame_value(text, clip_name, field_name)
    if not text then return nil, 0 end
    local num_str, hex_part = text:match("^(%d+)|?(%x*)")
    local num = num_str and tonumber(num_str)
    assert(num, string.format(
        "parse_resolve_tracks: clip '%s' %s has no numeric value (raw='%s')",
        clip_name, field_name, text))
    local subframe = 0
    if hex_part and #hex_part >= 16 then
        local decoded = decode_hex_double_at(hex_part, 0)
        if decoded and decoded >= 0 and decoded < 1.0 then
            subframe = decoded
        end
    end
    return num, subframe
end

--- Compose the V↔A pair key from <LinkedItemSync> + <Name>.
--
-- <LinkedItemSync> is a parent-take ID Resolve assigns to every
-- timeline clip that originated from one continuous capture — the
-- same value appears on each post-blade segment of that take. Its
-- actual V↔A pair granularity is per shot name within a take, so
-- the key downstream code groups on is (sync_value, name).
--
-- Returned value is opaque to importer_core — equality alone is
-- what matters. Empty (`<LinkedItemSync/>`) or absent element →
-- nil (unlinked clip). Non-numeric, non-integer, or unrepresentable
-- content asserts (Rule 1.14).
--
-- The composed key uses ASCII Unit Separator (\x1F) between fields
-- so it can never collide with clip-name content; the helper
-- asserts the name is free of that separator.
--
-- @param clip_elem table: Sm2TiVideoClip or Sm2TiAudioClip element
-- @param clip_name string: clip's <Name> (already resolved by caller)
-- @return string|nil: opaque pair key, or nil for unlinked clips
local PAIR_KEY_SEP = "\x1F"
local function extract_linked_item_sync(clip_elem, clip_name)
    assert(type(clip_elem) == "table",
        "extract_linked_item_sync: clip_elem must be a table (got "
        .. type(clip_elem) .. ")")
    assert(type(clip_name) == "string" and clip_name ~= "",
        "extract_linked_item_sync: clip_name must be a non-empty string (got "
        .. type(clip_name) .. ")")

    local lis_elem = find_element(clip_elem, "LinkedItemSync")
    local lis_text = lis_elem and get_text(lis_elem)
    if not lis_text or lis_text == "" then return nil end

    -- Resolve emits LinkedItemSync in two forms:
    --   "42"                              plain signed integer
    --   "-4799|00000000000000bd"          signed int + extended low bits
    -- (same `<int>|<hex>` shape as <Start>/<In>; see parse_drp_frame_value).
    -- The pair key is opaque (equality only), so the raw text composes
    -- straight into the key — distinct hex tails yield distinct keys, which
    -- is what we want. Anything outside these two forms is malformed input.
    assert(lis_text:match("^%-?%d+$") or lis_text:match("^%-?%d+|%x+$"),
        string.format(
            "extract_linked_item_sync: clip '%s' has malformed LinkedItemSync " ..
            "'%s' (expected '<int>' or '<int>|<hex>')",
            clip_name, lis_text))
    assert(not clip_name:find(PAIR_KEY_SEP, 1, true), string.format(
        "extract_linked_item_sync: clip name '%s' contains the pair-key " ..
        "separator (\\x1F); pair-key composition would be ambiguous",
        clip_name))
    return lis_text .. PAIR_KEY_SEP .. clip_name
end

--- Parse Resolve tracks from sequence element
-- NSF: frame_rate is REQUIRED - DRP reliably encodes fps in metadata
-- @param seq_elem table: XML sequence element
-- @param frame_rate number: Frame rate from DRP metadata (required)
-- @return video_tracks, audio_tracks, media_lookup
local function parse_resolve_tracks(seq_elem, opts)
    local frame_rate = opts.frame_rate
    local media_ref_path_map = opts.media_ref_path_map
    local media_ref_name_map = opts.media_ref_name_map
    local media_ref_sample_rate_map = opts.media_ref_sample_rate_map

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

            -- MediaFilePath is authoritative — it always contains the correct full path.
            -- Proxy paths live in proxy.dat, not in MediaFilePath. The blob path is a
            -- fallback only: blob filenames can be garbled (protobuf field data leaking
            -- into filename bytes).
            if (not file_path or file_path == "") and media_ref_path_map then
                local media_ref = get_text(find_element(clip_elem, "MediaRef"))
                if media_ref ~= "" and media_ref_path_map[media_ref] then
                    file_path = media_ref_path_map[media_ref]
                end
            end

            local clip_name = get_text(find_element(clip_elem, "Name")) or file_path or "unnamed"

            -- NSF: Assert on missing required clip fields
            local start_elem = find_element(clip_elem, "Start")
            local duration_elem = find_element(clip_elem, "Duration")
            local in_elem = find_element(clip_elem, "In")

            assert(start_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Start element", clip_name))
            assert(duration_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Duration element", clip_name))

            local start_frames, start_subframe = parse_drp_frame_value(get_text(start_elem), clip_name, "Start")
            local duration_raw = parse_drp_frame_value(get_text(duration_elem), clip_name, "Duration")

            start_frames = math.floor(start_frames)
            duration_raw = math.floor(duration_raw)

            -- Extract <MediaStartTime> — file's TC origin in seconds since midnight.
            -- This is a per-file property (not per-clip). All clips from the same file
            -- share the same MediaStartTime. Stored on media + master clip for relink TC verify.
            local mst_elem = find_element(clip_elem, "MediaStartTime")
            local media_start_time = mst_elem and tonumber(get_text(mst_elem))

            -- Extract <MediaFrameRate> — LE hex-encoded double (first 16 chars).
            -- Available on all clips, even those without <MediaRef>.
            -- Provides frame_rate independent of blob propagation.
            local mfr_elem = find_element(clip_elem, "MediaFrameRate")
            local media_frame_rate = nil
            if mfr_elem then
                local mfr_hex = get_text(mfr_elem)
                if mfr_hex ~= "" and #mfr_hex >= 16 then
                    local decoded = decode_hex_double_at(mfr_hex, 0)
                    if decoded and decoded > 0 and decoded < 1000 then
                        media_frame_rate = decoded
                    end
                end
            end

            -- DRP field meanings (confirmed from real DRP XML analysis):
            --   <MediaStartTime> = file's TC origin in SECONDS since midnight (not per-clip)
            --   <In>             = source mark-in offset in TIMELINE FRAMES
            --   <Start>          = timeline position (frames)
            --   <Duration>       = timeline duration (frames)
            --
            -- source_in comes from <In>, NOT <MediaStartTime>.
            -- Empty/missing <In> means untrimmed (source_in = 0).
            local in_value = 0
            local in_sub_frame = 0.0
            local clip_speed = 1.0
            local in_text = in_elem and get_text(in_elem) or ""
            if in_text ~= "" then
                -- <In> is 'NN' or 'NN|<hex>'. NN is the whole-frame offset;
                -- the hex is a little-endian IEEE-754 double in [0, 1)
                -- representing the sub-frame fractional position within that
                -- frame. The fraction is applied only on unretimed clips —
                -- retimed clips get sub-frame precision from the MTBA curve's
                -- own keyframes, and adding the <In> fraction on top would
                -- double-count and produce rounding errors at frame boundaries.
                local num_part, hex_part = in_text:match("^(%d+)|?(%x*)")
                in_value = assert(num_part and tonumber(num_part), string.format(
                    "parse_resolve_tracks: clip '%s' <In> has no numeric prefix: '%s'",
                    clip_name, in_text))
                if hex_part and hex_part ~= "" then
                    if #hex_part < 16 then
                        log.warn("parse_resolve_tracks: clip '%s' <In> hex suffix too short (%d chars): '%s'",
                            clip_name, #hex_part, hex_part)
                    else
                        local frac = decode_hex_double_at(hex_part, 0)
                        if not frac then
                            log.warn("parse_resolve_tracks: clip '%s' <In> hex suffix failed to decode: '%s'",
                                clip_name, hex_part:sub(1, 16))
                        elseif frac >= 0.0 and frac < 1.0 then
                            in_sub_frame = frac
                        end
                        -- Values outside [0, 1) are not sub-frame offsets;
                        -- they occur on retimed clips where the hex is a
                        -- speed-ratio remnant (MTBA is authoritative). Leave
                        -- in_sub_frame at 0 — the retimed branch won't use it.
                    end
                end
            end

            -- MediaTimemapBA: authoritative speed/direction for retimed clips.
            -- MTBA is present on all retimed clips. Clips without MTBA are not
            -- retimed; <In>'s integer+sub-frame fully specifies the in-point.
            local retime_keyframes = nil
            local mtba_elem = find_element(clip_elem, "MediaTimemapBA")
            if mtba_elem then
                local mtba_hex = get_text(mtba_elem)
                -- 9-byte blobs (18 hex chars) = just media duration, no speed data.
                -- Larger blobs = version 1 with YMax/XMax/KeyframesBA.
                if #mtba_hex > 18 then
                    local mtba = decode_media_timemap(mtba_hex)
                    if mtba then
                        clip_speed = mtba.is_reverse and -mtba.speed_ratio or mtba.speed_ratio
                        retime_keyframes = mtba.keyframes
                        log.event("DRP retime: clip '%s' speed from MTBA: %.4f (YMax=%.2f XMax=%.2f reverse=%s kf=%d)",
                                  clip_name, clip_speed, mtba.y_max, mtba.x_max,
                                  tostring(mtba.is_reverse),
                                  retime_keyframes and #retime_keyframes or 0)
                    end
                end
            end

            local duration_timeline_frames = duration_raw
            local abs_speed = math.abs(clip_speed)

            -- Synthesize a constant-speed curve when MTBA exists but keyframes
            -- were discarded (parsed but failed sanity check). Without the curve,
            -- the no-retime path would treat in_value as source frames, ignoring
            -- the speed change entirely.
            if not retime_keyframes and abs_speed ~= 1.0 then
                retime_keyframes = {
                    { x = 0, y = 0 },
                    { x = 1e9, y = 1e9 * abs_speed },
                }
            end

            -- Compute media TC origin: <MediaStartTime> converted to clip-rate units.
            -- MST is seconds since midnight. When MST=0 or nil, media_tc_origin=0
            -- (file starts at 00:00:00:00 = file-relative = absolute TC).
            -- Source coordinates must be at the media's native rate to avoid
            -- lossy cross-rate rounding (e.g. 25fps sequence + 120fps media,
            -- or 25fps sequence + 44100Hz audio).
            -- Video: use <MediaFrameRate> (media's fps), fall back to sequence fps.
            -- Audio: use pool master clip's sample_rate (no fallback).
            local native_rate
            if track_type == "AUDIO" then
                local media_ref = get_text(find_element(clip_elem, "MediaRef"))
                native_rate = media_ref_sample_rate_map and media_ref ~= ""
                    and media_ref_sample_rate_map[media_ref]
                if not native_rate then
                    local is_media = media_ref_path_map and media_ref ~= ""
                        and media_ref_path_map[media_ref]
                    if not is_media then
                        -- Not in path map → nested sequence (compound/synced/multicam
                        -- clip), not a media file — skip it.
                        log.detail("skipping nested sequence audio clip '%s' (MediaRef=%s)",
                            clip_name, media_ref)
                        goto continue_clip
                    end
                    -- In path map but no sample rate → video-only media with
                    -- linked audio track (silent companion clip). No audio
                    -- coordinates to compute — skip.
                    log.detail("skipping audio clip '%s' for video-only media (MediaRef=%s, no sample rate)",
                        clip_name, media_ref)
                    goto continue_clip
                end
            else
                assert(media_frame_rate, string.format(
                    "parse_resolve_tracks: clip '%s' has no <MediaFrameRate> — cannot determine native rate",
                    clip_name))
                native_rate = media_frame_rate
            end

            local media_tc_origin = 0
            local in_offset  -- <In> converted to native units (file-relative)
            local source_duration

            -- Compute media TC origin from <MediaStartTime> (seconds since
            -- midnight). 018 Helen fix: discriminator-aware conversion
            -- (camera files with float64-noise around an integer snap to
            -- nearest; BWF files with genuine sub-frame TC floor to match
            -- Resolve EDL). Pre-fix `math.floor(mst*rate + 0.5)` worked for
            -- camera but produced a 1-frame off-by-one for Helen-style BWF.
            if media_start_time and media_start_time > 0 then
                media_tc_origin = M.mst_to_tc_origin(media_start_time, native_rate)
            end

            -- <In> is in playback timeline frames at sequence rate (the X axis
            -- of the MTBA retime curve). Walk the curve to get source seconds,
            -- then convert to native_rate units (media frames or samples).
            if retime_keyframes and #retime_keyframes >= 2 then
                local in_sec = in_value / frame_rate
                local out_sec = (in_value + duration_raw) / frame_rate
                local y_in_sec = eval_curve(retime_keyframes, in_sec)
                local y_out_sec = eval_curve(retime_keyframes, out_sec)
                -- Normalize reverse curves up front: y_first is the lower source
                -- time (first frame in ascending source order), y_last the higher.
                -- Mark clip_speed negative so the source_in/source_out swap at the
                -- end of this function runs.
                local y_first, y_last = y_in_sec, y_out_sec
                if y_out_sec < y_in_sec then
                    y_first, y_last = y_out_sec, y_in_sec
                    clip_speed = -math.abs(clip_speed)
                end
                -- Snap at FRAME granularity (not sample). The curve-eval lands
                -- within a few float ULPs of the true seconds value; at
                -- native_rate=48000 a 1-ULP miss amplifies to a 1-sample shift.
                -- Resolve's Media-Managed exports cut source on whole-frame
                -- boundaries (no sub-frame audio edits, video is frame-
                -- quantized) so the result must land on a frame boundary.
                --
                -- Empirical rule (matches Resolve's Media-Manage exports across
                -- this branch's project for both accel and decel curves):
                --   in:  CEIL  — the first whole source-frame whose span
                --                starts at-or-after y_first; this is the head
                --                boundary of the trimmed file.
                --   out: FLOOR — the last whole source-frame fully consumed
                --                by the clip; ceil would claim a partial frame
                --                past the file's tail.
                -- A small ULP-tolerance (1e-6 frames ≈ 0.04 ms at 25 fps) keeps
                -- "essentially integer" values from snapping the wrong way.
                local y_in_frames   = y_first * frame_rate
                local y_last_frames = y_last  * frame_rate
                local in_frame  = math.ceil (y_in_frames   - 1e-6)
                local out_frame = math.floor(y_last_frames + 1e-6)
                -- Resolve writes retime keyframes whose first-anchor Y is
                -- occasionally sub-frame negative (observed Y in [-0.01, 0)
                -- seconds with zero bezier tangents — a direct Resolve
                -- encoding, not float noise). Resolve's Inspector shows
                -- Source In = media frame 0 for these clips; a frame before
                -- the file doesn't exist. Snap from -1 to 0 when y_first is
                -- within one frame of zero. Beyond that magnitude is a real
                -- parser bug: the assert below still fires.
                if in_frame < 0 and y_in_frames > -1.0 then
                    in_frame = 0
                end
                in_offset = math.floor(in_frame * native_rate / frame_rate + 0.5)
                source_duration =
                    math.floor(out_frame * native_rate / frame_rate + 0.5) - in_offset
            else
                -- No curve: <In> is source frames at sequence rate.
                -- Snap at FRAME granularity for the same reason as the retimed
                -- branch above: Resolve's Media-Managed exports cut source on
                -- whole-frame boundaries, so source_in / source_out must too.
                -- Without this, a clip with sub-frame <In> ends up with
                -- source_out = source_in + (timeline-duration × native_rate /
                -- frame_rate), which can land 1 frame past where Resolve cut
                -- the file (file = ceil(in_real) → floor(out_real), 1 frame
                -- shorter than naïve duration scaling when <In> has a fraction).
                local in_real_frames  = in_value + in_sub_frame
                local out_real_frames = in_real_frames + duration_raw
                local in_frame  = math.ceil (in_real_frames  - 1e-6)
                local out_frame = math.floor(out_real_frames + 1e-6)
                in_offset       = math.floor(in_frame  * native_rate / frame_rate + 0.5)
                source_duration =
                    math.floor(out_frame * native_rate / frame_rate + 0.5) - in_offset
            end

            -- Sanity: MST max = 86400s (midnight). At 48kHz = ~4.1B samples.
            assert(media_tc_origin >= 0 and media_tc_origin < 5e9, string.format(
                "parse_resolve_tracks: clip '%s' media_tc_origin=%d out of range (MST=%s)",
                clip_name, media_tc_origin, tostring(media_start_time)))
            assert(in_offset >= 0, string.format(
                "parse_resolve_tracks: clip '%s' in_offset=%d < 0 (in_value=%s speed=%s)",
                clip_name, in_offset, tostring(in_value), tostring(abs_speed)))

            -- source_in is ABSOLUTE TC in native units = file_tc_origin
            -- (media_tc_origin) + file-relative offset. Frames for video,
            -- samples for audio. The master sequence's timebase IS TC space:
            -- its media_refs sit at sequence_start = file_tc_origin spanning
            -- [tc_origin, tc_origin + file_duration]. Clips reference absolute
            -- TC into that timebase. C++ decode does file_pos = source_in -
            -- file_tc_origin to recover the file-relative position.
            local source_in_native = media_tc_origin + in_offset
            log.detail("  source_in: %s MST=%.4f tc_origin=%d in_val=%s in_off=%d src_in=%d dur=%d spd=%.3f %s",
                clip_name, media_start_time or 0, media_tc_origin,
                tostring(in_value), in_offset, source_in_native, source_duration or 0,
                abs_speed or 1, retime_keyframes and string.format("retime(%d kf)", #retime_keyframes) or "no-retime")

            -- Source extent in native units, file-relative — used downstream
            -- for media-row duration tracking (file length, not TC space).
            local source_extent_frames
            if track_type == "AUDIO" then
                source_extent_frames = math.floor(in_value) + duration_raw
            else
                source_extent_frames = in_offset + source_duration
            end
            assert(source_extent_frames >= 0, string.format(
                "parse_resolve_tracks: clip '%s' has negative source_extent_frames=%d",
                clip_name, source_extent_frames))

            -- Compute source_out, then swap for reverse clips.
            -- Reverse: source_in = high frame (playback start), source_out = low frame.
            local source_out_native = source_in_native + source_duration
            if clip_speed < 0 then
                source_in_native, source_out_native = source_out_native, source_in_native
            end

            -- Extract per-clip volume from EffectFiltersBA (direct child of clip element)
            local efba_elem = find_direct_child(clip_elem, "EffectFiltersBA")
            local efba_hex = efba_elem and get_text(efba_elem)
            local volume_linear = 1.0
            if efba_hex and efba_hex ~= "" then
                local volume_db = decode_effect_filters_volume_db(efba_hex)
                if volume_db then
                    volume_linear = 10 ^ (volume_db / 20)
                end
                -- nil = not a volume blob (different effect type, wrong size, etc.) → unity
            end

            local linked_item_sync = extract_linked_item_sync(clip_elem, clip_name)

            -- The clip's own Sm2Ti DbId. Real Resolve exports carry one on every
            -- timeline clip; per spec 023 FR-011b the importer adopts it as the
            -- JVE clip.id. Rule 2.13: no silent minting. If Resolve didn't
            -- provide a DbId, subsequent marker attachment via BlobOwner
            -- would orphan anyway.
            local clip_db_id = clip_elem.attrs and clip_elem.attrs.DbId
            assert(clip_db_id and clip_db_id ~= "", string.format(
                "drp_importer: timeline clip %q missing Sm2Ti DbId attribute",
                tostring(clip_name)))

            local clip = {
                clip_id = clip_db_id,
                name = clip_name,
                start_value = start_frames,        -- timeline position (integer frames)
                start_subframe = start_subframe,   -- fractional frame offset (0.0–1.0, for sub-frame audio)
                duration = duration_timeline_frames,  -- duration on timeline (integer frames)
                -- Absolute timecode addressing for source selection:
                source_in_tc = source_in_native,   -- native units (samples for audio, frames for video)
                source_length = source_duration,   -- duration in source units
                source_in = source_in_native,
                source_out = source_out_native,
                clip_speed = clip_speed,            -- signed speed for downstream validation
                enabled = get_text(find_element(clip_elem, "WasDisbanded")) ~= "true"
                    and (tonumber(get_text(find_element(clip_elem, "Flags"))) or 0) % 4 < 2,  -- bit 1 = muted
                volume = volume_linear,            -- linear gain from EffectFiltersBA (1.0 = 0dB)
                file_path = file_path,
                file_uuid = get_text(find_element(clip_elem, "MediaRef")),
                file_id = get_text(find_element(clip_elem, "MediaRef")),
                frame_rate = frame_rate,              -- sequence rate (for timeline position)
                native_rate = native_rate,            -- media's native rate (source coords are in this rate)
                media_start_time = media_start_time,  -- seconds since midnight (file TC origin)
                original_clip = extract_original_clip(clip_elem),  -- nil unless substituted
                linked_item_sync = linked_item_sync,  -- V↔A link-group key (nil = unlinked)
            }
            -- Skip degenerate zero-duration clips (Resolve artifacts: speed changes, disabled items)
            if clip.duration <= 0 then
                log.detail("Skipping zero-duration clip '%s' (duration=%d)", clip_name, clip.duration)
            else
                table.insert(track_info.clips, clip)
                clip_count = clip_count + 1

                if file_path and file_path ~= "" then
                    -- Key by UUID (file_id) for dedup across volumes.
                    -- Fall back to path key for clips without MediaRef.
                    local lookup_key = (clip.file_id and clip.file_id ~= "") and clip.file_id or file_path
                    local entry = media_lookup[lookup_key]
                    if not entry then
                        -- Use master clip name (original filename) for media name,
                        -- not timeline clip name (user's custom label)
                        local mc_name = media_ref_name_map and media_ref_name_map[clip.file_id]
                        entry = {
                            file_uuid = (clip.file_id and clip.file_id ~= "") and clip.file_id or nil,
                            name = mc_name or clip.name or file_path,
                            file_path = file_path,
                            duration = source_extent_frames,
                            frame_rate = media_frame_rate,  -- from <MediaFrameRate>; blob propagation may override
                            audio_channels = track_type == "AUDIO" and 2 or 0,
                            has_video = track_type == "VIDEO",
                            media_start_time = media_start_time,
                            alt_paths = {},
                        }
                        media_lookup[lookup_key] = entry
                    else
                        -- Same UUID, maybe different path — track alt_paths
                        if file_path ~= entry.file_path then
                            entry.alt_paths[file_path] = true
                        end
                        if source_extent_frames > entry.duration then
                            entry.duration = source_extent_frames
                        end
                        if track_type == "AUDIO" and entry.audio_channels < 2 then
                            entry.audio_channels = 2
                        end
                        if track_type == "VIDEO" then
                            entry.has_video = true
                        end
                        if media_frame_rate and not entry.frame_rate then
                            entry.frame_rate = media_frame_rate
                        end
                    end
                end
            end
            ::continue_clip::
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
-- @param media_ref_path_map table|nil: MediaRef DbId → original file path (for stale-path resolution)
-- @return table: Timeline data
local function parse_sequence(seq_elem, opts)
    local frame_rate = opts.frame_rate
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
        duration = get_number_or_assert(duration_elem, "Duration"),
        tracks = {}
    }

    -- Primary: Resolve-native format (Sm2TiTrack with Sm2TiVideoClip/AudioClip).
    -- Has authoritative retime curves (MTBA), MediaFrameRate, native-rate source
    -- coordinates, and TracksBA TC data. DRP files always contain this format.
    local resolve_video_tracks, resolve_audio_tracks, media_map = parse_resolve_tracks(seq_elem, opts)
    timeline.media_files = media_map

    for _, track in ipairs(resolve_video_tracks) do
        table.insert(timeline.tracks, track)
    end
    for _, track in ipairs(resolve_audio_tracks) do
        table.insert(timeline.tracks, track)
    end

    -- Fallback: FCP XML format (VideoTrack/AudioTrack with ClipItem).
    -- Used by non-DRP imports (FCP XML, Premiere XML). DRP files also contain
    -- this as a compatibility layer, but Resolve-native is preferred above.
    if #timeline.tracks == 0 then
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

    -- DRP freeze frame: Resolve encodes <In> == <Out> for the frozen source position.
    -- (Not FCP7 convention — FCP7 uses <stillframe> + <stillframeoffset> instead.)
    -- Single-frame source range → speed_ratio = 1/duration at playback.
    if source_in >= source_out then
        local clip_name = name_elem and get_text(name_elem) or "Untitled Clip"
        local duration = end_time - start_value
        log.event("DRP freeze frame: '%s' at source frame %d (duration=%d)",
                  clip_name, source_in, duration)
        source_out = source_in + 1
    end

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
--- Merge MediaPool master-clip (pmc) metadata into a media entry.
--
-- `pmc.num_frames` (from BtVideoInfo.Time) and `pmc.audio_duration` (from
-- BtAudioInfo.TracksBA) are independent facts: A/V files carry both, pure
-- video files carry only num_frames, pure audio files carry only
-- audio_duration. They must be applied independently — an A/V file must
-- get both a video-frame duration and an audio sample rate.
--
-- `duration`/`frame_rate` are single-valued on the media entry and come
-- from the video stream when present (timeline-frame domain), otherwise
-- from the audio stream (sample domain). `audio_sample_rate` is always
-- recorded when audio_duration is present, regardless of which stream
-- drove duration.
local function apply_pmc_metadata(entry, pmc)
    -- Video stream drives duration/frame_rate when present; otherwise
    -- the audio stream does (audio-only file, sample domain).
    if pmc.num_frames and pmc.num_frames > 0 then
        entry.duration = pmc.num_frames
        if pmc.frame_rate then
            entry.frame_rate = pmc.frame_rate
        end
    elseif pmc.audio_duration then
        entry.duration = pmc.audio_duration.samples
        entry.frame_rate = pmc.audio_duration.sample_rate
    end

    -- audio_sample_rate is independent of which stream drove duration —
    -- A/V files have both, and downstream consumers (waveform peaks,
    -- playback audio math) need the sample rate regardless.
    if pmc.audio_duration then
        entry.audio_sample_rate = pmc.audio_duration.sample_rate
    end

    -- File container TC origin from TracksBA.StartTime (FR-001)
    if pmc.file_tc_seconds then
        entry.file_tc_seconds = pmc.file_tc_seconds
    end

    -- For audio-only pool items (external WAVs), the DRP's TracksBA.StartTime
    -- IS the audio TC origin (no Set Timecode override possible on audio). Map
    -- it to media_start_time so build_media_metadata can write
    -- start_tc_audio_samples — the field ensure_master reads to place the
    -- synced audio clip on the timeline.
    if pmc.clip_type == "audio" and pmc.file_tc_seconds then
        entry.media_start_time = pmc.file_tc_seconds
    end

    -- Audio channel count:
    -- Sm2MpAudioClip (audio-only): one BtAudioInfo in XML regardless of channel
    -- count; TracksBA.NumChannels is the authoritative per-file value.
    -- Sm2MpVideoClip (A/V): one BtAudioInfo per embedded channel; XML count is
    -- authoritative (TracksBA of the first BtAudioInfo only covers that channel).
    if pmc.clip_type == "audio" then
        local n = pmc.audio_duration and pmc.audio_duration.num_channels
        if n and n > 0 then
            entry.audio_channels = n
        end
    elseif pmc.own_bt_audio_info_ids and #pmc.own_bt_audio_info_ids > 0 then
        entry.audio_channels = #pmc.own_bt_audio_info_ids
    end
end
M._apply_pmc_metadata = apply_pmc_metadata  -- exported for tests
M._parse_master_clip_element = parse_master_clip_element

-- For each video pool item with AudioSource=AUDIO_SOURCE_CUSTOM, resolve
-- the external audio pool items via the btai_dbid reverse index, ensure they
-- are present in media_items, and stamp synced_audio_pool_ids on the video
-- media entry so importer_core can forward the info to ensure_master.
--
-- The FieldsBlob on an AUDIO_SOURCE_CUSTOM Sm2MpVideoClip carries an ordered
-- list of BtAudioInfo DbId UUIDs (audio_refs). UUIDs that appear in the pool
-- item's own_bt_audio_info_ids are the camera's embedded scratch audio;
-- UUIDs owned by OTHER pool items identify the external synced WAV files.
--
-- @param master_clips table: array from media_pool_hierarchy.master_clips
-- @param media_get    function: (file_uuid, file_path) → entry or nil
-- @param media_put    function: (entry) — inserts/updates media_items
local function resolve_synced_audio_linkage(master_clips, media_get, media_put)
    -- Pass 1: build btai_dbid → owning pmc reverse index
    local btai_to_pmc = {}
    for _, pmc in ipairs(master_clips) do
        for _, btai_id in ipairs(pmc.own_bt_audio_info_ids or {}) do
            btai_to_pmc[btai_id] = pmc
        end
    end

    -- Pass 2: for each CUSTOM-audio video pmc, find external audio pmcs
    for _, pmc in ipairs(master_clips) do
        if pmc.audio_source ~= "AUDIO_SOURCE_CUSTOM" or not pmc.audio_refs then
            goto continue_pmc
        end

        local own_btai = {}
        for _, id in ipairs(pmc.own_bt_audio_info_ids or {}) do
            own_btai[id] = true
        end

        -- Walk audio_refs in wire order; collect distinct external pmc ids
        local synced_pool_ids = {}
        local seen_pool_ids   = {}
        for _, ref_id in ipairs(pmc.audio_refs) do
            if own_btai[ref_id] then goto next_ref end
            local audio_pmc = btai_to_pmc[ref_id]
            if not audio_pmc then
                log.warn("drp_importer: audio_ref '%s' on pmc '%s' not in btai index "
                    .. "— sync linkage incomplete", ref_id, pmc.name or "?")
                goto next_ref
            end
            if not audio_pmc.id then goto next_ref end
            if seen_pool_ids[audio_pmc.id] then goto next_ref end
            seen_pool_ids[audio_pmc.id] = true
            synced_pool_ids[#synced_pool_ids + 1] = audio_pmc.id
            -- Ensure external audio is in media_items (may be absent when not
            -- directly placed on any edit timeline track)
            if not media_get(audio_pmc.id, audio_pmc.file_path) then
                if not audio_pmc.file_path or audio_pmc.file_path == "" then
                    log.warn("drp_importer: synced audio pmc id=%s has no file_path; "
                        .. "cannot add to media_items", tostring(audio_pmc.id))
                    goto next_ref
                end
                local entry = {
                    file_uuid = audio_pmc.id,
                    name      = audio_pmc.name or audio_pmc.file_path,
                    file_path = audio_pmc.file_path,
                    duration  = 0,
                    alt_paths = {},
                }
                apply_pmc_metadata(entry, audio_pmc)
                media_put(entry)
                log.event("drp_importer: added synced audio to media_items: '%s' (id=%s)",
                    audio_pmc.name or "?", audio_pmc.id)
            end
            ::next_ref::
        end

        if #synced_pool_ids > 0 then
            local video_entry = media_get(pmc.id, pmc.file_path)
            if video_entry then
                video_entry.synced_audio_pool_ids = synced_pool_ids
                log.event("drp_importer: '%s' has %d synced audio file(s)",
                    pmc.name or "?", #synced_pool_ids)
            else
                log.warn("drp_importer: CUSTOM-audio pmc '%s' (id=%s) not in media_items "
                    .. "— synced_audio_pool_ids not stamped",
                    pmc.name or "?", tostring(pmc.id))
            end
        end

        ::continue_pmc::
    end
end
M._resolve_synced_audio_linkage = resolve_synced_audio_linkage  -- exported for tests

-- Build the MediaRef→{path, name, audio sample rate} maps from the
-- decoded media pool hierarchy. Timeline clips reference pool master
-- clips via <MediaRef>. The pool master clip's binary blob encodes the
-- original source path; the timeline clip's <MediaFilePath> may be
-- stale (proxy path or old volume name from a prior relink), so we
-- prefer the path/name pulled from the blob.
--
-- Video-only media (no audio blob) is intentionally NOT in the sample
-- rate map. Audio clips that link to such media are skipped in
-- parse_resolve_tracks (silent companion clips).
local function build_media_ref_maps(media_pool_hierarchy)
    local path_map, name_map, sample_rate_map = {}, {}, {}
    for _, pmc in ipairs(media_pool_hierarchy.master_clips) do
        if pmc.id then
            if pmc.file_path then path_map[pmc.id] = pmc.file_path end
            if pmc.name      then name_map[pmc.id] = pmc.name end
            if pmc.audio_duration and pmc.audio_duration.sample_rate then
                sample_rate_map[pmc.id] = pmc.audio_duration.sample_rate
            end
        end
    end
    return path_map, name_map, sample_rate_map
end

-- Locate the root <Project>/<SM_Project> element in a parsed project.xml.
-- Returns nil + err string when no recognized container is present.
local function locate_project_element(project_root)
    -- Rule 2.32: Avoid redundant recursive walks (review item #2).
    -- The project container is usually a top-level child of the root.
    if project_root.tag == "SM_Project" or project_root.tag == "Project" then
        return project_root
    end
    
    local project_elem = find_direct_child(project_root, "Project")
        or find_direct_child(project_root, "SM_Project")
    if project_elem then return project_elem end

    -- Fallback to recursive find if not top-level
    return find_element(project_root, "Project")
        or find_element(project_root, "SM_Project")
end

-- Some sequence XMLs wrap the timeline tracks in <Sequence>; others land
-- them in <Sm2SequenceContainer>. Pick whichever element actually carries
-- the track elements.
local function resolve_sequence_root_element(seq_root)
    local seq_elem = find_element(seq_root, "Sequence")
    if seq_elem then
        local has_classic_tracks = find_element(seq_elem, "VideoTrack")
            or find_element(seq_elem, "AudioTrack")
        local has_resolve_tracks = find_element(seq_elem, "Sm2TiTrack")
        if has_classic_tracks or has_resolve_tracks then
            return seq_elem
        end
    end
    return find_element(seq_root, "Sm2SequenceContainer") or seq_root
end

-- Decorate a freshly-parsed timeline with the metadata pulled from the
-- MediaPool sidecar (name, fps, resolution, start TC, viewport).
-- project.settings.{width,height} fill in resolution for legacy DRPs that
-- don't carry per-sequence FrameRect.
local function apply_timeline_metadata(timeline, metadata, fps_for_parsing,
                                       project_settings, seq_ref_id)
    timeline.tab_uuid = seq_ref_id
    if metadata and metadata.name then
        timeline.name = metadata.name
    end
    timeline.fps = fps_for_parsing
    -- Lua truthy-zero — `0 or fallback` == 0, so check > 0 explicitly.
    local meta_w = metadata and metadata.width
    local meta_h = metadata and metadata.height
    timeline.width  = (meta_w and meta_w > 0) and meta_w or project_settings.width
    timeline.height = (meta_h and meta_h > 0) and meta_h or project_settings.height
    timeline.folder_id = metadata and metadata.folder_id or nil
    timeline.start_tc_seconds = metadata and metadata.start_tc_seconds or nil
    timeline.ui_scale = metadata and metadata.ui_scale or nil
    timeline.cur_playhead_relative = metadata and metadata.cur_playhead_relative or nil
end

--- Decode clip markers from the raw project.xml text.
-- Each <Sm2TiItemLockableBlob> carries a <BlobOwner> (the owning clip's Sm2Ti
-- DbId) and a <FieldsBlob>; the blob is decoded and its markers keyed by owner.
-- Non-marker blobs (other per-item state) decode to nil and are skipped. A clip
-- can in principle own more than one marker blob, so markers are merged.
--
-- Works on the raw XML string rather than the qt_xml_parse element tree: the
-- LockableBlobMap subtree does not surface through find_all_elements (the tree
-- root is <BinWrapper> and the blob map isn't traversed), whereas the large
-- hex FieldsBlob text is intact in the file. The string scan is also what the
-- decoder is validated against.
-- @param project_xml string: full project.xml contents
-- @return table: owner_dbid → array of {frame,color,name,note,duration,custom_data}
local function parse_resolve_markers(project_xml)
    local by_owner = {}
    local owner_count, marker_count = 0, 0
    for block in project_xml:gmatch("<Sm2TiItemLockableBlob.-</Sm2TiItemLockableBlob>") do
        local owner = block:match("<BlobOwner>(.-)</BlobOwner>")
        local hex = block:match("<FieldsBlob>(.-)</FieldsBlob>")
        if owner and owner ~= "" and hex and hex ~= "" then
            local markers, err = drp_binary.decode_clip_markers((hex:gsub("%s+", "")))
            if err then
                -- The blob unwrapped as a marker collection but a specific
                -- entry was malformed — surface so a Resolve format drift
                -- doesn't silently drop markers (rule 2.32).
                log.warn("drp_importer: marker decode failed for owner %s: %s",
                    owner, err)
            elseif markers and #markers > 0 then
                local list = by_owner[owner]
                if not list then
                    list = {}
                    by_owner[owner] = list
                    owner_count = owner_count + 1
                end
                for _, m in ipairs(markers) do
                    list[#list + 1] = m
                    marker_count = marker_count + 1
                end
            end
        end
    end
    log.event("drp_importer: decoded %d markers across %d BlobOwners",
        marker_count, owner_count)
    return by_owner
end

function M.parse_drp_file(drp_path, progress_cb)
    local pump = progress_cb or function() end

    -- Extract .drp archive
    local tmp_dir, err = extract_drp(drp_path)
    if not tmp_dir then
        return {success = false, error = err}
    end

    -- Parse project.xml
    local project_xml_path = tmp_dir .. "/project.xml"
    local project_handle, open_err = io.open(project_xml_path, "r")
    if not project_handle then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "Failed to open project.xml: " .. tostring(open_err)}
    end
    local project_xml_text = file_read_all(project_handle, "parse_drp_file")
    project_handle:close()

    local project_root, parse_err = parse_xml_string(project_xml_text)
    if not project_root then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "Failed to parse project.xml: " .. tostring(parse_err)}
    end

    local project_elem = locate_project_element(project_root)
    if not project_elem then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "No <Project> element found in project.xml"}
    end

    local project = parse_project_metadata(project_elem)
    pump(10, "Scanning media pool…")

    -- Parse MediaPool XML for master clips (Pass 1: basic path-only entries)
    local media_pool_path = tmp_dir .. "/MediaPool/Master/MpFolder.xml"
    local media_pool_items = {}
    local media_pool_root = parse_xml_file(media_pool_path)
    if media_pool_root then
        media_pool_items = parse_media_pool(media_pool_root)
    end

    -- Build timeline metadata map by scanning all MediaPool folders.
    -- metadata_map: Sm2Sequence.DbId → {name, fps, width, height, folder_id, …}
    -- timeline_id_map: Sm2Timeline.DbId → {name, seq_id} — needed for
    --                  TimelineHandleVec resolution.
    local timeline_metadata_map, timeline_id_map = build_timeline_metadata_map(tmp_dir,
        function(sub_pct)
            pump(10 + math.floor(sub_pct * 0.15), "Scanning timeline metadata…")
        end)

    -- Now that we have Sm2Timeline→Sm2Sequence translation, resolve the
    -- project's tab/active ids (fills project.open_timeline_ids + active_id).
    resolve_project_tab_ids(project, timeline_id_map)

    pump(25, "Parsing media pool hierarchy…")

    -- Parse MediaPool folder hierarchy (with blob-decoded original source paths)
    -- Must happen before sequence parsing so we can resolve stale MediaFilePath values
    local media_pool_hierarchy = parse_media_pool_hierarchy(tmp_dir, function(sub_pct)
        pump(25 + math.floor(sub_pct * 0.45), "Decoding media pool clips…")
    end)

    local media_ref_path_map, media_ref_name_map, media_ref_sample_rate_map =
        build_media_ref_maps(media_pool_hierarchy)

    pump(70, "Parsing sequences…")

    -- Parse sequence XMLs
    local timelines = {}
    local seq_dir = tmp_dir .. "/SeqContainer"
    local seq_files = shell_capture("ls " .. seq_dir .. "/*.xml 2>/dev/null", "parse_drp_file:ls_seq")
    local sequence_file_list = {}

    -- Collect file list for progress counting
    local seq_file_paths = {}
    for f in seq_files:gmatch("[^\n]+") do
        seq_file_paths[#seq_file_paths + 1] = f
    end
    local seq_count = #seq_file_paths

    for seq_idx, seq_file in ipairs(seq_file_paths) do
        table.insert(sequence_file_list, seq_file)
        if seq_count > 0 then
            pump(70 + math.floor(seq_idx / seq_count * 25))
        end
        local seq_root = parse_xml_file(seq_file)
        if seq_root then
            local seq_elem = resolve_sequence_root_element(seq_root)
            if seq_elem then
                local seq_ref_id = extract_sequence_ref_id(seq_elem)
                local metadata = seq_ref_id and timeline_metadata_map[seq_ref_id]
                -- Skip orphan sequences with no MediaPool metadata
                -- (compound clips, deleted timelines).
                local fps_for_parsing = metadata and metadata.fps
                if fps_for_parsing and fps_for_parsing > 0 then
                    local timeline = parse_sequence(seq_elem, {
                        frame_rate = fps_for_parsing,
                        media_ref_path_map = media_ref_path_map,
                        media_ref_name_map = media_ref_name_map,
                        media_ref_sample_rate_map = media_ref_sample_rate_map,
                    })
                    apply_timeline_metadata(timeline, metadata, fps_for_parsing,
                        project.settings, seq_ref_id)
                    table.insert(timelines, timeline)
                else
                    log.warn("Skipping sequence '%s' (seq_ref_id=%s) - no fps in MediaPool metadata",
                        seq_file:match("([^/]+)%.xml$") or seq_file,
                        tostring(seq_ref_id))
                end
            end
        end
    end

    -- 023: attach decoded clip markers to their clips by Sm2Ti DbId.
    do
        local markers_by_owner = parse_resolve_markers(project_xml_text)
        for _, timeline in ipairs(timelines) do
            for _, track in ipairs(timeline.tracks) do
                for _, c in ipairs(track.clips) do
                    -- c.clip_id is the Sm2Ti DbId (nil for synthetic fixtures
                    -- without one; those carry no markers either). A nil index
                    -- on the map is a valid no-match read.
                    if c.clip_id then
                        c.markers = markers_by_owner[c.clip_id]
                    end
                end
            end
        end
    end

    -- media_items: UUID → entry (one entry per master clip).
    -- For entries without UUID, key is file_path.
    -- Secondary path→entry index for path-based lookups.
    local media_items = {}     -- uuid_or_path → entry
    local path_to_key = {}     -- file_path → key in media_items (for path lookups)

    local function media_put(entry)
        local key = (entry.file_uuid and entry.file_uuid ~= "") and entry.file_uuid or entry.file_path
        if not key or key == "" then return end
        media_items[key] = entry
        if entry.file_path and entry.file_path ~= "" then
            path_to_key[entry.file_path] = key
        end
        for alt in pairs(entry.alt_paths or {}) do
            path_to_key[alt] = key
        end
    end

    local function media_get(file_uuid, file_path)
        if file_uuid and file_uuid ~= "" and media_items[file_uuid] then
            return media_items[file_uuid]
        end
        if file_path and file_path ~= "" then
            local key = path_to_key[file_path]
            if key then return media_items[key] end
        end
        return nil
    end

    -- Seed from parse_media_pool (Pass 1: path-only, no UUIDs)
    for _, item in ipairs(media_pool_items) do
        if item.file_path and item.file_path ~= "" then
            if not item.alt_paths then item.alt_paths = {} end
            media_put(item)
        end
    end

    -- Merge per-timeline media_files (from parse_resolve_tracks, UUID-keyed)
    for _, timeline in ipairs(timelines) do
        if timeline.media_files then
            for _, info in pairs(timeline.media_files) do
                local existing = media_get(info.file_uuid, info.file_path)
                if existing then
                    -- Same master clip — merge all paths
                    local ekey = (existing.file_uuid and existing.file_uuid ~= "") and existing.file_uuid or existing.file_path
                    if info.file_path and info.file_path ~= existing.file_path then
                        existing.alt_paths[info.file_path] = true
                        path_to_key[info.file_path] = ekey
                    end
                    for alt in pairs(info.alt_paths or {}) do
                        if alt ~= existing.file_path then
                            existing.alt_paths[alt] = true
                            path_to_key[alt] = ekey
                        end
                    end
                    if (info.duration or 0) > (existing.duration or 0) then
                        existing.duration = info.duration
                    end
                    if (info.audio_channels or 0) > (existing.audio_channels or 0) then
                        existing.audio_channels = info.audio_channels
                    end
                    if info.has_video then
                        existing.has_video = true
                    end
                    if info.media_start_time and not existing.media_start_time then
                        existing.media_start_time = info.media_start_time
                    end
                    if info.frame_rate and not existing.frame_rate then
                        existing.frame_rate = info.frame_rate
                    end
                    -- If existing was path-keyed but info has UUID, upgrade the key
                    if info.file_uuid and info.file_uuid ~= "" and not existing.file_uuid then
                        -- Remove old path-based key, re-insert under UUID
                        media_items[existing.file_path] = nil
                        existing.file_uuid = info.file_uuid
                        media_put(existing)
                    end
                else
                    local entry = {
                        file_uuid = info.file_uuid,
                        name = info.name or info.file_path,
                        file_path = info.file_path,
                        duration = info.duration or 0,
                        frame_rate = info.frame_rate,
                        audio_channels = info.audio_channels,
                        has_video = info.has_video,
                        media_start_time = info.media_start_time,
                        alt_paths = info.alt_paths or {},
                    }
                    media_put(entry)
                end
            end
        end
    end

    -- Pass 4: raw XML grep for orphaned paths not found in structured parse.
    -- Strip <OriginalClip> blocks first — those record a clip's pre-replace
    -- state (e.g., a Windows path before the user relinked to Mac) and aren't
    -- referenced by any active timeline clip. Harvesting them creates phantom
    -- zero-duration media items.
    for _, seq_file in ipairs(sequence_file_list) do
        local handle = assert(io.open(seq_file, "r"),
            string.format("parse_drp_file: failed to open %s", seq_file))
        local content = file_read_all(handle, "drp_importer:seq_xml:" .. seq_file)
        handle:close()
        content = content:gsub("<OriginalClip>.-</OriginalClip>", "")
        for raw_path in content:gmatch("<MediaFilePath>(.-)</MediaFilePath>") do
            local cleaned = raw_path:match("^%s*(.-)%s*$")
            if cleaned ~= "" and not media_get(nil, cleaned) then
                media_put({
                    name = cleaned:match("([^/\\]+)$") or cleaned,
                    file_path = cleaned,
                    duration = 0,
                    alt_paths = {},
                })
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

    -- UUID enrichment: fast regex scan of sequence XMLs for <MediaRef>+<MediaFilePath>
    -- pairs. Entries from Pass 1/4 may lack UUIDs (e.g., from skipped sequences).
    -- Text scan is much faster than full XML parse (~100x for large DRPs).
    pump(96, "Enriching media UUIDs…")
    local enriched_count = 0
    for seq_idx, seq_file in ipairs(sequence_file_list) do
        local handle = assert(io.open(seq_file, "r"),
            string.format("parse_drp_file: failed to open %s for UUID enrichment", seq_file))
        local content = file_read_all(handle, "drp_importer:seq_xml:" .. seq_file)
        handle:close()
        do
            -- Collapse whitespace so patterns can span XML elements on separate lines.
            -- Lua's . doesn't match \n, so multi-line XML breaks .- patterns.
            content = content:gsub("%s+", " ")
            -- Extract <MediaRef>+<MediaFilePath> pairs (UUID enrichment)
            for ref_id, mfp in content:gmatch("<MediaRef>([^<]+)</MediaRef>.-<MediaFilePath>([^<]+)</MediaFilePath>") do
                ref_id = ref_id:match("^%s*(.-)%s*$")
                mfp = mfp:match("^%s*(.-)%s*$")
                if ref_id ~= "" and mfp ~= "" then
                    local path_entry = media_get(nil, mfp)
                    local uuid_entry = media_get(ref_id, nil)

                    if path_entry and uuid_entry and path_entry ~= uuid_entry then
                        -- Merge path_entry into uuid_entry
                        if mfp ~= uuid_entry.file_path then
                            uuid_entry.alt_paths[mfp] = true
                        end
                        if (path_entry.duration or 0) > (uuid_entry.duration or 0) then
                            uuid_entry.duration = path_entry.duration
                        end
                        if path_entry.media_start_time and not uuid_entry.media_start_time then
                            uuid_entry.media_start_time = path_entry.media_start_time
                        end
                        media_items[path_entry.file_path] = nil
                        path_to_key[mfp] = ref_id
                        enriched_count = enriched_count + 1
                    elseif path_entry and not path_entry.file_uuid then
                        media_items[path_entry.file_path] = nil
                        path_entry.file_uuid = ref_id
                        media_put(path_entry)
                        enriched_count = enriched_count + 1
                    elseif not path_entry and uuid_entry then
                        uuid_entry.alt_paths[mfp] = true
                        path_to_key[mfp] = ref_id
                    elseif not path_entry and not uuid_entry then
                        media_put({
                            file_uuid = ref_id,
                            name = mfp:match("([^/\\]+)$") or mfp,
                            file_path = mfp,
                            duration = 0,
                            alt_paths = {},
                        })
                        enriched_count = enriched_count + 1
                    end
                end
            end

            -- Extract <MediaFilePath>+<MediaFrameRate> for entries missing frame_rate.
            -- Catches clips in skipped sequences (no MediaRef, no blob propagation).
            for mfp, mfr_hex in content:gmatch("<MediaFilePath>([^<]+)</MediaFilePath>.-<MediaFrameRate>([^<]+)</MediaFrameRate>") do
                mfp = mfp:match("^%s*(.-)%s*$")
                if mfp ~= "" and #mfr_hex >= 16 then
                    local entry = media_get(nil, mfp)
                    if entry and not entry.frame_rate then
                        local fps = decode_hex_double_at(mfr_hex, 0)
                        if fps and fps > 0 and fps < 1000 then
                            entry.frame_rate = fps
                            enriched_count = enriched_count + 1
                        end
                    end
                end
            end
        end
        if seq_idx % 10 == 0 then
            pump(96 + math.floor(seq_idx / #sequence_file_list * 2))
        end
    end
    if enriched_count > 0 then
        log.event("UUID enrichment: %d entries from %d files",
            enriched_count, #sequence_file_list)
    end

    -- Apply authoritative media durations from MediaPool blob data.
    pump(98, "Applying media durations…")
    local pmc_count = #media_pool_hierarchy.master_clips
    for pmc_idx, pmc in ipairs(media_pool_hierarchy.master_clips) do
        if pmc_idx % 50 == 0 then
            pump(98 + math.floor(pmc_idx / pmc_count))
        end
        local entry = media_get(pmc.id, pmc.file_path)

        if not entry and pmc.id then
            log.detail("pmc %s (id=%s): no media entry (encrypted blob, unreferenced)",
                pmc.name or "?", pmc.id)
        end

        if entry then
            -- Update canonical path from blob if blob has a decodable path
            if pmc.file_path and pmc.file_path ~= entry.file_path then
                entry.alt_paths[entry.file_path] = true
                entry.file_path = pmc.file_path
                path_to_key[pmc.file_path] = (entry.file_uuid and entry.file_uuid ~= "") and entry.file_uuid or entry.file_path
            end

            apply_pmc_metadata(entry, pmc)
        end
    end

    -- Nil out timeline folder_ids that referenced the excluded Master root
    if media_pool_hierarchy.excluded_root_id then
        for _, timeline in ipairs(timelines) do
            if timeline.folder_id == media_pool_hierarchy.excluded_root_id then
                timeline.folder_id = nil
            end
        end
    end

    -- Stamp synced_audio_pool_ids on video media entries for CUSTOM-audio pool
    -- items. Must run after apply_pmc_metadata (needs decoded blob paths) and
    -- after UUID enrichment (needs media_get to resolve by id).
    resolve_synced_audio_linkage(media_pool_hierarchy.master_clips, media_get, media_put)

    os.execute("rm -rf " .. tmp_dir)

    -- parse_result.project.open_timeline_ids + active_timeline_id are the
    -- authoritative Sm2Sequence.DbIds (resolved by resolve_project_tab_ids).
    -- parse_result.timelines[i].tab_uuid carries the same id per timeline
    -- so importer_core can emit a tab-uuid → sequence-id map.
    return {
        success = true,
        project = project,
        media_items = media_items,
        timelines = timelines,
        -- Folder/bin hierarchy and master clips from MediaPool
        folders = media_pool_hierarchy.folders,
        pool_master_clips = media_pool_hierarchy.master_clips,
        folder_map = media_pool_hierarchy.folder_map,
    }
end

-- Parsing kernel exports (stable public API for testing + extension)
M.parse_resolve_tracks = parse_resolve_tracks
M.extract_original_path = extract_original_path
M.parse_fields_blob_tabs = parse_fields_blob_tabs
M.decode_bt_video_time = decode_bt_video_time
M.decode_bt_audio_duration = decode_bt_audio_duration
M.decode_effect_filters_volume_db = decode_effect_filters_volume_db
M.decode_media_timemap = decode_media_timemap

--- Lightweight metadata extraction — project name only, no full parse.
-- Extracts project.xml from ZIP via unzip -p to temp file (EINTR-safe).
-- @param drp_path string: Path to .drp file
-- @return table|nil: { name = "Project Name" }, or nil on error
-- @return string|nil: error message if failed
function M.quick_metadata(drp_path)
    assert(drp_path and drp_path ~= "", "drp_importer.quick_metadata: drp_path required")

    local tmp = os.tmpname()
    local cmd = string.format('unzip -p "%s" project.xml > "%s" 2>/dev/null', drp_path, tmp)
    local exit_code = os.execute(cmd)
    if exit_code ~= 0 then
        os.remove(tmp)
        return nil, "Failed to read .drp archive"
    end

    local handle = io.open(tmp, "r")
    if not handle then
        os.remove(tmp)
        return nil, "Failed to open temp file for project.xml"
    end
    local xml_content = handle:read("*a")
    handle:close()
    os.remove(tmp)

    if not xml_content or xml_content == "" then
        return nil, "No project.xml in .drp archive"
    end

    local project_root, parse_err = parse_xml_string(xml_content)
    if not project_root then return nil, "Failed to parse project.xml: " .. tostring(parse_err) end

    local project_elem = find_element(project_root, "Project")
    if not project_elem then
        if project_root.tag == "SM_Project" or project_root.tag == "Project" then
            project_elem = project_root
        else
            project_elem = find_element(project_root, "SM_Project")
        end
    end
    if not project_elem then return nil, "No <Project> element" end

    local name_elem = find_direct_child(project_elem, "ProjectName")
        or find_direct_child(project_elem, "Name")
    local name = name_elem and get_text(name_elem) or "Untitled Project"

    return { name = name }
end

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

-- Models (SQL isolation: only what DRP-specific code needs post-extraction).
local Sequence = require("models.sequence")

-- ---------------------------------------------------------------------------
-- Helper: Infer frame rate from 1-hour timecode start position
-- ---------------------------------------------------------------------------
--
-- HEURISTIC: video projects typically place start TC at 01:00:00:00
-- (1-hour offset). Different frame rates produce different frame counts:
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
-- frame_rate_to_rational and infer_fps_from_one_hour_start moved to importer_core.lua

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

        -- Find the master sequence for this media (V13).
        local mc_seq_id = Sequence.find_master_for_media(media.id)
        if not mc_seq_id then
            log.warn("apply_marks: no master sequence for media '%s' (id=%s)",
                media.name, media.id)
            goto next_media
        end

        local mc_seq = Sequence.load(mc_seq_id)
        assert(mc_seq, string.format(
            "apply_marks: Sequence.load failed for master %s (media=%s)",
            mc_seq_id, media.name))

        -- video_stream/audio_streams return plain tables backed by media_refs
        -- rows under V13. Persist marks via MediaRef.update.
        local MediaRef = require("models.media_ref")

        if name_marks.video then
            local video_ref = mc_seq:video_stream()
            if video_ref then
                MediaRef.update(video_ref.id, {
                    mark_in_frame  = name_marks.video.mark_in,
                    mark_out_frame = name_marks.video.mark_out,
                    playhead_frame = name_marks.video.playhead,
                })
                applied_count = applied_count + 1
            end
        end

        if name_marks.audio then
            for _, audio_ref in ipairs(mc_seq:audio_streams()) do
                MediaRef.update(audio_ref.id, {
                    mark_in_frame  = name_marks.audio.mark_in,
                    mark_out_frame = name_marks.audio.mark_out,
                    playhead_frame = name_marks.audio.playhead,
                })
                applied_count = applied_count + 1
            end
        end

        ::next_media::
    end

    if applied_count > 0 then
        log.event("Applied marks to %d master clip stream(s)", applied_count)
    end
end

-- mark_offline_clips removed: offline status is now transient,
-- recomputed reactively by core.media.media_status registry.

--- Import parsed DRP data into an existing project.
-- Delegates to importer_core for entity creation, then applies DRP-specific
-- post-import steps (pool master clip marks).
-- @param project_id string: Target project ID (must already exist)
-- @param parse_result table: Output of parse_drp_file()
-- @param opts table: Optional settings
-- @return table: {media_ids, sequence_ids, track_ids, clip_ids} for undo
function M.import_into_project(project_id, parse_result, opts)
    local result = importer_core.import_into_project(project_id, parse_result, opts)

    -- DRP-specific: apply pool master clip marks
    apply_pool_master_clip_marks(parse_result.pool_master_clips, result.media_by_path)

    return result
end
-- Original import_into_project body moved to importer_core.lua.

-- ---------------------------------------------------------------------------
-- convert: Parse .drp and create new .jvp at target path (Open verb)
-- ---------------------------------------------------------------------------

--- Convert .drp file to .jvp at target path
-- @param drp_path string: Path to source .drp file
-- @param jvp_path string: Path for new .jvp file
-- @param progress_cb function|nil: optional progress(pct, text [, log_line])
-- @return boolean: success
-- @return string|nil: error message if failed
-- Pick the project audio sample rate by majority vote across the imported
-- timelines' media files' BtAudioInfo blobs. Falls back to 48000 when no
-- media carries a decodeable audio rate (video-only projects, or projects
-- whose BtAudioInfo blobs all failed to decode).
--
-- TODO: decode the Fairlight project FieldsBlob to read the authoritative
-- project-level mix-bus sample rate (Project Settings → Fairlight → Timeline
-- Sample Rate). That value is binary-encoded in SM_Project/FieldsBlob and is
-- NOT exposed as a plain XML element. Until that decoding is implemented,
-- 48 kHz is the safe fallback: it is Resolve's documented default and the
-- only option in free Resolve (free offers 44.1 or 48; Studio adds 96/192).
-- Projects actually running at 96/192 kHz will have audio media whose blobs
-- decode successfully, so the majority-vote path handles them correctly.
local function pick_majority_audio_sample_rate(parse_result)
    local votes = {}
    for _, timeline in ipairs(parse_result.timelines or {}) do
        for _, info in pairs(timeline.media_files or {}) do
            local r = info.audio_sample_rate
            if r and r > 0 then votes[r] = (votes[r] or 0) + 1 end
        end
    end
    local picked, best_count = nil, 0
    for r, c in pairs(votes) do
        if c > best_count then picked, best_count = r, c end
    end
    if not picked then
        -- No audio media decoded; fall back to Resolve's standard default.
        -- TODO: replace with Fairlight FieldsBlob decode (see comment above).
        log.warn("pick_majority_audio_sample_rate: no audio media decoded; " ..
            "defaulting to 48000 Hz (Resolve standard default — TODO: decode Fairlight FieldsBlob)")
        return 48000
    end
    return picked
end
-- Exposed so command-layer importers (ImportResolveProject) can derive the
-- project's audio_sample_rate from the same parse_result the convert() flow
-- uses.
M.pick_majority_audio_sample_rate = pick_majority_audio_sample_rate

--- Derive the JVE project-settings table from a parsed DRP.
-- Format-knowledge: which fields the parse_result carries + the
-- master-clock / default-fps defaults JVE requires on every project
-- (018 FR-028 / FR-036a — DRPs don't carry a master-clock concept of
-- their own, so we fill in the spec'd defaults).
-- @param parse_result table  — the result of M.parse_drp_file
-- @param audio_sample_rate number  — caller-resolved audio rate (the DRP
--   carries no project-wide default; the caller resolves explicit-arg
--   vs majority-vote, see pick_majority_audio_sample_rate).
-- @return table  settings ready to JSON-encode into projects.settings
function M.derive_project_settings(parse_result, audio_sample_rate)
    assert(parse_result and parse_result.project and parse_result.project.settings,
        "drp_importer.derive_project_settings: parse_result.project.settings required")
    local s = parse_result.project.settings
    assert(type(s.frame_rate) == "number" and s.frame_rate > 0, string.format(
        "drp_importer.derive_project_settings: frame_rate must be a positive number; got %s",
        tostring(s.frame_rate)))
    assert(type(s.width) == "number" and s.width > 0, string.format(
        "drp_importer.derive_project_settings: width must be a positive number; got %s",
        tostring(s.width)))
    assert(type(s.height) == "number" and s.height > 0, string.format(
        "drp_importer.derive_project_settings: height must be a positive number; got %s",
        tostring(s.height)))
    assert(type(audio_sample_rate) == "number" and audio_sample_rate > 0, string.format(
        "drp_importer.derive_project_settings: audio_sample_rate must be a positive number; got %s",
        tostring(audio_sample_rate)))
    return {
        frame_rate        = s.frame_rate,
        width             = s.width,
        height            = s.height,
        audio_sample_rate = audio_sample_rate,
        master_clock_hz   = subframe_math.MASTER_CLOCK_HZ,
        default_fps       = { num = 24, den = 1 },
    }
end

--- Translate a parsed DRP's tab UUIDs to JVE sequence ids for tab
--- restoration. Pure transform; does NOT write to the DB (the caller
--- decides what to do with the result — typically writes
--- ``open_sequence_ids`` / ``last_open_sequence_id`` project settings).
--- Asserts on any unresolved UUID — a missing mapping means a timeline
--- the DRP marked open was silently dropped during import.
--- @param parse_result table
--- @param import_result table  — output of M.import_into_project
--- @return table|nil  ``{ open_sequence_ids, active_sequence_id }``
---                    or nil when the DRP has no open tabs.
function M.extract_tab_state(parse_result, import_result)
    assert(parse_result and parse_result.project,
        "drp_importer.extract_tab_state: parse_result.project required")
    assert(import_result,
        "drp_importer.extract_tab_state: import_result required")

    local open_tab_uuids = parse_result.project.open_timeline_ids
    if not open_tab_uuids or #open_tab_uuids == 0 then return nil end
    local active_tab_uuid = parse_result.project.active_timeline_id
    local tab_uuid_to_sequence_id = import_result.tab_uuid_to_sequence_id
    assert(type(tab_uuid_to_sequence_id) == "table", string.format(
        "drp_importer.extract_tab_state: import_result.tab_uuid_to_sequence_id "
        .. "must be a table populated by import_into_project; got %s",
        type(tab_uuid_to_sequence_id)))

    local open_sequence_ids, active_sequence_id = {}, nil
    for _, tab_uuid in ipairs(open_tab_uuids) do
        local seq_id = tab_uuid_to_sequence_id[tab_uuid]
        assert(seq_id, string.format(
            "drp_importer.extract_tab_state: open timeline tab UUID %s has "
            .. "no corresponding sequence. Timeline was present in "
            .. "project.xml open-tab list but never created during import "
            .. "(check for parse_drp_file skips or a mismatch between "
            .. "Sm2Sequence.DbId and the id used in SequenceTabsData / "
            .. "TimelineHandleVec).",
            tostring(tab_uuid)))
        open_sequence_ids[#open_sequence_ids + 1] = seq_id
        if tab_uuid == active_tab_uuid then
            active_sequence_id = seq_id
        end
    end

    -- Open tabs known ⇒ active tab must also be known. Both Phase A
    -- priorities (SequenceTabsData, TimelineHandleVec+Index) emit
    -- active_tab_uuid whenever they emit open_tab_uuids. Any violation
    -- here means the parser returned inconsistent state — fail loud.
    assert(active_tab_uuid, string.format(
        "drp_importer.extract_tab_state: %d open tab UUIDs but "
        .. "active_tab_uuid is nil — parser returned inconsistent tab state",
        #open_tab_uuids))
    assert(active_sequence_id, string.format(
        "drp_importer.extract_tab_state: active timeline UUID %s was not "
        .. "in the open-tab list %s — project.xml inconsistency",
        tostring(active_tab_uuid), table.concat(open_tab_uuids, ",")))

    return {
        open_sequence_ids   = open_sequence_ids,
        active_sequence_id  = active_sequence_id,
    }
end

M.frame_rate_to_rational = importer_core.frame_rate_to_rational
M.decode_bt_clip_path = decode_bt_clip_path

return M
