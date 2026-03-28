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

            -- Skip if we already created a record for this file_path
            if media_item.file_path and media_by_path[media_item.file_path] then
                local existing = media_by_path[media_item.file_path]
                if media_item.file_uuid then
                    media_by_uuid[media_item.file_uuid] = existing
                end
                goto continue_media
            end

            -- Convert media_start_time (seconds since midnight) to native units
            local media_metadata = '{}'
            local native_rate = math.floor(fps + 0.5)
            if media_item.media_start_time then
                local json = require("dkjson")
                local mst = media_item.media_start_time
                local audio_sr = media_item.audio_sample_rate or 48000
                media_metadata = json.encode({
                    start_tc_value = math.floor(mst * native_rate + 0.5),
                    start_tc_rate = native_rate,
                    start_tc_audio_samples = math.floor(mst * audio_sr + 0.5),
                    start_tc_audio_rate = audio_sr,
                })
            end

            -- Track type determines video presence:
            -- width/height 0 prevents ensure_masterclip from creating a video track.
            local media_width = media_item.has_video and project_settings.width or 0
            local media_height = media_item.has_video and project_settings.height or 0

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
                metadata = media_metadata,
            })

            assert(media:save(), string.format(
                "importer_core: failed to save media '%s' (path=%s)",
                media_item.name, media_item.file_path))

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
                local margin = math.floor(content_duration * 0.05)
                view_start = math.max(start_timecode_frame, view_start - margin)
                view_duration = content_duration + (margin * 2)
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

        local sequence = Sequence.create(
            timeline_data.name,
            project_id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            seq_width,
            seq_height,
            {
                audio_rate = 48000,
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
                        -- Prefer UUID lookup, fall back to path
                        local media_id = nil
                        if clip_data.file_uuid and media_by_uuid[clip_data.file_uuid] then
                            media_id = media_by_uuid[clip_data.file_uuid].id
                        elseif clip_data.file_path and media_by_path[clip_data.file_path] then
                            media_id = media_by_path[clip_data.file_path].id
                        end

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

                        local clip_rate_num, clip_rate_den
                        if track_data.type == "VIDEO" then
                            clip_rate_num, clip_rate_den = fps_num, fps_den
                        else
                            clip_rate_num, clip_rate_den = 48000, 1
                        end

                        local source_out = clip_data.source_out
                        local is_reverse = (clip_data.clip_speed or 1) < 0

                        if not is_reverse then
                            if not source_out or source_out <= (clip_data.source_in or 0) then
                                source_out = (clip_data.source_in or 0) + (clip_data.duration or 0)
                            end
                            if source_out <= (clip_data.source_in or 0) then
                                log.warn("Skipping clip '%s' - zero source range (source_in=%s, source_out=%s)",
                                    clip_data.name or "unnamed", tostring(clip_data.source_in), tostring(source_out))
                                goto continue_clip
                            end
                        else
                            if not source_out then
                                source_out = (clip_data.source_in or 0) - (clip_data.duration or 0)
                            end
                            if source_out == (clip_data.source_in or 0) then
                                log.warn("Skipping reverse clip '%s' - zero source range (source_in=%s, source_out=%s)",
                                    clip_data.name or "unnamed", tostring(clip_data.source_in), tostring(source_out))
                                goto continue_clip
                            end
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
                            enabled = clip_data.enabled,
                            volume = clip_data.volume,
                        })

                        assert(clip:save(), string.format(
                            "importer_core: failed to save clip '%s' in track '%s'",
                            clip_data.name, track_name))
                        do
                            table.insert(result.clip_ids, clip.id)

                            -- Assign masterclip to folder bin
                            if clip.master_clip_id then
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
                                    tag_service.add_to_bin(project_id, {clip.master_clip_id}, bin, "master_clip")
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

    log.event("Import complete: %d media, %d sequences, %d tracks, %d clips",
        #result.media_ids, #result.sequence_ids, #result.track_ids, #result.clip_ids)

    -- Return lookup tables for format-specific post-import steps
    result.media_by_uuid = media_by_uuid
    result.media_by_path = media_by_path

    return result
end

return M
