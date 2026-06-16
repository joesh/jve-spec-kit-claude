--- Shared importer core — format-agnostic entity creation from parse results.
--
-- Responsibilities:
-- - import_into_project(): Create media, sequences, tracks, clips, A/V links
--   from a format-neutral intermediate representation (parse_result).
-- - frame_rate_to_rational(): Float fps → (numerator, denominator)
-- - infer_fps_from_one_hour_start(): Heuristic fps from 1-hour TC convention
--
-- Used by:
-- - drp_importer.lua (DaVinci Resolve .drp)
-- - prproj_importer.lua (Premiere Pro .prproj)
--
-- Invariants:
-- - All DB access goes through model APIs (SQL isolation)
-- - All coordinates are integers (frames or samples)
-- - No format-specific logic — format parsers produce parse_result, this consumes it
--
-- @file importer_core.lua
local M = {}

local log = require("core.logger").for_area("media")

-- Models (SQL isolation: all DB access goes through models)
local Media = require("models.media")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local ClipMarker = require("models.clip_marker")
local Property = require("models.property")
local clip_link = require("models.clip_link")
-- 018: sub-frame math primitive for audio clip source position conversion
-- (file samples → master.fps frame + master_clock_hz tick subframe). Pure
-- numeric helper; no DB coupling.
local subframe_math = require("core.subframe_math")

-- ---------------------------------------------------------------------------
-- Helper: Frame rate to rational
-- ---------------------------------------------------------------------------

function M.frame_rate_to_rational(frame_rate)
    local fps = tonumber(frame_rate)
    assert(fps and fps > 0, "importer_core: invalid frame_rate: " .. tostring(frame_rate))

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
-- Helper: Infer fps from 1-hour TC convention
-- ---------------------------------------------------------------------------

function M.infer_fps_from_one_hour_start(min_start_frame)
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
            log.event("Inferred %.3f fps from 1-hour TC start (frame %d ~ %d)",
                    marker[2], min_start_frame, expected)
            return marker[2], marker[3], marker[4]
        end
    end

    log.event("Could not infer fps from start frame %d (not near 1-hour TC)", min_start_frame)
    return nil
end

-- ---------------------------------------------------------------------------
-- Viewport math (pure, exposed for unit tests as M._compute_*)
-- ---------------------------------------------------------------------------
--
-- Sequences store viewport state (playhead_frame, view_start_frame) in
-- absolute timecode space — the same coordinate system as clip placements
-- and the sequence's start_timecode_frame. Display formatters never add
-- an offset; the TC string for any absolute frame is just that frame at
-- the sequence rate.

--- Compute the absolute playhead frame to store on a freshly imported
--- sequence. All inputs are already in absolute display-TC space:
---   opts.start_timecode_frame  — required, sequence start (absolute)
---   opts.src_scale             — present (>0) when source UI carried a
---                                playhead position
---   opts.src_playhead_rel      — playhead from source UI in absolute
---                                display-TC; defaults to start_tc
---                                (parked at sequence start)
---   opts.min_start_frame       — first clip's start_value (absolute) when
---                                no source UI state
--- Defensive: clamp below start_timecode_frame up to start (no pre-content).
function M._compute_playhead_frame(opts)
    assert(type(opts.start_timecode_frame) == "number",
        "_compute_playhead_frame: start_timecode_frame required")
    local abs_frame
    if opts.src_scale and opts.src_scale > 0 then
        abs_frame = opts.src_playhead_rel or opts.start_timecode_frame
    elseif opts.min_start_frame then
        abs_frame = opts.min_start_frame
    else
        return opts.start_timecode_frame
    end
    return math.max(opts.start_timecode_frame, abs_frame)
end

--- Compute the absolute view_start_frame for the source-UI-driven branch.
--- Centers around playhead_frame with half view_duration on either side,
--- clamped at start_timecode_frame (no pre-sequence space).
function M._compute_view_start_frame(opts)
    assert(type(opts.start_timecode_frame) == "number",
        "_compute_view_start_frame: start_timecode_frame required")
    assert(type(opts.playhead_frame) == "number",
        "_compute_view_start_frame: playhead_frame required (absolute)")
    assert(type(opts.view_duration) == "number" and opts.view_duration > 0,
        "_compute_view_start_frame: view_duration must be positive")
    return math.max(opts.start_timecode_frame,
        opts.playhead_frame - math.floor(opts.view_duration / 2))
end

-- ---------------------------------------------------------------------------
-- import_into_project: Format-agnostic entity creation from parse_result
-- ---------------------------------------------------------------------------

-- Sort the folder list so parents always come before their children
-- (the bin creator needs each parent's bin id to exist when it creates a
-- child). Sorts in place; returns the same table for chaining.
local function sort_folders_parent_first(folders)
    local lookup = {}
    for _, f in ipairs(folders) do lookup[f.id] = f end
    local function depth(f)
        local d = 0
        local cur = f
        while cur and cur.parent_id do
            d = d + 1
            cur = lookup[cur.parent_id]
        end
        return d
    end
    table.sort(folders, function(a, b) return depth(a) < depth(b) end)
    return folders
end

-- Create one JVE bin per source folder (parent-before-child order assumed
-- — see sort_folders_parent_first). Returns source-folder-id → bin-id.
local function import_folders_as_bins(project_id, folders, tag_service, uuid)
    local folder_to_bin = {}
    for _, folder in ipairs(folders) do
        local parent_bin_id = folder.parent_id and folder_to_bin[folder.parent_id] or nil
        local bin_id = uuid.generate_with_prefix("bin")
        local ok, def = tag_service.create_bin(project_id, {
            id        = bin_id,
            name      = folder.name,
            parent_id = parent_bin_id,
        })
        if ok and def then
            folder_to_bin[folder.id] = def.id
        else
            log.warn("Failed to create bin: %s", folder.name)
        end
    end
    return folder_to_bin
end

-- For each pool master clip with a known source folder, register both a
-- UUID-keyed lookup (reliable when the source format provides a stable id)
-- and a name-keyed fallback. Returns (uuid → bin, name → bin).
local function build_pool_clip_mappings(pool_master_clips, folder_to_bin)
    local pool_uuid_to_bin = {}
    local pool_name_to_bin = {}
    for _, pmc in ipairs(pool_master_clips) do
        if pmc.folder_id and folder_to_bin[pmc.folder_id] then
            if pmc.id then
                pool_uuid_to_bin[pmc.id] = folder_to_bin[pmc.folder_id]
            end
            pool_name_to_bin[pmc.name] = folder_to_bin[pmc.folder_id]
        end
    end
    return pool_uuid_to_bin, pool_name_to_bin
end

-- Create the "Unorganized" bin that orphaned media lands in. Returns the
-- bin id, or nil if creation fails (warning already logged by tag_service).
local function ensure_unorganized_bin(project_id, tag_service, uuid)
    local bin_id = uuid.generate_with_prefix("bin")
    local ok, def = tag_service.create_bin(project_id, {
        id   = bin_id,
        name = "Unorganized",
    })
    if ok and def then
        return def.id
    end
    return nil
end

-- If the media's file_path points at a /ProxyMedia/ folder, swap to a
-- non-proxy alt path when one exists. Returns:
--   "use", path     — proceed with `path` as the file_path
--   "skip", reason  — caller drops this media item (proxy with no original)
local function resolve_proxy_path(media_item)
    if not (media_item.file_path and media_item.file_path:find("/ProxyMedia/")) then
        return "use", media_item.file_path
    end
    for alt_path in pairs(media_item.alt_paths or {}) do
        if not alt_path:find("/ProxyMedia/") then
            return "use", alt_path
        end
    end
    return "skip", "proxy-only media (no non-proxy alt path)"
end

-- Same file_path + matching media_start_time = same media row. Different
-- media_start_time on the same path means the user applied a Set Timecode
-- override and we need a separate row (FR-003a). Returns the existing
-- row to dedupe against, or nil to fall through and create a new row.
local function find_dedup_match(media_by_path, media_item)
    local existing = media_by_path[media_item.file_path]
    if not existing then return nil end
    local existing_mst = existing._media_start_time
    local this_mst     = media_item.media_start_time
    local same_tc = (existing_mst == nil or this_mst == nil)
        or (existing_mst == this_mst)
        or (math.abs(existing_mst - this_mst) < 0.001)
    return same_tc and existing or nil
end

-- Build the metadata JSON for a media row. When media_start_time is
-- present the metadata carries video TC + (when audio is present) audio
-- TC. FR-001: when the file's container TC differs from the displayed
-- TC, also persist file_original_timecode for override detection.
local function build_media_metadata(media_item, native_rate)
    if not media_item.media_start_time then
        return '{}'
    end
    local json = require("dkjson")
    local mst = media_item.media_start_time
    local audio_sr = media_item.audio_sample_rate
    local has_video = media_item.has_video and true or false
    local has_audio = audio_sr and audio_sr > 0

    local meta = {}
    if not (has_video or has_audio) then
        -- Bad / malformed media item with neither V nor A characteristics.
        -- Leave metadata empty; downstream consumers gate on has_video /
        -- has_audio and won't attempt to read TC. ensure_master will
        -- refuse to build a master for this row.
        return json.encode(meta)
    end
    -- V pair written ONLY for files that actually have a video stream.
    -- Pre-normalization (≤ 2026-05-16) wrote start_tc_value for audio-
    -- only files too (using native_rate==sr), which was the 4-second-
    -- late overload — retired by feedback_timecode_is_truth's unified
    -- model. Audio-only files now carry their TC exclusively in the
    -- start_tc_audio_* pair.
    local start_tc_value
    if has_video then
        start_tc_value = math.floor(mst * native_rate + 0.5)
        meta.start_tc_value = start_tc_value
        meta.start_tc_rate  = native_rate
    end
    if has_audio then
        meta.start_tc_audio_samples = math.floor(mst * audio_sr + 0.5)
        meta.start_tc_audio_rate    = audio_sr
    end

    -- file_tc_seconds nil is normal (encrypted blobs, stock footage without
    -- decodable TracksBA, unmatched PMC enrichment). No override detection
    -- in that case — pre-feature behavior (file_original_timecode absent).
    if media_item.file_tc_seconds then
        if has_video then
            local file_tc_video = math.floor(media_item.file_tc_seconds * native_rate + 0.5)
            if file_tc_video ~= start_tc_value then
                meta.file_original_timecode = file_tc_video
                log.event("  Set Timecode override: start_tc=%d file_tc=%d (delta=%d frames)",
                    start_tc_value, file_tc_video, start_tc_value - file_tc_video)
            end
        end
        if has_audio then
            local file_tc_audio = math.floor(media_item.file_tc_seconds * audio_sr + 0.5)
            if file_tc_audio ~= meta.start_tc_audio_samples then
                meta.file_original_timecode_audio = file_tc_audio
            end
        end
    end

    return json.encode(meta)
end

-- Key `target` under every pool id that names its physical file: the item's
-- own file_uuid plus every alt_uuid the parser recorded. Resolve pools one
-- file under several MediaPoolItem ids (one per sync relationship); the parser
-- collapses them to one media entry and records the extra ids as alt_uuids, so
-- keying under all of them lets sync linkage resolve by ANY of the file's ids.
-- Asserts an id never maps to two different media entries — that would mean the
-- parser failed to collapse same-file pool clips (rule 1.14, fail loud).
local function register_media_aliases(target, media_item, media_by_uuid)
    local ids = {}
    if media_item.file_uuid then ids[media_item.file_uuid] = true end
    for alias in pairs(media_item.alt_uuids or {}) do ids[alias] = true end
    for id in pairs(ids) do
        assert(media_by_uuid[id] == nil or media_by_uuid[id] == target,
            string.format("register_media_aliases: pool id %s already maps to "
                .. "a different media (have %s, got %s) — parser failed to "
                .. "collapse same-file pool clips", id,
                tostring(media_by_uuid[id] and media_by_uuid[id].id),
                tostring(target.id)))
        media_by_uuid[id] = target
    end
end

-- Register the saved media entry in the by-uuid and by-path maps and stash
-- media_start_time so future dedup_match calls can compare TC overrides.
local function register_media_row(media, media_item, media_by_uuid, media_by_path)
    media._media_start_time = media_item.media_start_time
    register_media_aliases(media, media_item, media_by_uuid)
    media_by_path[media_item.file_path] = media
    for alt in pairs(media_item.alt_paths or {}) do
        media_by_path[alt] = media
    end
end

-- ============================================================================
-- Timeline-import phase helpers
-- ============================================================================

-- Find the (min start, max end) of every clip on the timeline. Both are
-- in absolute timecode space — clip start_value/duration come from the
-- parser pre-translated. Asserts the clips carry numeric start_value and
-- duration (rule 2.13).
local function compute_clip_position_extents(timeline_data)
    local min_start_frame, max_end_frame
    for _, track_data in ipairs(timeline_data.tracks) do
        for _, clip_data in ipairs(track_data.clips) do
            assert(type(clip_data.start_value) == "number", string.format(
                "import_into_project: clip '%s' missing start_value",
                tostring(clip_data.name)))
            assert(type(clip_data.duration) == "number", string.format(
                "import_into_project: clip '%s' missing duration",
                tostring(clip_data.name)))
            local s = clip_data.start_value
            local e = s + clip_data.duration
            if not min_start_frame or s < min_start_frame then min_start_frame = s end
            if e > (max_end_frame or 0) then max_end_frame = e end
        end
    end
    return min_start_frame, max_end_frame or 0
end

-- Resolve the timeline's frame rate. Order: explicit metadata → infer from
-- a 1-hour TC start → project default. Returns (fps_num, fps_den).
local function resolve_timeline_frame_rate(timeline_data, min_start_frame, project_settings)
    if timeline_data.fps and timeline_data.fps > 0 then
        local fps_num, fps_den = M.frame_rate_to_rational(timeline_data.fps)
        log.event("Using explicit fps from metadata: %.3f (%d/%d)",
                timeline_data.fps, fps_num, fps_den)
        return fps_num, fps_den
    end
    local inferred_fps, inferred_num, inferred_den = M.infer_fps_from_one_hour_start(min_start_frame)
    if inferred_fps then
        log.event("Inferred fps from 1-hour TC: %.3f (%d/%d)",
                inferred_fps, inferred_num, inferred_den)
        return inferred_num, inferred_den
    end
    local fps_num, fps_den = M.frame_rate_to_rational(project_settings.frame_rate)
    log.warn("No fps metadata, no 1-hour TC; using project default: %d/%d", fps_num, fps_den)
    return fps_num, fps_den
end

-- Compute the start_timecode_frame for the new sequence. start_tc_seconds
-- is the source format's timeline-start; convert to native frames at the
-- sequence's fps.
local function compute_sequence_start_tc(timeline_data, fps_num, fps_den)
    if not (timeline_data.start_tc_seconds and timeline_data.start_tc_seconds > 0) then
        return 0
    end
    local effective_fps = fps_num / fps_den
    local frame = math.floor(timeline_data.start_tc_seconds * effective_fps + 0.5)
    log.event("Timeline start TC: %.2fs → %d frames (%d/%d fps)",
        timeline_data.start_tc_seconds, frame, fps_num, fps_den)
    return frame
end

-- Compute the initial viewport state for the new sequence. Two paths:
--   * Source UI state (ui_scale + cur_playhead_relative present): translate.
--   * No source UI state: zoom-to-fit on clip extents, or 10s of empty space.
-- All viewport state is in absolute TC space — the same coordinate system
-- as clip start_value, so no translation needed.
local function compute_viewport(timeline_data, fps_num, fps_den, start_timecode_frame,
                                min_start_frame, max_end_frame)
    local src_scale = timeline_data.ui_scale
    local src_playhead_rel = timeline_data.cur_playhead_relative

    if src_scale and src_scale > 0 then
        local ESTIMATED_PANEL_WIDTH = 1200
        local view_duration = math.floor(ESTIMATED_PANEL_WIDTH / src_scale)
        local playhead_frame = M._compute_playhead_frame({
            start_timecode_frame = start_timecode_frame,
            src_scale            = src_scale,
            src_playhead_rel     = src_playhead_rel,
        })
        local view_start = M._compute_view_start_frame({
            start_timecode_frame = start_timecode_frame,
            src_scale            = src_scale,
            playhead_frame       = playhead_frame,
            view_duration        = view_duration,
        })
        log.event("Viewport from source: scale=%.4f → dur=%d, playhead=%d (rel=%s)",
            src_scale, view_duration, playhead_frame, tostring(src_playhead_rel))
        return view_start, view_duration, playhead_frame
    end

    -- Clamp view_start at start_timecode_frame so the viewport never sits
    -- in pre-sequence space.
    local abs_view_start = min_start_frame or start_timecode_frame
    local content_duration = max_end_frame - abs_view_start
    local view_duration
    if content_duration > 0 then
        local ui_constants = require("core.ui_constants")
        local fit_start, fit_dur = ui_constants.compute_zoom_to_fit(abs_view_start, max_end_frame)
        abs_view_start = math.max(start_timecode_frame, fit_start)
        view_duration = fit_dur
    else
        local effective_fps = fps_num / fps_den
        view_duration = math.floor(10 * effective_fps)
    end
    local view_start = math.max(start_timecode_frame, abs_view_start)
    local playhead_frame = M._compute_playhead_frame({
        start_timecode_frame = start_timecode_frame,
        min_start_frame      = min_start_frame,
    })
    return view_start, view_duration, playhead_frame
end

-- Resolve the sequence's pixel dimensions: source-format value when valid,
-- project default otherwise. Both are passed by the caller; we fall back
-- to project defaults only when the source carries no usable size.
local function resolve_sequence_dimensions(timeline_data, project_settings)
    local seq_width = (timeline_data.width and timeline_data.width > 0)
        and timeline_data.width or project_settings.width
    local seq_height = (timeline_data.height and timeline_data.height > 0)
        and timeline_data.height or project_settings.height
    return seq_width, seq_height
end

-- Resolve the sequence's audio_sample_rate. Order: project_settings →
-- timeline_data. Both nil = abort with an actionable message (rule 2.13:
-- no silent default to 48000).
local function resolve_sequence_audio_rate(timeline_data, project_settings)
    local rate = (project_settings and project_settings.audio_sample_rate)
        or timeline_data.audio_sample_rate
    assert(rate and rate > 0, string.format(
        "importer_core: audio_sample_rate required for timeline '%s' "
        .. "(rule 2.13 — no silent default; got project_settings.audio_sample_rate=%s, "
        .. "timeline_data.audio_sample_rate=%s)",
        tostring(timeline_data.name),
        tostring(project_settings and project_settings.audio_sample_rate),
        tostring(timeline_data.audio_sample_rate)))
    return rate
end

-- Create one V/A track on the imported sequence, save it, and register
-- its id on the result. Returns the saved Track instance.
local function create_imported_track(sequence, timeline_data, track_data, result)
    local track_prefix = track_data.type == "VIDEO" and "V" or "A"
    local track_name   = string.format("%s%d", track_prefix, track_data.index)
    local track
    if track_data.type == "VIDEO" then
        track = Track.create_video(track_name, sequence.id, { index = track_data.index })
    else
        track = Track.create_audio(track_name, sequence.id, { index = track_data.index })
    end
    assert(track:save(), string.format(
        "importer_core: failed to save track '%s' in timeline '%s'",
        track_name, timeline_data.name))
    table.insert(result.track_ids, track.id)
    return track
end

-- Look up the media record for an imported clip. Prefer file_uuid; fall
-- back to file_path. Returns nil when neither resolves (caller logs +
-- skips).
local function lookup_clip_media(clip_data, media_by_uuid, media_by_path)
    if clip_data.file_uuid and media_by_uuid[clip_data.file_uuid] then
        return media_by_uuid[clip_data.file_uuid]
    end
    if clip_data.file_path and media_by_path[clip_data.file_path] then
        return media_by_path[clip_data.file_path]
    end
    return nil
end

-- Resolve the (source_in, source_out) the imported clip will land with.
-- Returns nil when the parser produced a zero-width range that we should
-- skip (caller logs). Reverse clips (negative speed) keep source_out <
-- source_in by design.
local function resolve_clip_source_range(clip_data)
    local source_out  = clip_data.source_out
    local is_reverse  = (clip_data.clip_speed or 1) < 0

    if not is_reverse then
        if not source_out or source_out <= clip_data.source_in then
            source_out = clip_data.source_in + clip_data.duration
        end
        if source_out <= clip_data.source_in then
            return nil
        end
    else
        if not source_out then
            source_out = clip_data.source_in - clip_data.duration
        end
        if source_out == clip_data.source_in then
            return nil
        end
    end
    return clip_data.source_in, source_out
end

-- 018 (FR-022 / FR-008): convert an audio clip's file-natural sample
-- position to the (frame, subframe) representation in the master sequence's
-- timebase + project master_clock_hz tick space. Composes subframe_math
-- primitives — pure numerics, no DB coupling. Every invalid input asserts
-- (delegated to subframe_math which names the offending parameter).
--
--   samples         : file-natural sample position (>= 0 integer)
--   file_rate       : audio file's native sample rate (Hz, > 0 integer)
--   master_fps_num  : master sequence fps numerator (> 0 integer)
--   master_fps_den  : master sequence fps denominator (> 0 integer)
--   master_clock_hz : project master clock rate (Hz, > 0 integer)
--
-- Returns (frame, subframe) canonical: 0 <= subframe < ticks_per_frame.
function M.compute_audio_clip_source(samples, file_rate,
                                     master_fps_num, master_fps_den,
                                     master_clock_hz)
    local total_ticks = subframe_math.samples_to_ticks(
        samples, file_rate, master_clock_hz)
    local tpf = subframe_math.ticks_per_frame(
        master_clock_hz, master_fps_num, master_fps_den)
    return subframe_math.unpack(total_ticks, tpf)
end

-- Resolve AUDIO_SOURCE_CUSTOM pool IDs → DB media IDs; returns video_media_id → [audio_media_id, ...].
local function build_synced_audio_map(media_items, media_by_uuid)
    local map = {}
    for _, media_item in pairs(media_items) do
        if not (media_item.synced_audio_pool_ids
                and #media_item.synced_audio_pool_ids > 0) then
            goto continue_item
        end
        local video_media = media_item.file_uuid
            and media_by_uuid[media_item.file_uuid]
        if not video_media then goto continue_item end

        local audio_ids = {}
        for _, pool_id in ipairs(media_item.synced_audio_pool_ids) do
            local audio_media = media_by_uuid[pool_id]
            if audio_media then
                audio_ids[#audio_ids + 1] = audio_media.id
            else
                log.warn("importer_core: synced audio pool_id %s not in "
                    .. "media_by_uuid (video media_id=%s)",
                    tostring(pool_id), video_media.id)
            end
        end
        if #audio_ids > 0 then
            map[video_media.id] = audio_ids
        end
        ::continue_item::
    end
    return map
end

-- Resolve the bin a master sequence belongs in. Try, in order: pool-by-uuid
-- → pool-by-name (via media_by_uuid/path lookup) → pool-by-basename →
-- "Unorganized" fallback. Returns the bin id (always non-nil when an
-- "Unorganized" bin exists).
local function resolve_master_bin(clip_data, media_by_uuid, media_by_path,
                                  pool_uuid_to_bin, pool_name_to_bin,
                                  unorganized_bin_id)
    if clip_data.file_uuid and clip_data.file_uuid ~= "" then
        local bin = pool_uuid_to_bin[clip_data.file_uuid]
        if bin then return bin end
    end
    local media = nil
    if clip_data.file_uuid and clip_data.file_uuid ~= "" then
        media = media_by_uuid[clip_data.file_uuid]
    end
    if not media and clip_data.file_path and clip_data.file_path ~= "" then
        media = media_by_path[clip_data.file_path]
    end
    if media then
        local bin = pool_name_to_bin[media.name]
        if bin then return bin end
    end
    if clip_data.file_path then
        local basename = clip_data.file_path:match("([^/\\]+)$")
        local bin = basename and pool_name_to_bin[basename]
        if bin then return bin end
    end
    return unorganized_bin_id
end

-- Create (idempotently) the master sequence for `media_id`, track it once for
-- undo, and file it into the bin resolved for `bin_clip` (anything carrying
-- file_uuid + file_path — a clip_data struct or a synthesized {file_uuid,
-- file_path}; resolve_master_bin reads only those two). `ctx` bundles the
-- per-import state (created_master_set, result, the media + pool-bin lookups,
-- unorganized_bin_id, tag_service). ensure_master and add_to_bin are both
-- idempotent, so calling this for a media that already has a master + bin is a
-- no-op. Returns the master sequence id. Used by both the eager full-pool pass
-- and the per-timeline-clip pass.
local function ensure_master_and_bin(media_id, project_id, synced_audio, bin_clip, ctx)
    -- One master per media_id. Sequence.ensure_master is idempotent but its
    -- existence check is a 3-table JOIN; the per-clip pass would re-run it for
    -- every clip of an already-built master (the eager full-pool pass builds
    -- most masters up front), an O(clips) redundancy that dominated import CPU.
    -- Cache the media_id → master_seq_id resolution for this import.
    local master_seq_id = ctx.master_by_media_id[media_id]
    if not master_seq_id then
        local master_opts = { sample_rate = ctx.default_audio_sample_rate }
        if synced_audio then master_opts.synced_audio_media_ids = synced_audio end
        master_seq_id = Sequence.ensure_master(media_id, project_id, master_opts)
        ctx.master_by_media_id[media_id] = master_seq_id
    end
    if not ctx.created_master_set[master_seq_id] then
        ctx.created_master_set[master_seq_id] = true
        table.insert(ctx.result.sequence_ids, master_seq_id)
    end
    local bin = resolve_master_bin(bin_clip, ctx.media_by_uuid, ctx.media_by_path,
        ctx.pool_uuid_to_bin, ctx.pool_name_to_bin, ctx.unorganized_bin_id)
    if bin then
        ctx.tag_service.add_to_bin(project_id, {master_seq_id}, bin, "master_clip")
    end
    return master_seq_id
end

-- Build and persist a kind='sequence' sequence row for one parsed timeline.
-- Asserts the save (rule 2.13). Returns the saved Sequence instance.
local function create_imported_sequence(project_id, timeline_data, fps_num, fps_den,
                                        seq_width, seq_height, seq_audio_rate,
                                        start_timecode_frame, view_start, view_duration,
                                        playhead_frame)
    local sequence = Sequence.create(
        timeline_data.name,
        project_id,
        { fps_numerator = fps_num, fps_denominator = fps_den },
        seq_width,
        seq_height,
        {
            kind                 = "sequence",
            audio_sample_rate    = seq_audio_rate,
            start_timecode_frame = start_timecode_frame,
            view_start_frame     = view_start,
            view_duration_frames = view_duration,
            playhead_frame       = playhead_frame,
        })
    assert(sequence:save(), string.format(
        "importer_core: failed to save timeline '%s'", timeline_data.name))
    return sequence
end

-- Import one parsed media item into the project. Returns the imported
-- Media row, or nil when the item is filtered (zero-duration, proxy-only,
-- missing fps) or deduped to an existing row.
local function try_import_media_item(media_item, project_id, project_settings,
                                     media_by_uuid, media_by_path)
    if (media_item.duration or 0) <= 0 then
        log.warn("Skipping zero-duration media: %s", media_item.name)
        return nil
    end

    local action, path_or_reason = resolve_proxy_path(media_item)
    if action == "skip" then
        log.event("Skipping proxy-only media: %s (%s)", media_item.name, path_or_reason)
        return nil
    end
    if path_or_reason ~= media_item.file_path then
        media_item.file_path = path_or_reason
        log.event("Proxy media '%s' — using original path: %s", media_item.name, path_or_reason)
    end

    local fps = media_item.frame_rate
    if not fps then
        log.warn("Skipping media without frame_rate: %s (path=%s, uuid=%s)",
            media_item.name, tostring(media_item.file_path), tostring(media_item.file_uuid))
        return nil
    end

    local existing = media_item.file_path and find_dedup_match(media_by_path, media_item)
    if existing then
        -- Dedup onto an already-imported entry: still key this item's pool ids
        -- (file_uuid + alt_uuids) onto it, exactly as register_media_row would
        -- for a fresh entry — otherwise a synced WAV that dedups loses the
        -- aliases its sync linkage resolves by.
        register_media_aliases(existing, media_item, media_by_uuid)
        return nil
    end

    local native_rate = math.floor(fps + 0.5)
    local media_metadata = build_media_metadata(media_item, native_rate)

    -- Track type determines video presence: width/height 0 prevents
    -- ensure_masterclip from creating a video track.
    local media_width  = media_item.has_video and project_settings.width  or 0
    local media_height = media_item.has_video and project_settings.height or 0
    local media_codec  = media_item.codec

    -- media.id IS the source format's stable per-file identifier (DRP
    -- MediaRef DbId, FCP7 file id, etc) when one is present. Fresh-uuid
    -- fallback only when the parser couldn't extract one. Stable ids
    -- across re-imports keep per-media-id caches (peak files, future
    -- content caches) intact instead of orphaning them every time the
    -- DRP is re-converted into the same destination.
    local stable_id = media_item.file_uuid
    if stable_id == "" then stable_id = nil end

    local media = Media.create({
        id                = stable_id,
        project_id        = project_id,
        name              = media_item.name,
        file_path         = media_item.file_path,
        file_uuid         = media_item.file_uuid,
        duration_frames   = media_item.duration,
        frame_rate        = fps,
        audio_sample_rate = media_item.audio_sample_rate,
        audio_channels    = media_item.audio_channels,
        width             = media_width,
        height            = media_height,
        codec             = media_codec,
        is_still          = Media.classify_is_still(media_codec, media_width, media_item.duration),
        metadata          = media_metadata,
    })
    assert(media:save(), string.format(
        "importer_core: failed to save media '%s' (path=%s)",
        media_item.name, media_item.file_path))

    register_media_row(media, media_item, media_by_uuid, media_by_path)
    log.event("  Imported media: %s", media.name)
    return media
end

--- Import parsed data into an existing project.
-- Creates: media records, sequences, tracks, clips, A/V link groups, bins.
-- @param project_id string: Target project ID (must already exist)
-- @param parse_result table: Output of any format parser (drp, prproj, fcp7)
-- @param opts table: Optional settings
--   opts.project_settings table: {frame_rate, width, height} project defaults
--   opts.progress_cb function: optional progress(pct, text)
-- @return table: {media_ids, sequence_ids, track_ids, clip_ids, media_by_uuid, media_by_path}
function M.import_into_project(project_id, parse_result, opts)
    assert(project_id and project_id ~= "", "importer_core.import_into_project: project_id required")
    assert(parse_result and parse_result.success, "importer_core.import_into_project: parse_result must be successful")
    opts = opts or {}
    local project_settings = opts.project_settings or parse_result.project.settings
    local sub_report = opts.progress_cb or function() end

    -- 018 (FR-028): project_settings.master_clock_hz drives every per-clip
    -- audio sample → (frame, subframe) conversion below. Asserted once here
    -- so we fail loud at the entry of the import rather than per-clip
    -- (rule 1.14). DRP / prproj importers populate this at parse time.
    local master_clock_hz = project_settings and project_settings.master_clock_hz
    assert(master_clock_hz and master_clock_hz > 0, string.format(
        "importer_core.import_into_project: project_settings.master_clock_hz "
        .. "required (FR-028); got %s. The format-specific parser must populate "
        .. "this in parse_result.project.settings before calling import_into_project.",
        tostring(master_clock_hz)))

    local tag_service = require("core.tag_service")
    local uuid = require("uuid")

    -- Track created entity IDs for undo
    local result = {
        media_ids = {},
        sequence_ids = {},
        track_ids = {},
        clip_ids = {},
        -- Maps the source format's per-timeline UUID (e.g. DRP Sm2Sequence.DbId)
        -- to the newly-created JVE Sequence.id. Populated when timeline_data
        -- carries a tab_uuid — used to restore open tabs post-import.
        tab_uuid_to_sequence_id = {},
        -- Maps imported timeline NAME to its new JVE Sequence.id. Used by
        -- importers that key tabs by name instead of UUID (prproj — Premiere
        -- doesn't expose a per-tab UUID in the open-tab list, only names).
        name_to_sequence_id = {},
    }
    -- Dedup set for master sequences captured directly from ensure_master
    -- returns. Masters whose media_refs haven't been populated yet won't
    -- appear in a find_master_for_media JOIN, so we capture them here.
    local created_master_set = {}

    local folders = sort_folders_parent_first(parse_result.folders or {})
    local folder_to_bin = import_folders_as_bins(project_id, folders, tag_service, uuid)
    local pool_uuid_to_bin, pool_name_to_bin = build_pool_clip_mappings(
        parse_result.pool_master_clips or {}, folder_to_bin)
    local unorganized_bin_id = ensure_unorganized_bin(project_id, tag_service, uuid)

    -- Import media items. Each row is keyed by file_uuid (when supplied)
    -- and by file_path (incl. alt paths). See try_import_media_item /
    -- find_dedup_match for the (path, media_start_time) dedup contract.
    local media_by_uuid = {}
    local media_by_path = {}
    local imported_media = {}
    for _, media_item in pairs(parse_result.media_items) do
        local media = try_import_media_item(media_item, project_id, project_settings,
                                            media_by_uuid, media_by_path)
        if media then
            table.insert(result.media_ids, media.id)
            table.insert(imported_media, media)
        end
    end

    local synced_audio_by_media_id =
        build_synced_audio_map(parse_result.media_items, media_by_uuid)

    -- Shared state for ensure_master_and_bin, used by both the eager full-pool
    -- pass and the per-timeline-clip pass below.
    local master_ctx = {
        created_master_set = created_master_set,
        master_by_media_id = {},
        master_seq_by_id   = {},
        -- Project default audio rate: the fallback ensure_master uses for
        -- OFFLINE media whose project file gave audio_channels but no rate of
        -- its own (the file isn't probed — importers must not probe). A media's
        -- own recorded rate always wins; this only fills the gap. nil is fine —
        -- the factory asserts loud if an audio media has neither.
        default_audio_sample_rate = project_settings.audio_sample_rate,
        result             = result,
        media_by_uuid      = media_by_uuid,
        media_by_path      = media_by_path,
        pool_uuid_to_bin   = pool_uuid_to_bin,
        pool_name_to_bin   = pool_name_to_bin,
        unorganized_bin_id = unorganized_bin_id,
        tag_service        = tag_service,
    }

    -- Full-pool import: give EVERY imported media item a master source
    -- sequence, not just the media placed on a timeline. A clip filed in a bin
    -- but never cut into the edit must still be browseable in the media pool
    -- and openable in the source viewer — both require a kind='master'
    -- sequence. The per-timeline clip loop below calls ensure_master_and_bin
    -- too, but it is idempotent, so those calls are no-ops for media handled here.
    sub_report(18, "Building source clips…")
    for _, media in ipairs(imported_media) do
        -- A master needs a known TC origin per present stream, and importers
        -- must not probe the file to get one. Pool clips whose project file
        -- carried no TC (encrypted / undecodable blob) import as relinkable
        -- media rows now and gain a master when the media is relinked or
        -- probed — "import everything we can" rather than asserting and
        -- aborting the whole import on one TC-less clip.
        if media:has_master_source_tc() then
            ensure_master_and_bin(media.id, project_id,
                synced_audio_by_media_id[media.id],
                { file_uuid = media.id, file_path = media.file_path }, master_ctx)
        else
            log.warn("import: pool media '%s' (%s) has no source timecode in the "
                .. "project file — imported as a relinkable clip; its master "
                .. "source sequence builds on relink/probe", media.name, media.id)
        end
    end

    sub_report(20, "Importing timelines…")

    -- Import timelines
    local timeline_count = #parse_result.timelines
    for tl_idx, timeline_data in ipairs(parse_result.timelines) do
        sub_report(20 + math.floor(tl_idx / timeline_count * 70),
            string.format("Importing: %s", timeline_data.name))

        local min_start_frame, max_end_frame =
            compute_clip_position_extents(timeline_data)
        local fps_num, fps_den =
            resolve_timeline_frame_rate(timeline_data, min_start_frame, project_settings)
        local start_timecode_frame =
            compute_sequence_start_tc(timeline_data, fps_num, fps_den)
        local view_start, view_duration, playhead_frame =
            compute_viewport(timeline_data, fps_num, fps_den, start_timecode_frame,
                             min_start_frame, max_end_frame)

        -- 013: edit timelines created by import are kind='sequence' (they
        -- hold clips referencing master sequences). Master sequences for
        -- source media are created separately via Sequence.ensure_master.
        local seq_width, seq_height = resolve_sequence_dimensions(timeline_data, project_settings)
        local seq_audio_rate        = resolve_sequence_audio_rate(timeline_data, project_settings)
        local sequence = create_imported_sequence(project_id, timeline_data,
            fps_num, fps_den, seq_width, seq_height, seq_audio_rate,
            start_timecode_frame, view_start, view_duration, playhead_frame)
        do
            table.insert(result.sequence_ids, sequence.id)
            if timeline_data.tab_uuid and timeline_data.tab_uuid ~= "" then
                result.tab_uuid_to_sequence_id[timeline_data.tab_uuid] = sequence.id
            end
            if timeline_data.name and timeline_data.name ~= "" then
                result.name_to_sequence_id[timeline_data.name] = sequence.id
            end
            log.event("  Created timeline: %s @ %d/%d fps, %dx%d, viewport [%d..%d]",
                    timeline_data.name, fps_num, fps_den, seq_width, seq_height, view_start, view_start + view_duration)

            -- Assign timeline to folder bin if available
            local timeline_folder_bin = timeline_data.folder_id and folder_to_bin[timeline_data.folder_id] or nil
            if timeline_folder_bin then
                tag_service.add_to_bin(project_id, {sequence.id}, timeline_folder_bin, "sequence")
            end

            local clips_for_linking = {}

            -- STEP 5: Import tracks + clips
            for _, track_data in ipairs(timeline_data.tracks) do
                local track = create_imported_track(sequence, timeline_data, track_data, result)
                for _, clip_data in ipairs(track_data.clips) do
                    local media_record = lookup_clip_media(clip_data, media_by_uuid, media_by_path)
                    local media_id = media_record and media_record.id or nil
                    if not media_id then
                        if not clip_data.file_path or clip_data.file_path == "" then
                            log.detail("Skipping nested/generated clip '%s' (no media path)",
                                clip_data.name or "unnamed")
                        else
                            log.warn("Skipping clip '%s' - no media record for path: %s",
                                clip_data.name or "unnamed", clip_data.file_path)
                        end
                        goto continue_clip
                    end

                    -- Source coords (source_in, source_out) are absolute TC
                    -- in native units, set by the parser (parse_resolve_tracks):
                    -- file_tc_origin + file-relative offset. Frames for video,
                    -- samples for audio. The master sequence's timebase IS TC
                    -- space (its media_refs sit at sequence_start = file_tc_origin),
                    -- so parser values pass through unchanged.
                    assert(clip_data.native_rate, string.format(
                        "import_into_project: clip '%s' missing native_rate (media_id=%s)",
                        clip_data.name or "unnamed", media_id))
                    assert(type(clip_data.source_in) == "number", string.format(
                        "import_into_project: clip '%s' missing source_in (media_id=%s)",
                        clip_data.name or "unnamed", media_id))
                    assert(type(clip_data.duration) == "number", string.format(
                        "import_into_project: clip '%s' missing duration (media_id=%s)",
                        clip_data.name or "unnamed", media_id))

                    local source_in_final, source_out_final = resolve_clip_source_range(clip_data)
                    if not source_in_final then
                        log.warn("Skipping clip '%s' - zero source range (source_in=%s, source_out=%s)",
                            clip_data.name or "unnamed",
                            tostring(clip_data.source_in), tostring(clip_data.source_out))
                        goto continue_clip
                    end

                    -- Master + bin for this clip's media (idempotent: the eager
                    -- full-pool pass above already created most of these).
                    -- clip.sequence_id is this master ref (V13).
                    local master_seq_id = ensure_master_and_bin(media_id, project_id,
                        synced_audio_by_media_id[media_id], clip_data, master_ctx)

                    local now = os.time()
                    -- 018 (FR-001 / FR-008 / FR-022): clip.source_in_frame /
                    -- source_out_frame are uniformly in the master sequence's
                    -- fps timebase across both mediums. Audio sub-sample
                    -- residual lives in source_*_subframe (master_clock_hz
                    -- ticks). The parser delivers source_in/out in
                    -- file-natural units (samples for audio, frames for
                    -- video); the audio path converts here. FR-013 requires
                    -- subframe NULL on video, non-NULL on audio.
                    local src_in_frame, sub_in
                    local src_out_frame, sub_out
                    if track.track_type == "AUDIO" then
                        -- The audio path reads only the master's fps timebase;
                        -- masters are few but audio clips are many, so cache the
                        -- loaded master per id rather than re-loading per clip.
                        local master_seq = master_ctx.master_seq_by_id[master_seq_id]
                        if not master_seq then
                            master_seq = Sequence.find(master_seq_id)
                            assert(master_seq, string.format(
                                "importer_core: master %s not loadable after ensure_master",
                                tostring(master_seq_id)))
                            master_ctx.master_seq_by_id[master_seq_id] = master_seq
                        end
                        src_in_frame, sub_in = M.compute_audio_clip_source(
                            source_in_final, clip_data.native_rate,
                            master_seq.fps_numerator, master_seq.fps_denominator,
                            master_clock_hz)
                        src_out_frame, sub_out = M.compute_audio_clip_source(
                            source_out_final, clip_data.native_rate,
                            master_seq.fps_numerator, master_seq.fps_denominator,
                            master_clock_hz)
                    else
                        -- VIDEO: source_in/out from parser are already in
                        -- master.fps frames; subframe NULL on video (FR-013).
                        local defaults_in, defaults_out =
                            Clip.subframe_defaults_for_track_type(track.track_type)
                        src_in_frame, sub_in   = source_in_final,  defaults_in
                        src_out_frame, sub_out = source_out_final, defaults_out
                    end
                    local clip_id = Clip.create({
                        -- Spec 023 FR-011b: adopt the Resolve Sm2Ti DbId as
                        -- clip.id. Rule 2.13: no silent minting. Real Resolve
                        -- exports always carry one.
                        id                    = assert(clip_data.clip_id, "importer_core: clip missing id"),
                        project_id            = project_id,
                        owner_sequence_id     = sequence.id,
                        track_id              = track.id,
                        sequence_id    = master_seq_id,
                        name                  = clip_data.name or "Untitled Clip",
                        sequence_start_frame  = clip_data.start_value,
                        duration_frames       = clip_data.duration,
                        source_in_frame       = src_in_frame,
                        source_out_frame      = src_out_frame,
                        source_in_subframe    = sub_in,
                        source_out_subframe   = sub_out,
                        master_layer_track_id = nil,
                        master_audio_track_id = nil,
                        fps_mismatch_policy   = "resample",
                        enabled               = (clip_data.enabled ~= false),
                        volume                = clip_data.volume or 1.0,
                        playhead_frame        = 0,
                        created_at            = now,
                        modified_at           = now,
                    })
                    assert(clip_id and clip_id ~= "", string.format(
                        "importer_core: failed to create clip '%s' in track '%s'",
                        clip_data.name, track_data.type .. tostring(track_data.index)))
                    table.insert(result.clip_ids, clip_id)

                    -- 023: persist the clip's markers (decoded from the DRP
                    -- Sm2TiItemLockableBlob, attached to clip_data by the parser
                    -- and keyed by the clip's own Sm2Ti DbId). The DRP defines
                    -- the canonical marker set for this clip: clear first so
                    -- re-import is idempotent (the per-marker UUID would
                    -- otherwise mint fresh ids each parse and accumulate dups).
                    if clip_data.markers then
                        ClipMarker.delete_for_clip(clip_id)
                        for _, mk in ipairs(clip_data.markers) do
                            ClipMarker.new({
                                clip_id     = clip_id,
                                frame       = mk.frame,
                                duration    = mk.duration,
                                color       = mk.color,
                                name        = mk.name,
                                note        = mk.note,
                                custom_data = mk.custom_data,
                            }):save()
                        end
                    end

                    -- Persist substitution history (OriginalClip) when the
                    -- source format carried one. Rare (replace/relink events
                    -- only) and archival, so it lives in properties rather
                    -- than its own column.
                    if clip_data.original_clip then
                        Property.save_for_clip(clip_id, {{
                            property_name  = "original_clip",
                            property_value = clip_data.original_clip,
                            property_type  = "json",
                        }})
                    end

                    -- V↔A linkage is driven entirely by an explicit pair
                    -- key the parser surfaces on clip_data.linked_item_sync.
                    -- The value is opaque here — equality alone is what
                    -- groups clips. nil means the source format declared
                    -- the clip unlinked (or doesn't yet emit a key); such
                    -- clips never join a group. Linkage is never inferred
                    -- from media identity, timeline position, or name
                    -- coincidence — the source format is authoritative.
                    if clip_data.linked_item_sync ~= nil then
                        local role
                        if track_data.type == "VIDEO" then
                            role = "video"
                        elseif track_data.type == "AUDIO" then
                            role = "audio"
                        else
                            assert(false, string.format(
                                "import_into_project: clip '%s' on unsupported " ..
                                "track type '%s' surfaced a link key — clip_links " ..
                                "role column accepts only video|audio",
                                tostring(clip_data.name), tostring(track_data.type)))
                        end
                        table.insert(clips_for_linking, {
                            clip_id = clip_id,
                            link_id = clip_data.linked_item_sync,
                            role    = role,
                        })
                    end
                    ::continue_clip::
                end
            end

            -- STEP 6: Pool collected clips into groups by their pair key.
            -- Singleton groups are filtered out below.
            local link_groups_by_key = {}
            for _, clip_info in ipairs(clips_for_linking) do
                local key = tostring(clip_info.link_id)
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
                        log.warn("Failed to create link group: %s", link_err or "unknown error")
                    end
                end
            end

            if link_count > 0 then
                log.event("Created %d A/V link groups for timeline: %s", link_count, timeline_data.name)
            end
        end
    end

    sub_report(90, "Finalizing…")

    log.event("Import complete: %d media, %d sequences, %d tracks, %d clips",
        #result.media_ids, #result.sequence_ids, #result.track_ids, #result.clip_ids)

    -- Sequences (master + timeline) were inserted in bulk above. Emit once
    -- at the end so the project browser rebuilds its tree to include the
    -- new rows. Per-row emits would cause N rebuilds for an N-sequence DRP.
    -- queue_post_commit_emit defers to the surrounding command's commit
    -- when invoked from the Import command; emits immediately for the
    -- Open-path importer pass (no transaction to defer to).
    if #result.sequence_ids > 0 then
        require("core.command_manager").queue_post_commit_emit(
            "sequence_list_changed", project_id)
    end

    -- Return lookup tables for format-specific post-import steps
    result.media_by_uuid = media_by_uuid
    result.media_by_path = media_by_path

    return result
end

return M
