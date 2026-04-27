--- Premiere Pro .prproj Importer — parse gzipped XML to intermediate representation.
--
-- Responsibilities:
-- - parse_prproj_file(): Parse .prproj (gzipped XML) to structured Lua tables
-- - quick_metadata(): Lightweight name extraction (no full parse)
-- - convert(): Parse .prproj and create new .jvp database (Open verb)
--
-- The intermediate representation matches drp_importer's parse_result schema,
-- so importer_core.import_into_project() works unchanged.
--
-- Invariants:
-- - All tick→frame conversions use exact integer division (no rounding for standard rates)
-- - Synthetic media (Color Matte, generators) are skipped
-- - All coordinates are integers after conversion
--
-- @file prproj_importer.lua
local M = {}

local log = require("core.logger").for_area("media")
local importer_core = require("importers.importer_core")

-- Premiere's universal tick rate: LCM of all standard frame/sample rates
local TICKS_PER_SECOND = 254016000000

-- ---------------------------------------------------------------------------
-- XML helpers (same patterns as drp_importer)
-- ---------------------------------------------------------------------------

local function find_direct_child(elem, tag_name)
    if not elem or not elem.children then return nil end
    for _, child in ipairs(elem.children) do
        if child.tag == tag_name then return child end
    end
    return nil
end

local function find_all_direct_children(elem, tag_name)
    local results = {}
    if not elem or not elem.children then return results end
    for _, child in ipairs(elem.children) do
        if child.tag == tag_name then
            results[#results + 1] = child
        end
    end
    return results
end

local function find_all_elements(elem, tag_name)
    local results = {}
    if not elem then return results end
    local function walk(e)
        if e.tag == tag_name then results[#results + 1] = e end
        for _, child in ipairs(e.children or {}) do walk(child) end
    end
    walk(elem)
    return results
end

local function get_text(elem)
    if not elem then return nil end
    if elem.text then return elem.text:match("^%s*(.-)%s*$") end
    -- Text may be in first text child
    for _, child in ipairs(elem.children or {}) do
        if type(child) == "string" then return child:match("^%s*(.-)%s*$") end
    end
    return nil
end

local function get_child_text(parent, tag_name)
    local child = find_direct_child(parent, tag_name)
    return child and get_text(child) or nil
end

local function get_child_number(parent, tag_name)
    local text = get_child_text(parent, tag_name)
    return text and tonumber(text) or nil
end

--- Get a property value from a Properties element.
-- Premiere stores sequence properties as <PropertyName>value</PropertyName> inside
-- <Properties> inside <Node>.
local function get_property(elem, prop_name)
    local node = find_direct_child(elem, "Node")
    if not node then return nil end
    local props = find_direct_child(node, "Properties")
    if not props then return nil end
    return get_child_text(props, prop_name)
end

local function get_property_number(elem, prop_name)
    local text = get_property(elem, prop_name)
    return text and tonumber(text) or nil
end

-- ---------------------------------------------------------------------------
-- Tick conversion
-- ---------------------------------------------------------------------------

local function ticks_to_frames(ticks, ticks_per_frame)
    assert(type(ticks) == "number",
        "prproj: ticks_to_frames: ticks must be number, got " .. type(ticks))
    assert(type(ticks_per_frame) == "number" and ticks_per_frame > 0,
        "prproj: ticks_to_frames: ticks_per_frame must be > 0, got " .. tostring(ticks_per_frame))
    -- Exact integer division for standard rates; round for non-standard
    return math.floor(ticks / ticks_per_frame + 0.5)
end

local function ticks_per_frame_to_fps(ticks_per_frame)
    assert(ticks_per_frame > 0, "prproj: invalid ticks_per_frame: " .. tostring(ticks_per_frame))
    return TICKS_PER_SECOND / ticks_per_frame
end

-- ---------------------------------------------------------------------------
-- Object reference index
-- ---------------------------------------------------------------------------

--- Build lookup tables for ObjectUID (UUID) and ObjectID (integer) references.
-- ObjectUIDs are globally unique. ObjectIDs may collide in range 1-60 across
-- different element types, but import-relevant entities (SubClip, Clip, Source)
-- use IDs >2000.
local function build_object_index(root)
    local by_uuid = {}   -- ObjectUID string → element
    local by_id = {}     -- ObjectID integer → element (last-wins for collisions)

    local function walk(elem)
        if not elem or type(elem) ~= "table" then return end
        local attrs = elem.attrs
        if attrs then
            local ouid = attrs.ObjectUID
            if ouid then by_uuid[ouid] = elem end
            local oid = attrs.ObjectID
            if oid then by_id[tonumber(oid)] = elem end
        end
        for _, child in ipairs(elem.children or {}) do
            if type(child) == "table" then walk(child) end
        end
    end
    walk(root)
    return by_uuid, by_id
end

-- ---------------------------------------------------------------------------
-- Decompress
-- ---------------------------------------------------------------------------

local function decompress_prproj(prproj_path)
    local tmp_path = os.tmpname() .. ".xml"
    local cmd = string.format('gunzip -c %q > %q', prproj_path, tmp_path)
    local exit_code = os.execute(cmd)
    assert(exit_code == 0 or exit_code == true,
        "prproj: gunzip failed for " .. prproj_path)
    return tmp_path
end

-- ---------------------------------------------------------------------------
-- Media parsing
-- ---------------------------------------------------------------------------

--- Check if a Media element is synthetic (Color Matte, generator, etc.)
local function is_synthetic_media(media_elem)
    -- Synthetic media has numeric-only FilePath or Infinite=true
    local file_path = get_child_text(media_elem, "FilePath")
    if not file_path or file_path == "" then return true end
    -- Numeric-only path = ImplementationID for generators
    if file_path:match("^%d+$") then return true end
    -- Infinite media (bars, tone, etc.)
    local infinite = get_child_text(media_elem, "Infinite")
    if infinite == "true" then return true end
    return false
end

--- Strip Premiere's /// prefix from file paths.
local function clean_file_path(raw_path)
    if not raw_path then return nil end
    -- Premiere uses ///path for absolute, //host/share for UNC
    return raw_path:gsub("^///", "/"):gsub("^//", "/")
end

--- Count channels in an AudioChannelLayout JSON string.
-- Layout example: '[{"channellabel":100},{"channellabel":101}]' (2 channels).
-- We count "channellabel" occurrences rather than running a JSON parser —
-- the layout is flat and the labels are 1:1 with channels.
local function count_audio_channels(layout_text)
    if not layout_text or layout_text == "" then return 0 end
    local n = 0
    for _ in layout_text:gmatch('channellabel') do n = n + 1 end
    return n
end

--- Resolve <AudioStream ObjectRef="N"/> to its per-stream metadata.
-- The referenced AudioStream carries FrameRate (ticks-per-sample) and
-- AudioChannelLayout. <ConformedAudioRate> on the Media is a project-
-- level conforming target, not per-file, so must not be used as the
-- authoritative sample rate.
local function resolve_audio_stream(media_elem, by_id)
    local ref = find_direct_child(media_elem, "AudioStream")
    if not ref or not ref.attrs or not ref.attrs.ObjectRef then
        return nil
    end
    local stream = by_id[tonumber(ref.attrs.ObjectRef)]
    if not stream then return nil end

    local ticks_per_sample = get_child_number(stream, "FrameRate")
    assert(ticks_per_sample and ticks_per_sample > 0, string.format(
        "prproj: AudioStream %s missing/invalid FrameRate",
        tostring(ref.attrs.ObjectRef)))
    local sample_rate = math.floor(TICKS_PER_SECOND / ticks_per_sample + 0.5)

    local layout_text = get_child_text(stream, "AudioChannelLayout")
    local channels = count_audio_channels(layout_text)
    assert(channels > 0, string.format(
        "prproj: AudioStream %s has no channels in AudioChannelLayout",
        tostring(ref.attrs.ObjectRef)))

    return { sample_rate = sample_rate, channels = channels }
end

--- Parse a Media element to extract file metadata.
local function parse_media_element(media_elem, by_id)
    if is_synthetic_media(media_elem) then return nil end

    local uuid = media_elem.attrs and media_elem.attrs.ObjectUID
    assert(uuid, "prproj: Media element missing ObjectUID")

    local raw_path = get_child_text(media_elem, "FilePath")
        or get_child_text(media_elem, "ActualMediaFilePath")
    local file_path = clean_file_path(raw_path)
    local name = get_child_text(media_elem, "Title") or (file_path and file_path:match("([^/]+)$"))

    local has_video = find_direct_child(media_elem, "VideoStream") ~= nil
    local audio_info = resolve_audio_stream(media_elem, by_id)

    return {
        file_uuid = uuid,
        name = name or "Untitled",
        file_path = file_path,
        has_video = has_video,
        has_audio = audio_info ~= nil,
        audio_sample_rate = audio_info and audio_info.sample_rate or nil,
        audio_channels = audio_info and audio_info.channels or 0,
        alt_paths = {},
    }
end

M._parse_media_element = parse_media_element  -- exported for tests

-- ---------------------------------------------------------------------------
-- Sequence + Track + Clip parsing
-- ---------------------------------------------------------------------------

--- Parse a single track's clips from a VideoClipTrack or AudioClipTrack element.
local function parse_track_clips(track_elem, by_id, by_uuid, ticks_per_frame, track_type)
    local clips = {}

    -- Find ClipItems → TrackItems
    local clip_track = find_direct_child(track_elem, "ClipTrack")
    if not clip_track then return clips end

    local clip_items = find_direct_child(clip_track, "ClipItems")
    if not clip_items then return clips end

    local track_items_elem = find_direct_child(clip_items, "TrackItems")
    if not track_items_elem then return clips end

    for _, ti_ref in ipairs(find_all_direct_children(track_items_elem, "TrackItem")) do
        local ref_id = ti_ref.attrs and ti_ref.attrs.ObjectRef
        if not ref_id then goto next_track_item end

        local ti_elem = by_id[tonumber(ref_id)]
        if not ti_elem then
            log.warn("prproj: TrackItem ObjectRef %s not found", tostring(ref_id))
            goto next_track_item
        end

        -- Skip transition items
        if ti_elem.tag:find("Transition") then goto next_track_item end

        -- Get timeline position
        local cti = find_direct_child(ti_elem, "ClipTrackItem")
        if not cti then goto next_track_item end

        local inner_ti = find_direct_child(cti, "TrackItem")
        local start_ticks = inner_ti and get_child_number(inner_ti, "Start") or 0
        local end_ticks = inner_ti and get_child_number(inner_ti, "End")
        if not end_ticks then goto next_track_item end

        -- Enabled state
        local is_muted = get_child_text(cti, "IsMuted")
        local enabled = is_muted ~= "true"

        -- Follow reference chain: SubClip → Clip → Source → Media
        local subclip_ref = find_direct_child(cti, "SubClip")
        if not subclip_ref then goto next_track_item end
        local subclip_id = subclip_ref.attrs and subclip_ref.attrs.ObjectRef
        if not subclip_id then goto next_track_item end

        local subclip = by_id[tonumber(subclip_id)]
        if not subclip then
            log.warn("prproj: SubClip %s not found", tostring(subclip_id))
            goto next_track_item
        end

        local clip_name = get_child_text(subclip, "Name") or "Untitled"

        -- Resolve Clip → InPoint/OutPoint
        local clip_ref = find_direct_child(subclip, "Clip")
        local in_point_ticks, out_point_ticks
        local media_uuid

        if clip_ref and clip_ref.attrs and clip_ref.attrs.ObjectRef then
            local clip_elem = by_id[tonumber(clip_ref.attrs.ObjectRef)]
            if clip_elem then
                -- InPoint/OutPoint are inside the nested <Clip> element
                local inner_clip = find_direct_child(clip_elem, "Clip")
                if inner_clip then
                    in_point_ticks = get_child_number(inner_clip, "InPoint")
                    out_point_ticks = get_child_number(inner_clip, "OutPoint")

                    -- Source → Media
                    local source_ref = find_direct_child(inner_clip, "Source")
                    if source_ref and source_ref.attrs and source_ref.attrs.ObjectRef then
                        local source_elem = by_id[tonumber(source_ref.attrs.ObjectRef)]
                        if source_elem then
                            local media_source = find_direct_child(source_elem, "MediaSource")
                            if media_source then
                                local media_ref = find_direct_child(media_source, "Media")
                                if media_ref and media_ref.attrs then
                                    media_uuid = media_ref.attrs.ObjectURef
                                end
                            end
                        end
                    end
                end
            end
        end

        if not media_uuid then
            log.detail("Skipping clip '%s' — no media reference", clip_name)
            goto next_track_item
        end

        -- Look up media for file_path
        local media_elem = by_uuid[media_uuid]
        local file_path = nil
        if media_elem then
            local raw = get_child_text(media_elem, "FilePath")
                or get_child_text(media_elem, "ActualMediaFilePath")
            file_path = clean_file_path(raw)
            -- Skip synthetic media clips
            if is_synthetic_media(media_elem) then
                log.detail("Skipping synthetic clip '%s'", clip_name)
                goto next_track_item
            end
        end

        -- Convert ticks to frames
        local start_frame = ticks_to_frames(start_ticks, ticks_per_frame)
        local end_frame = ticks_to_frames(end_ticks, ticks_per_frame)
        local duration_frames = end_frame - start_frame

        -- InPoint/OutPoint are authoritative source coords in Premiere's
        -- model. A TrackItem missing either is malformed .prproj (third-
        -- party PRPROJ-READER defaults to 0, but Adobe's own scripting
        -- docs describe these as concrete Time values with no documented
        -- default — Premiere itself always writes them).
        assert(in_point_ticks, string.format(
            "prproj: clip '%s' missing InPoint (malformed TrackItem)", clip_name))
        assert(out_point_ticks, string.format(
            "prproj: clip '%s' missing OutPoint (malformed TrackItem)", clip_name))
        local source_in = ticks_to_frames(in_point_ticks, ticks_per_frame)
        local source_out = ticks_to_frames(out_point_ticks, ticks_per_frame)

        if duration_frames <= 0 then
            log.warn("Skipping zero-duration clip '%s' (start=%d end=%d)",
                clip_name, start_frame, end_frame)
            goto next_track_item
        end

        clips[#clips + 1] = {
            name = clip_name,
            start_value = start_frame,
            duration = duration_frames,
            source_in = source_in,
            source_out = source_out,
            file_uuid = media_uuid,
            file_path = file_path,
            clip_speed = 1.0,
            enabled = enabled,
        }

        ::next_track_item::
    end

    return clips
end

--- Parse a Sequence element into the intermediate representation.
local function parse_sequence(seq_elem, by_id, by_uuid, media_items)
    local name = get_child_text(seq_elem, "Name")
    assert(name, "prproj: Sequence missing Name")

    -- ZeroPoint (start TC) and EditLine (playhead)
    local zero_point_ticks = get_property_number(seq_elem, "MZ.ZeroPoint") or 0
    local edit_line_ticks = get_property_number(seq_elem, "MZ.EditLine") or 0

    -- Find TrackGroups
    local track_groups_elem = find_direct_child(seq_elem, "TrackGroups")
    assert(track_groups_elem, "prproj: Sequence '" .. name .. "' missing TrackGroups")

    local video_group, audio_group
    for _, tg in ipairs(find_all_direct_children(track_groups_elem, "TrackGroup")) do
        local second = find_direct_child(tg, "Second")
        if second and second.attrs and second.attrs.ObjectRef then
            local group_elem = by_id[tonumber(second.attrs.ObjectRef)]
            if group_elem then
                if group_elem.tag == "VideoTrackGroup" then
                    video_group = group_elem
                elseif group_elem.tag == "AudioTrackGroup" then
                    audio_group = group_elem
                end
            end
        end
    end

    assert(video_group, "prproj: Sequence '" .. name .. "' missing VideoTrackGroup")

    -- Frame rate from VideoTrackGroup
    local inner_vtg = find_direct_child(video_group, "TrackGroup")
    local video_ticks_per_frame = get_child_number(inner_vtg, "FrameRate")
    assert(video_ticks_per_frame and video_ticks_per_frame > 0,
        "prproj: Sequence '" .. name .. "' missing video FrameRate")

    local fps = ticks_per_frame_to_fps(video_ticks_per_frame)

    -- Resolution from VideoTrackGroup. .prproj reliably emits FrameRect on
    -- video track groups; a missing one indicates malformed input — fail
    -- loud rather than fabricate dimensions.
    local frame_rect_str = get_child_text(video_group, "FrameRect")
    assert(frame_rect_str, string.format(
        "prproj: sequence '%s' missing FrameRect on VideoTrackGroup", name))
    local x1, y1, x2, y2 = frame_rect_str:match("(%d+),(%d+),(%d+),(%d+)")
    assert(x2 and y2, string.format(
        "prproj: sequence '%s' has malformed FrameRect '%s'",
        name, frame_rect_str))
    local width  = tonumber(x2) - tonumber(x1)
    local height = tonumber(y2) - tonumber(y1)
    assert(width > 0 and height > 0, string.format(
        "prproj: sequence '%s' has non-positive dimensions %dx%d (FrameRect '%s')",
        name, width, height, frame_rect_str))

    -- Audio ticks per sample
    local audio_ticks_per_sample
    if audio_group then
        local inner_atg = find_direct_child(audio_group, "TrackGroup")
        audio_ticks_per_sample = get_child_number(inner_atg, "FrameRate")
    end

    -- Convert ZeroPoint and EditLine to frames
    local start_tc_seconds = zero_point_ticks / TICKS_PER_SECOND

    -- Playhead relative to start TC
    local playhead_ticks_from_start = edit_line_ticks
    local cur_playhead_relative = ticks_to_frames(playhead_ticks_from_start, video_ticks_per_frame)

    -- Parse video tracks
    local tracks = {}
    if inner_vtg then
        local vtg_tracks = find_direct_child(inner_vtg, "Tracks")
        if vtg_tracks then
            for _, track_ref in ipairs(find_all_direct_children(vtg_tracks, "Track")) do
                local track_uuid = track_ref.attrs and track_ref.attrs.ObjectURef
                if track_uuid then
                    local track_elem = by_uuid[track_uuid]
                    if track_elem then
                        local track_index = track_ref.attrs.Index
                        local clips = parse_track_clips(
                            track_elem, by_id, by_uuid, video_ticks_per_frame, "VIDEO")

                        tracks[#tracks + 1] = {
                            type = "VIDEO",
                            index = (tonumber(track_index) or 0) + 1,  -- 0-indexed → 1-indexed
                            clips = clips,
                        }
                    end
                end
            end
        end
    end

    -- Parse audio tracks
    if audio_group and audio_ticks_per_sample then
        local inner_atg = find_direct_child(audio_group, "TrackGroup")
        local atg_tracks = inner_atg and find_direct_child(inner_atg, "Tracks")
        if atg_tracks then
            for _, track_ref in ipairs(find_all_direct_children(atg_tracks, "Track")) do
                local track_uuid = track_ref.attrs and track_ref.attrs.ObjectURef
                if track_uuid then
                    local track_elem = by_uuid[track_uuid]
                    if track_elem then
                        local track_index = track_ref.attrs.Index
                        local clips = parse_track_clips(
                            track_elem, by_id, by_uuid, audio_ticks_per_sample, "AUDIO")

                        tracks[#tracks + 1] = {
                            type = "AUDIO",
                            index = (tonumber(track_index) or 0) + 1,
                            clips = clips,
                        }
                    end
                end
            end
        end
    end

    -- Update media_items with duration from Sources encountered during clip parsing
    -- (Media elements don't always have duration directly)

    return {
        name = name,
        fps = fps,
        width = width,
        height = height,
        start_tc_seconds = start_tc_seconds,
        cur_playhead_relative = cur_playhead_relative,
        tracks = tracks,
    }
end

-- ---------------------------------------------------------------------------
-- Media duration extraction
-- ---------------------------------------------------------------------------

--- Extract media durations from VideoMediaSource/AudioMediaSource elements.
-- These have OriginalDuration in ticks + reference to their Media ObjectURef.
local function extract_media_durations(root, by_id, by_uuid, media_items)
    -- Video sources
    for _, vms in ipairs(find_all_elements(root, "VideoMediaSource")) do
        local dur_ticks = get_child_number(vms, "OriginalDuration")
        local media_source = find_direct_child(vms, "MediaSource")
        if dur_ticks and media_source then
            local media_ref = find_direct_child(media_source, "Media")
            if media_ref and media_ref.attrs and media_ref.attrs.ObjectURef then
                local uuid = media_ref.attrs.ObjectURef
                local item = media_items[uuid]
                if item and not item.duration then
                    -- Need ticks_per_frame from the Media's video stream
                    -- Use the media's native frame rate if available
                    local media_elem = by_uuid[uuid]
                    if media_elem then
                        local vs_ref = find_direct_child(media_elem, "VideoStream")
                        if vs_ref and vs_ref.attrs and vs_ref.attrs.ObjectRef then
                            local vs = by_id[tonumber(vs_ref.attrs.ObjectRef)]
                            if vs then
                                local fr = get_child_number(vs, "FrameRate")
                                if fr and fr > 0 then
                                    item.duration = ticks_to_frames(dur_ticks, fr)
                                    item.frame_rate = ticks_per_frame_to_fps(fr)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Audio sources — duration in samples
    for _, ams in ipairs(find_all_elements(root, "AudioMediaSource")) do
        local dur_ticks = get_child_number(ams, "OriginalDuration")
        local media_source = find_direct_child(ams, "MediaSource")
        if dur_ticks and media_source then
            local media_ref = find_direct_child(media_source, "Media")
            if media_ref and media_ref.attrs and media_ref.attrs.ObjectURef then
                local uuid = media_ref.attrs.ObjectURef
                local item = media_items[uuid]
                if item and not item.duration then
                    -- An AudioMediaSource should only reference a Media whose
                    -- AudioStream we already parsed — assert to surface any
                    -- malformed .prproj where that invariant breaks.
                    assert(item.audio_sample_rate and item.audio_sample_rate > 0,
                        string.format(
                            "prproj: AudioMediaSource for Media %s has no audio_sample_rate"
                            .. " — AudioStream missing or unparsed", tostring(uuid)))
                    local ticks_per_sample = TICKS_PER_SECOND / item.audio_sample_rate
                    item.duration = ticks_to_frames(dur_ticks, ticks_per_sample)
                    item.frame_rate = item.audio_sample_rate
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Bin parsing
-- ---------------------------------------------------------------------------

local function parse_bins(root, by_uuid)
    local folders = {}
    -- Find BinProjectItem elements (not RootProjectItem)
    for _, bin_elem in ipairs(find_all_elements(root, "BinProjectItem")) do
        local uuid = bin_elem.attrs and bin_elem.attrs.ObjectUID
        if not uuid then goto next_bin end

        local proj_item = find_direct_child(bin_elem, "ProjectItem")
        local name = proj_item and get_child_text(proj_item, "Name") or "Untitled Bin"

        folders[#folders + 1] = {
            id = uuid,
            name = name,
            parent_id = nil,  -- Premiere bins are flat in most exports
        }
        ::next_bin::
    end
    return folders
end

-- ---------------------------------------------------------------------------
-- Main parse function
-- ---------------------------------------------------------------------------

--- Parse a .prproj file into the intermediate representation.
-- @param prproj_path string: Path to .prproj file
-- @param progress_cb function|nil: optional progress(pct, text)
-- @return table: parse_result (same schema as drp_importer)
function M.parse_prproj_file(prproj_path, progress_cb)
    assert(prproj_path and prproj_path ~= "", "prproj_importer: prproj_path required")
    local report = progress_cb or function() end

    report(5, "Decompressing…")
    local xml_path = decompress_prproj(prproj_path)

    report(10, "Parsing XML…")
    assert(_G.qt_xml_parse, "prproj_importer: qt_xml_parse not available (requires C++ bindings)")
    local root = _G.qt_xml_parse(xml_path)
    os.remove(xml_path)
    assert(root, "prproj_importer: failed to parse XML from " .. prproj_path)
    assert(root.tag == "PremiereData",
        "prproj_importer: expected <PremiereData> root, got <" .. tostring(root.tag) .. ">")

    report(20, "Building reference index…")
    local by_uuid, by_id = build_object_index(root)

    -- Parse all Media elements
    report(30, "Parsing media…")
    local media_items = {}
    for _, media_elem in ipairs(find_all_elements(root, "Media")) do
        if media_elem.attrs and media_elem.attrs.ObjectUID then
            local item = parse_media_element(media_elem, by_id)
            if item then
                media_items[item.file_uuid] = item
            end
        end
    end

    -- Extract durations from Source elements
    report(40, "Extracting durations…")
    extract_media_durations(root, by_id, by_uuid, media_items)

    -- Parse sequences
    report(50, "Parsing sequences…")
    local timelines = {}
    local sequences = find_all_elements(root, "Sequence")
    for _, seq_elem in ipairs(sequences) do
        if seq_elem.attrs and seq_elem.attrs.ObjectUID then
            -- No pcall: a broken <Sequence> element must surface as an
            -- import failure with the underlying assert, not silently
            -- drop the sequence and produce a partial project. If real-
            -- world .prproj files demand partial-import tolerance, re-
            -- introduce pcall consciously with a surfaced error UI.
            local timeline = parse_sequence(seq_elem, by_id, by_uuid, media_items)
            timelines[#timelines + 1] = timeline
            log.event("Parsed sequence: %s (%.3f fps, %dx%d, %d tracks)",
                timeline.name, timeline.fps, timeline.width, timeline.height, #timeline.tracks)
        end
    end

    -- Parse project metadata
    report(70, "Parsing project metadata…")
    local project_name = prproj_path:match("([^/]+)%.prproj$") or "Untitled"
    local project_fps = 25
    local project_width, project_height = 1920, 1080
    if #timelines > 0 then
        project_fps = timelines[1].fps
        project_width = timelines[1].width
        project_height = timelines[1].height
    end

    -- Parse bins
    report(80, "Parsing bins…")
    local folders = parse_bins(root, by_uuid)

    -- Determine active/open timelines
    local active_timeline_name = #timelines > 0 and timelines[1].name or nil
    local open_timeline_names = {}
    for _, tl in ipairs(timelines) do
        open_timeline_names[#open_timeline_names + 1] = tl.name
    end

    -- Fill in media_start_time from ZeroPoint (if media has TC)
    -- Premiere stores TC origin in the Sequence's ZeroPoint, not per-media.
    -- Skip for now — media_start_time is optional.

    report(90, "Done parsing")

    return {
        success = true,
        project = {
            name = project_name,
            settings = {
                frame_rate = project_fps,
                width = project_width,
                height = project_height,
                -- 013: every sequence carries audio_sample_rate. .prproj doesn't
                -- expose a project-level mix bus rate; use industry default.
                audio_sample_rate = 48000,
            },
        },
        media_items = media_items,
        timelines = timelines,
        folders = folders,
        pool_master_clips = {},  -- Premiere doesn't have separate pool marks
        active_timeline_name = active_timeline_name,
        open_timeline_names = open_timeline_names,
    }
end

-- ---------------------------------------------------------------------------
-- Quick metadata (lightweight)
-- ---------------------------------------------------------------------------

function M.quick_metadata(prproj_path)
    local name = prproj_path:match("([^/]+)%.prproj$")
    if name then
        return { name = name }
    end
    return nil, "Could not extract name from path"
end

-- ---------------------------------------------------------------------------
-- Convert: Parse .prproj and create new .jvp (Open verb)
-- ---------------------------------------------------------------------------

function M.convert(prproj_path, jvp_path, progress_cb)
    assert(prproj_path and prproj_path ~= "", "prproj_importer.convert: prproj_path required")
    assert(jvp_path and jvp_path ~= "", "prproj_importer.convert: jvp_path required")
    local raw_report = progress_cb or function() end
    local function report(pct, text)
        if raw_report(pct, text) == "cancel" then
            error({cancelled = true}, 0)
        end
    end

    log.event("Converting %s -> %s", prproj_path, jvp_path)

    local convert_ok, convert_err = pcall(function()

    report(5, "Parsing project…")
    local parse_progress = progress_cb and function(sub_pct, text)
        report(5 + math.floor(sub_pct * 0.25), text)
    end or nil
    local parse_result = M.parse_prproj_file(prproj_path, parse_progress)
    assert(parse_result.success, "Failed to parse .prproj: " .. tostring(parse_result.error))

    report(30, "Creating project database…")

    os.remove(jvp_path)
    os.remove(jvp_path .. "-shm")
    os.remove(jvp_path .. "-wal")

    local database = require("core.database")
    database.init(jvp_path)

    local Project = require("models.project")
    local json = require("dkjson")
    local settings = parse_result.project.settings

    local project = Project.create(parse_result.project.name, {
        settings = json.encode(settings),
        fps_mismatch_policy = "resample",
    })
    assert(project:save(), "Failed to save project record")

    log.event("Created project: %s (%dx%d @ %sfps)",
        project.name, settings.width, settings.height, tostring(settings.frame_rate))

    report(40, "Importing media…")
    importer_core.import_into_project(project.id, parse_result, {
        project_settings = settings,
        progress_cb = progress_cb and function(sub_pct, text)
            report(40 + math.floor(sub_pct * 0.5), text)
        end or nil,
    })

    -- Store open timeline state
    report(95, "Setting active timeline…")
    local pid = database.get_current_project_id()
    if parse_result.active_timeline_name then
        local sequences = database.load_sequences(pid)
        local name_to_seq = {}
        for _, seq in ipairs(sequences) do name_to_seq[seq.name] = seq end

        if parse_result.open_timeline_names and #parse_result.open_timeline_names > 0 then
            local open_ids = {}
            local active_id = nil
            for _, tl_name in ipairs(parse_result.open_timeline_names) do
                local seq = name_to_seq[tl_name]
                if seq then
                    open_ids[#open_ids + 1] = seq.id
                    if tl_name == parse_result.active_timeline_name then
                        active_id = seq.id
                    end
                end
            end
            if #open_ids > 0 then
                database.set_project_setting(pid, "open_sequence_ids", open_ids)
            end
            if active_id then
                database.set_project_setting(pid, "last_open_sequence_id", active_id)
            end
        end
    end

    report(100, "Done")

    end) -- pcall

    if not convert_ok then
        if type(convert_err) == "table" and convert_err.cancelled then
            return false, "Cancelled"
        end
        error(convert_err)
    end
    return true
end

-- Expose for tests
M.ticks_to_frames = ticks_to_frames
M.ticks_per_frame_to_fps = ticks_per_frame_to_fps
M.TICKS_PER_SECOND = TICKS_PER_SECOND
M.frame_rate_to_rational = importer_core.frame_rate_to_rational

return M
