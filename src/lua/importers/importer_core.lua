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
local Property = require("models.property")
local clip_link = require("models.clip_link")

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
-- import_into_project: Format-agnostic entity creation from parse_result
-- ---------------------------------------------------------------------------

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
    }

    -- Import folder hierarchy as bins
    -- Sort by depth (parents before children) so each folder's parent bin
    -- exists when we create it.
    local folders = parse_result.folders or {}
    local folder_lookup = {}
    for _, f in ipairs(folders) do folder_lookup[f.id] = f end

    local function folder_depth(f)
        local d = 0
        local cur = f
        while cur and cur.parent_id do
            d = d + 1
            cur = folder_lookup[cur.parent_id]
        end
        return d
    end
    table.sort(folders, function(a, b) return folder_depth(a) < folder_depth(b) end)

    local folder_to_bin = {}  -- source folder ID → JVE bin_id
    for _, folder in ipairs(folders) do
        local parent_bin_id = folder.parent_id and folder_to_bin[folder.parent_id] or nil
        local bin_id = uuid.generate_with_prefix("bin")
        local ok, def = tag_service.create_bin(project_id, {
            id = bin_id,
            name = folder.name,
            parent_id = parent_bin_id,
        })
        if ok and def then
            folder_to_bin[folder.id] = def.id
        else
            log.warn("Failed to create bin: %s", folder.name)
        end
    end

    -- Build pool master clip → folder bin mappings.
    -- Primary: UUID → bin (reliable). Fallback: name → bin.
    local pool_uuid_to_bin = {}
    local pool_name_to_bin = {}
    for _, pmc in ipairs(parse_result.pool_master_clips or {}) do
        if pmc.folder_id and folder_to_bin[pmc.folder_id] then
            if pmc.id then
                pool_uuid_to_bin[pmc.id] = folder_to_bin[pmc.folder_id]
            end
            pool_name_to_bin[pmc.name] = folder_to_bin[pmc.folder_id]
        end
    end

    -- Create "Unorganized" bin for orphaned media
    local unorganized_bin_id = nil
    do
        local bin_id = uuid.generate_with_prefix("bin")
        local ok, def = tag_service.create_bin(project_id, {
            id = bin_id,
            name = "Unorganized",
        })
        if ok and def then
            unorganized_bin_id = def.id
        end
    end

    -- Import media items (hash table keyed by uuid or path)
    local media_by_uuid = {}  -- file_uuid → Media record
    local media_by_path = {}  -- file_path → Media record
    for _, media_item in pairs(parse_result.media_items) do
        local dur = media_item.duration or 0
        if dur <= 0 then
            log.warn("Skipping zero-duration media: %s", media_item.name)
            goto continue_media
        end

        -- Proxy path — check alt_paths for a non-proxy original
        if media_item.file_path and media_item.file_path:find("/ProxyMedia/") then
            local original_path = nil
            for alt_path in pairs(media_item.alt_paths or {}) do
                if not alt_path:find("/ProxyMedia/") then
                    original_path = alt_path
                    break
                end
            end
            if original_path then
                media_item.file_path = original_path
                log.event("Proxy media '%s' — using original path: %s", media_item.name, original_path)
            else
                log.event("Skipping proxy-only media: %s", media_item.name)
                goto continue_media
            end
        end

        do
            local fps = media_item.frame_rate
            if not fps then
                log.warn("Skipping media without frame_rate: %s (path=%s, uuid=%s)",
                    media_item.name, tostring(media_item.file_path), tostring(media_item.file_uuid))
                goto continue_media
            end

            -- Skip if we already created a record for this (file_path, media_start_time).
            -- Two master clips pointing at the same file but with different Set Timecode
            -- overrides (different media_start_time) produce separate media rows (FR-003a).
            -- Same file + same TC still dedupes to one row (camera footage, unchanged).
            if media_item.file_path and media_by_path[media_item.file_path] then
                local existing = media_by_path[media_item.file_path]
                local existing_mst = existing._media_start_time
                local this_mst = media_item.media_start_time
                local same_tc = (existing_mst == nil or this_mst == nil) or
                    (existing_mst == this_mst) or
                    (math.abs(existing_mst - this_mst) < 0.001)
                if same_tc then
                    if media_item.file_uuid then
                        media_by_uuid[media_item.file_uuid] = existing
                    end
                    goto continue_media
                end
                -- Different TC for same file → fall through to create a second row
            end

            -- Convert media_start_time (seconds since midnight) to native units
            local media_metadata = '{}'
            local native_rate = math.floor(fps + 0.5)
            if media_item.media_start_time then
                local json = require("dkjson")
                local mst = media_item.media_start_time
                local start_tc_value = math.floor(mst * native_rate + 0.5)
                local meta = {
                    start_tc_value = start_tc_value,
                    start_tc_rate = native_rate,
                }

                -- Audio TC fields only when the media actually has audio.
                -- Video-only media (no audio_sample_rate) gets video TC only —
                -- audio TC fields are omitted, not faked.
                local audio_sr = media_item.audio_sample_rate
                if audio_sr and audio_sr > 0 then
                    meta.start_tc_audio_samples = math.floor(mst * audio_sr + 0.5)
                    meta.start_tc_audio_rate = audio_sr
                end

                -- FR-001: Store file_original_timecode when file's container TC
                -- differs from the displayed TC (Set Timecode override detected).
                if media_item.file_tc_seconds then
                    local file_tc_video = math.floor(media_item.file_tc_seconds * native_rate + 0.5)
                    if file_tc_video ~= start_tc_value then
                        meta.file_original_timecode = file_tc_video
                        if audio_sr and audio_sr > 0 then
                            meta.file_original_timecode_audio =
                                math.floor(media_item.file_tc_seconds * audio_sr + 0.5)
                        end
                        log.event("  Set Timecode override: start_tc=%d file_tc=%d (delta=%d frames)",
                            start_tc_value, file_tc_video, start_tc_value - file_tc_video)
                    end
                end
                -- file_tc_seconds nil is normal: encrypted blobs, stock footage without
                -- decodable TracksBA, unmatched PMC enrichment. No override detection for
                -- this row — pre-feature behavior (file_original_timecode absent).

                media_metadata = json.encode(meta)
            end

            -- Track type determines video presence:
            -- width/height 0 prevents ensure_masterclip from creating a video track.
            local media_width = media_item.has_video and project_settings.width or 0
            local media_height = media_item.has_video and project_settings.height or 0

            local media_codec = media_item.codec
            local media = Media.create({
                project_id = project_id,
                name = media_item.name,
                file_path = media_item.file_path,
                file_uuid = media_item.file_uuid,
                duration_frames = dur,
                frame_rate = fps,
                audio_sample_rate = media_item.audio_sample_rate,
                audio_channels = media_item.audio_channels,
                width = media_width,
                height = media_height,
                codec = media_codec,
                is_still = Media.classify_is_still(media_codec, media_width, dur),
                metadata = media_metadata,
            })

            assert(media:save(), string.format(
                "importer_core: failed to save media '%s' (path=%s)",
                media_item.name, media_item.file_path))

            -- Stash media_start_time for dedup comparison (same file, different TC → separate rows)
            media._media_start_time = media_item.media_start_time

            if media_item.file_uuid then
                media_by_uuid[media_item.file_uuid] = media
            end
            media_by_path[media_item.file_path] = media
            for alt in pairs(media_item.alt_paths or {}) do
                media_by_path[alt] = media
            end

            table.insert(result.media_ids, media.id)
            log.event("  Imported media: %s", media.name)
        end
        ::continue_media::
    end

    sub_report(20, "Importing timelines…")

    -- Import timelines
    local timeline_count = #parse_result.timelines
    for tl_idx, timeline_data in ipairs(parse_result.timelines) do
        sub_report(20 + math.floor(tl_idx / timeline_count * 70),
            string.format("Importing: %s", timeline_data.name))
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
            fps_num, fps_den = M.frame_rate_to_rational(timeline_data.fps)
            log.event("Using explicit fps from metadata: %.3f (%d/%d)",
                    timeline_data.fps, fps_num, fps_den)
        else
            local inferred_fps, inferred_num, inferred_den = M.infer_fps_from_one_hour_start(min_start_frame)

            if inferred_fps then
                fps_num, fps_den = inferred_num, inferred_den
                log.event("Inferred fps from 1-hour TC: %.3f (%d/%d)",
                        inferred_fps, fps_num, fps_den)
            else
                fps_num, fps_den = M.frame_rate_to_rational(project_settings.frame_rate)
                log.warn("No fps metadata, no 1-hour TC; using project default: %d/%d",
                        fps_num, fps_den)
            end
        end

        -- STEP 2b: Timeline start timecode
        local start_timecode_frame = 0
        if timeline_data.start_tc_seconds and timeline_data.start_tc_seconds > 0 then
            local effective_fps = fps_num / fps_den
            start_timecode_frame = math.floor(timeline_data.start_tc_seconds * effective_fps + 0.5)
            log.event("Timeline start TC: %.2fs → %d frames (%d/%d fps)",
                timeline_data.start_tc_seconds, start_timecode_frame, fps_num, fps_den)
        end

        -- STEP 3: Viewport from source UI state, or zoom-to-fit fallback
        local view_start, view_duration
        local playhead_frame

        local src_scale = timeline_data.ui_scale
        local src_playhead_rel = timeline_data.cur_playhead_relative

        if src_scale and src_scale > 0 then
            local ESTIMATED_PANEL_WIDTH = 1200
            view_duration = math.floor(ESTIMATED_PANEL_WIDTH / src_scale)

            playhead_frame = start_timecode_frame + (src_playhead_rel or 0)

            view_start = math.max(start_timecode_frame,
                playhead_frame - math.floor(view_duration / 2))

            log.event("Viewport from source: scale=%.4f → dur=%d, playhead=%d (rel=%s)",
                src_scale, view_duration, playhead_frame, tostring(src_playhead_rel))
        else
            view_start = min_start_frame or start_timecode_frame
            local content_duration = max_end_frame - view_start

            if content_duration > 0 then
                local ui_constants = require("core.ui_constants")
                local fit_start, fit_dur = ui_constants.compute_zoom_to_fit(view_start, max_end_frame)
                view_start = math.max(start_timecode_frame, fit_start)
                view_duration = fit_dur
            else
                local effective_fps = fps_num / fps_den
                view_duration = math.floor(10 * effective_fps)
            end

            playhead_frame = min_start_frame or start_timecode_frame
        end

        -- STEP 4: Create Sequence
        local seq_width = (timeline_data.width and timeline_data.width > 0)
            and timeline_data.width or project_settings.width
        local seq_height = (timeline_data.height and timeline_data.height > 0)
            and timeline_data.height or project_settings.height

        -- 013: edit timelines created by import are kind='nested'
        -- (they hold clips referencing master sequences). Master sequences
        -- for source media are created separately via Sequence.ensure_master.
        local seq_audio_rate = (project_settings and project_settings.audio_rate)
            or (timeline_data.audio_rate)
        assert(seq_audio_rate and seq_audio_rate > 0, string.format(
            "importer_core: audio_rate required for timeline '%s' "
            .. "(rule 2.13 — no silent default; got project_settings.audio_rate=%s, "
            .. "timeline_data.audio_rate=%s)",
            tostring(timeline_data.name),
            tostring(project_settings and project_settings.audio_rate),
            tostring(timeline_data.audio_rate)))

        local sequence = Sequence.create(
            timeline_data.name,
            project_id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            seq_width,
            seq_height,
            {
                kind = "nested",
                audio_rate = seq_audio_rate,
                start_timecode_frame = start_timecode_frame,
                view_start_frame = view_start,
                view_duration_frames = view_duration,
                playhead_frame = playhead_frame,
            }
        )

        assert(sequence:save(), string.format(
            "importer_core: failed to save timeline '%s'", timeline_data.name))
        do
            table.insert(result.sequence_ids, sequence.id)
            if timeline_data.tab_uuid and timeline_data.tab_uuid ~= "" then
                result.tab_uuid_to_sequence_id[timeline_data.tab_uuid] = sequence.id
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
                local track_prefix = track_data.type == "VIDEO" and "V" or "A"
                local track_name = string.format("%s%d", track_prefix, track_data.index)

                local track
                if track_data.type == "VIDEO" then
                    track = Track.create_video(track_name, sequence.id, { index = track_data.index })
                else
                    track = Track.create_audio(track_name, sequence.id, { index = track_data.index })
                end

                assert(track:save(), string.format(
                    "importer_core: failed to save track '%s' in timeline '%s'",
                    track_name, timeline_data.name))
                do
                    table.insert(result.track_ids, track.id)

                    for _, clip_data in ipairs(track_data.clips) do
                        -- Prefer UUID lookup, fall back to path. Hold the
                        -- whole record so we can read media duration without
                        -- a round-trip through the DB (and without the
                        -- file-system-touching `Media:get_start_tc()` path).
                        local media_record
                        if clip_data.file_uuid and media_by_uuid[clip_data.file_uuid] then
                            media_record = media_by_uuid[clip_data.file_uuid]
                        elseif clip_data.file_path and media_by_path[clip_data.file_path] then
                            media_record = media_by_path[clip_data.file_path]
                        end
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

                        -- Clip rate = media's native rate. Source coordinates
                        -- (source_in, source_out) are absolute TC in native
                        -- units, set by the parser (parse_resolve_tracks):
                        -- file_tc_origin + file-relative offset. Frames for
                        -- video, samples for audio. The master sequence's
                        -- timebase IS TC space (its media_refs sit at
                        -- timeline_start = file_tc_origin), so parser values
                        -- pass through unchanged.
                        assert(clip_data.native_rate, string.format(
                            "import_into_project: clip '%s' missing native_rate (media_id=%s)",
                            clip_data.name or "unnamed", media_id))
                        assert(type(clip_data.source_in) == "number", string.format(
                            "import_into_project: clip '%s' missing source_in (media_id=%s)",
                            clip_data.name or "unnamed", media_id))
                        assert(type(clip_data.duration) == "number", string.format(
                            "import_into_project: clip '%s' missing duration (media_id=%s)",
                            clip_data.name or "unnamed", media_id))
                        local clip_rate_num = clip_data.native_rate
                        local clip_rate_den = 1

                        local source_out = clip_data.source_out
                        local is_reverse = (clip_data.clip_speed or 1) < 0

                        if not is_reverse then
                            if not source_out or source_out <= clip_data.source_in then
                                source_out = clip_data.source_in + clip_data.duration
                            end
                            if source_out <= clip_data.source_in then
                                log.warn("Skipping clip '%s' - zero source range (source_in=%s, source_out=%s)",
                                    clip_data.name or "unnamed", tostring(clip_data.source_in), tostring(source_out))
                                goto continue_clip
                            end
                        else
                            if not source_out then
                                source_out = clip_data.source_in - clip_data.duration
                            end
                            if source_out == clip_data.source_in then
                                log.warn("Skipping reverse clip '%s' - zero source range (source_in=%s, source_out=%s)",
                                    clip_data.name or "unnamed", tostring(clip_data.source_in), tostring(source_out))
                                goto continue_clip
                            end
                        end

                        -- V13: master sequence is the link from clip → media.
                        local master_seq_id = Sequence.ensure_master(media_id, project_id)

                        -- Reconcile the parser's source range against the
                        -- media row's actual extent. The model: source_in =
                        -- tc_origin + zero-based file index, where the index
                        -- lives in [0, file_duration). For stills (a single
                        -- file frame) the index is always 0, regardless of
                        -- what Resolve put in <In> — Resolve sometimes writes
                        -- the timeline TC into <In> for stills, which the
                        -- parser propagates verbatim; the file's true span
                        -- wins.
                        local Media = require("models.media")
                        local media_row = Media.load(media_id)
                        assert(media_row, string.format(
                            "importer_core: media %s missing while creating clip '%s'",
                            tostring(media_id), tostring(clip_data.name)))
                        -- Media.load hydrates the duration_frames column as
                        -- the .duration field on the instance.
                        local fdur = media_row.duration
                        assert(type(fdur) == "number" and fdur > 0, string.format(
                            "importer_core: media %s ('%s') has duration=%s — "
                            .. "the dur<=0 skip in import_into_project should have prevented this",
                            tostring(media_id), tostring(media_row.name), tostring(fdur)))
                        local source_in_final = clip_data.source_in
                        local source_out_final = source_out
                        if track_data.type == "AUDIO" then
                            local atc = media_row:get_audio_start_tc() or 0
                            -- Audio clip bounds are in samples; media.duration
                            -- is in video frames. Convert to samples via the
                            -- media's audio_sample_rate and fps ratio.
                            local sr = media_row.audio_sample_rate
                            local fps_num = media_row.frame_rate.fps_numerator
                            local fps_den = media_row.frame_rate.fps_denominator
                            assert(sr and sr > 0 and fps_num and fps_den, string.format(
                                "importer_core: media %s audio metadata incomplete "
                                .. "(sample_rate=%s, fps=%s/%s) for clip '%s'",
                                tostring(media_id), tostring(sr),
                                tostring(fps_num), tostring(fps_den),
                                tostring(clip_data.name)))
                            local dur_samples = math.floor(
                                fdur * sr * fps_den / fps_num + 0.5)
                            local extent = atc + dur_samples
                            assert(math.max(source_in_final, source_out_final) <= extent,
                                string.format(
                                "importer_core: clip '%s' audio source range "
                                .. "[%d,%d] samples exceeds media %s extent %d "
                                .. "(atc=%d, dur=%d samples = %d frames) — parser bug",
                                tostring(clip_data.name), source_in_final, source_out_final,
                                tostring(media_id), extent, atc, dur_samples, fdur))
                        else
                            local vtc = media_row:get_start_tc() or 0
                            local extent = vtc + fdur
                            if media_row.is_still or fdur == 1 then
                                -- Still: source range is always [tc_origin,
                                -- tc_origin+1). Resolve's <In>/<Out> for stills
                                -- are timeline coordinates; the source has
                                -- exactly one frame.
                                source_in_final = vtc
                                source_out_final = vtc + 1
                            else
                                assert(math.max(source_in_final, source_out_final) <= extent,
                                    string.format(
                                    "importer_core: clip '%s' video source range "
                                    .. "[%d,%d] exceeds media %s extent %d (vtc=%d, dur=%d) — parser bug",
                                    tostring(clip_data.name), source_in_final, source_out_final,
                                    tostring(media_id), extent, vtc, fdur))
                            end
                        end

                        local now = os.time()
                        local clip_id = Clip.create({
                            project_id = project_id,
                            owner_sequence_id = sequence.id,
                            track_id = track.id,
                            nested_sequence_id = master_seq_id,
                            name = clip_data.name or "Untitled Clip",
                            timeline_start_frame = clip_data.start_value,
                            duration_frames = clip_data.duration,
                            source_in_frame = source_in_final,
                            source_out_frame = source_out_final,
                            master_layer_track_id = nil,
                            master_audio_track_id = nil,
                            fps_mismatch_policy = "resample",
                            enabled = (clip_data.enabled ~= false),
                            volume = clip_data.volume or 1.0,
                            playhead_frame = 0,
                            created_at = now,
                            modified_at = now,
                        })
                        assert(clip_id and clip_id ~= "", string.format(
                            "importer_core: failed to create clip '%s' in track '%s'",
                            clip_data.name, track_name))
                        local clip = { id = clip_id, nested_sequence_id = master_seq_id }
                        local _unused = { clip_rate_num, clip_rate_den }  -- luacheck: ignore
                        do
                            table.insert(result.clip_ids, clip.id)

                            -- Persist substitution history (OriginalClip) when
                            -- the source format carried one. Rare (replace/
                            -- relink events only) and archival, so this uses
                            -- the properties table rather than adding a
                            -- column to clips.
                            if clip_data.original_clip then
                                Property.save_for_clip(clip.id, {{
                                    property_name = "original_clip",
                                    property_value = clip_data.original_clip,
                                    property_type = "json",
                                }})
                            end

                            -- Assign master sequence to folder bin (V13:
                            -- clip.nested_sequence_id is the master ref).
                            if clip.nested_sequence_id then
                                local bin = nil
                                if clip_data.file_uuid and clip_data.file_uuid ~= "" then
                                    bin = pool_uuid_to_bin[clip_data.file_uuid]
                                end
                                if not bin then
                                    local media = nil
                                    if clip_data.file_uuid and clip_data.file_uuid ~= "" then
                                        media = media_by_uuid[clip_data.file_uuid]
                                    end
                                    if not media and clip_data.file_path and clip_data.file_path ~= "" then
                                        media = media_by_path[clip_data.file_path]
                                    end
                                    if media then
                                        bin = pool_name_to_bin[media.name]
                                    end
                                end
                                if not bin and clip_data.file_path then
                                    local basename = clip_data.file_path:match("([^/\\]+)$")
                                    bin = basename and pool_name_to_bin[basename]
                                end
                                if not bin then
                                    bin = unorganized_bin_id
                                end
                                if bin then
                                    tag_service.add_to_bin(project_id, {clip.nested_sequence_id}, bin, "master_clip")
                                end
                            end

                            if clip_data.file_uuid or clip_data.file_path then
                                table.insert(clips_for_linking, {
                                    clip_id = clip.id,
                                    link_key = clip_data.file_uuid or clip_data.file_path,
                                    timeline_start = clip_data.start_value,
                                    role = track_data.type == "VIDEO" and "video" or "audio",
                                })
                            end
                        end
                        ::continue_clip::
                    end
                end
            end

            -- STEP 6: Create A/V link groups
            local link_groups_by_key = {}
            for _, clip_info in ipairs(clips_for_linking) do
                local key = clip_info.link_key .. ":" .. tostring(clip_info.timeline_start)
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

    -- Masterclip sequences are created as a side effect of Clip.create via
    -- Sequence.ensure_master. They're real sequence rows that belong to
    -- this import — track them so undoers can remove them. Newly-created
    -- media (result.media_ids) implies a newly-created master.
    for _, media_id in ipairs(result.media_ids) do
        local master_id = Sequence.find_master_for_media(media_id)
        if master_id then
            table.insert(result.sequence_ids, master_id)
        end
    end

    log.event("Import complete: %d media, %d sequences, %d tracks, %d clips",
        #result.media_ids, #result.sequence_ids, #result.track_ids, #result.clip_ids)

    -- Return lookup tables for format-specific post-import steps
    result.media_by_uuid = media_by_uuid
    result.media_by_path = media_by_path

    return result
end

return M
