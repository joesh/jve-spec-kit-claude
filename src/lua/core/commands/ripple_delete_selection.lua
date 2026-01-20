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
-- Size: ~428 LOC
-- Volatility: unknown
--
-- @file ripple_delete_selection.lua
local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local timeline_state = require('ui.timeline.timeline_state')
local Rational = require("core.rational")
local logger = require("core.logger")


local SPEC = {
    args = {
        clip_ids = { required = true },
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        ripple_selection_deleted_clips = {},
        ripple_selection_sequence_id = {},
        ripple_selection_shift_amount = {},
        ripple_selection_shifted = {},
        ripple_selection_total_removed = {},
        ripple_selection_window_end = {},
        ripple_selection_window_start = {},
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    local debug_enabled = os.getenv("JVE_DEBUG_RIPPLE_DELETE_SELECTION") == "1"
    local function debug_log(message)
        if debug_enabled then
            logger.debug("ripple_delete_selection", message)
        end
    end

    local function require_number(value, name)
        if value == nil then
            error("FATAL: RippleDeleteSelection missing " .. tostring(name))
        end
        if type(value) ~= "number" then
            error("FATAL: RippleDeleteSelection " .. tostring(name) .. " must be a number")
        end
        return value
    end

    local function load_sequence_rate(sequence_id)
        if not sequence_id or sequence_id == "" then
            error("FATAL: RippleDeleteSelection requires a sequence_id to load fps")
        end
        local query = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        if not query then
            error("FATAL: RippleDeleteSelection: failed to prepare sequence fps query")
        end
        query:bind_value(1, sequence_id)
        local fps_num = nil
        local fps_den = nil
        if query:exec() and query:next() then
            fps_num = tonumber(query:value(0))
            fps_den = tonumber(query:value(1))
        end
        query:finalize()
        if not fps_num or fps_num <= 0 or not fps_den or fps_den <= 0 then
            error(string.format("FATAL: RippleDeleteSelection: sequence %s missing valid fps_numerator/fps_denominator", tostring(sequence_id)))
        end
        return fps_num, fps_den
    end

    local function normalize_segments(segments)
        if not segments or #segments == 0 then
            return {}
        end

        table.sort(segments, function(a, b)
            if a.start_value == b.start_value then
                return require_number(a.duration, "segment.duration") < require_number(b.duration, "segment.duration")
            end
            return require_number(a.start_value, "segment.start_value") < require_number(b.start_value, "segment.start_value")
        end)

        local merged = {}
        for _, seg in ipairs(segments) do
            local start_value = require_number(seg.start_value, "segment.start_value")
            local duration = require_number(seg.duration, "segment.duration")
            if duration < 0 then
                error("FATAL: RippleDeleteSelection: segment.duration must be >= 0")
            end

            local end_time = start_value + duration
            if end_time > start_value then
                local last = merged[#merged]
                if last and start_value <= last.end_time then
                    if end_time > last.end_time then
                        last.end_time = end_time
                        last.duration = last.end_time - last.start_value
                    end
                else
                    table.insert(merged, {
                        start_value = start_value,
                        end_time = end_time,
                        duration = duration
                    })
                end
            end
        end

        return merged
    end

    local function load_sequence_track_ids(sequence_id)
        if not sequence_id or sequence_id == "" then
            return {}
        end
        local ids = {}
        local query = db:prepare("SELECT id FROM tracks WHERE sequence_id = ?")
        if not query then
            return ids
        end
        query:bind_value(1, sequence_id)
        if query:exec() then
            while query:next() do
                table.insert(ids, query:value(0))
            end
        end
        query:finalize()
        return ids
    end

    command_executors["RippleDeleteSelection"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            debug_log("Executing RippleDeleteSelection command")
        end

        local clip_ids = args.clip_ids

        if (not clip_ids or #clip_ids == 0) and timeline_state and timeline_state.get_selected_clips then
            local selected = timeline_state.get_selected_clips() or {}
            clip_ids = {}
            for _, clip in ipairs(selected) do
                if type(clip) == "table" then
                    if clip.id then
                        table.insert(clip_ids, clip.id)
                    elseif clip.clip_id then
                        table.insert(clip_ids, clip.clip_id)
                    end
                elseif type(clip) == "string" then
                    table.insert(clip_ids, clip)
                end
            end
        end

        if not clip_ids or #clip_ids == 0 then
            logger.warn("ripple_delete_selection", "No clips selected")
            return false
        end

        local clips = {}
        local clip_ids_for_delete = {}
        local window_start = nil
        local window_end = nil
        local function clip_start_frames(clip)
            if clip.timeline_start and clip.timeline_start.frames ~= nil then
                return tonumber(clip.timeline_start.frames)
            end
            if clip.start_value ~= nil then
                return tonumber(clip.start_value)
            end
            error("FATAL: RippleDeleteSelection: clip missing timeline_start")
        end
        local function clip_duration_frames(clip)
            if clip.duration and clip.duration.frames ~= nil then
                return tonumber(clip.duration.frames)
            end
            if clip.duration ~= nil then
                return tonumber(clip.duration)
            end
            error("FATAL: RippleDeleteSelection: clip missing duration")
        end

        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load_optional(clip_id)
            if clip then
                clips[#clips + 1] = clip
                local clip_start = clip_start_frames(clip)
                local clip_end = clip_start + clip_duration_frames(clip)
                window_start = window_start and math.min(window_start, clip_start) or clip_start
                window_end = window_end and math.max(window_end, clip_end) or clip_end
                table.insert(clip_ids_for_delete, clip.id)
            else
                logger.warn("ripple_delete_selection", string.format("Clip %s not found", tostring(clip_id)))
            end
        end

        if #clips == 0 then
            logger.warn("ripple_delete_selection", "No valid clips to delete")
            return false
        end

        if window_start == nil or window_end == nil then
            error("FATAL: RippleDeleteSelection: unable to compute window bounds")
        end
        local shift_amount = window_end - window_start
        if shift_amount < 0 then
            error("FATAL: RippleDeleteSelection: computed negative shift_amount")
        end

        local sequence_id = args.sequence_id
        if (not sequence_id or sequence_id == "") and #clips > 0 then
            local track_query = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
            if track_query then
                track_query:bind_value(1, clips[1].track_id)
                if track_query:exec() and track_query:next() then
                    sequence_id = track_query:value(0)
                end
                track_query:finalize()
            end
        end

        if not sequence_id or sequence_id == "" then
            logger.error("ripple_delete_selection", "Unable to determine sequence_id")
            return false
        end

        local sequence_fps_num, sequence_fps_den = load_sequence_rate(sequence_id)

        if args.dry_run then
            return true, {
                clip_count = #clips,
                shift_amount = shift_amount,
                window_start = window_start,
                window_end = window_end,
            }
        end

        local deleted_states = {}
        local selected_by_track = {}
        local global_segments_raw = {}
        local total_removed_duration = 0

        for _, clip in ipairs(clips) do
            table.insert(deleted_states, command_helper.capture_clip_state(clip))
            local dur_frames = clip_duration_frames(clip)
            local start_frames = clip_start_frames(clip)
            total_removed_duration = total_removed_duration + dur_frames
            selected_by_track[clip.track_id] = selected_by_track[clip.track_id] or {}
            table.insert(selected_by_track[clip.track_id], {
                start_value = start_frames,
                duration = dur_frames
            })
            table.insert(global_segments_raw, {
                start_value = start_frames,
                duration = dur_frames
            })
        end

        for _, clip in ipairs(clips) do
            if not clip:delete() then
                logger.error("ripple_delete_selection", string.format("Failed to delete clip %s", tostring(clip.id)))
                return false
            end
        end
        if #clip_ids_for_delete > 0 then
            command_helper.add_delete_mutation(command, sequence_id, clip_ids_for_delete)
        end

        local normalized_segments_by_track = {}
        for track_id, segments in pairs(selected_by_track) do
            normalized_segments_by_track[track_id] = normalize_segments(segments)
        end
        local global_segments = normalize_segments(global_segments_raw)
        local track_ids = load_sequence_track_ids(sequence_id)
        if (#track_ids == 0) then
            for track_id in pairs(selected_by_track) do
                table.insert(track_ids, track_id)
            end
        end

        local shifted_clips = {}
        local deleted_lookup = {}
        for _, deleted_id in ipairs(clip_ids_for_delete) do
            deleted_lookup[deleted_id] = true
        end

        local active_sequence_id = command_helper.resolve_active_sequence_id(nil, timeline_state)
        local timeline_track_cache_allowed = timeline_state
            and timeline_state.get_clips_for_track
            and active_sequence_id
            and active_sequence_id == sequence_id

        for _, track_id in ipairs(track_ids) do
            local segments = normalized_segments_by_track[track_id]
            if (not segments or #segments == 0) and global_segments and #global_segments > 0 then
                segments = global_segments
            end

            if segments and #segments > 0 then
                local seg_index = 1
                local cumulative_removed = 0

                local function process_shift_candidate(shifted_id, original_start)
                    while seg_index <= #segments do
                        local seg = segments[seg_index]
                        local seg_end_val = seg.end_time
                        
                        if type(seg_end_val) == "table" and seg_end_val.frames then
                            seg_end_val = seg_end_val.frames
                        end
                        
                        if seg_end_val <= original_start then
                            local dur = seg.duration or 0
                            if type(dur) == "table" and dur.frames then dur = dur.frames end
                            cumulative_removed = cumulative_removed + dur
                            seg_index = seg_index + 1
                        else
                            break
                        end
                    end

                    if cumulative_removed > 0 then
                        local shift_clip = Clip.load_optional(shifted_id)
                        if shift_clip then
                            local new_start_frames = original_start - cumulative_removed
                            if new_start_frames < 0 then
                                return false, string.format("ERROR: RippleDeleteSelection: computed negative new_start for %s", tostring(shifted_id))
                            end

                            shift_clip.timeline_start = Rational.new(new_start_frames, sequence_fps_num, sequence_fps_den)
                            if shift_clip:save({skip_occlusion = true}) then
                                table.insert(shifted_clips, {
                                    clip_id = shifted_id,
                                    original_start = original_start,
                                    new_start = new_start_frames,
                                })
                                local update_payload = command_helper.clip_update_payload(shift_clip, sequence_id)
                                if update_payload then
                                    command_helper.add_update_mutation(command, update_payload.track_sequence_id or sequence_id, update_payload)
                                end
                            else
                                return false, string.format("ERROR: RippleDeleteSelection: Failed to save shifted clip %s", tostring(shifted_id))
                            end
                        end
                    end
                    return true
                end

                local processed = false
                if timeline_track_cache_allowed then
                    local ok, track_clips = pcall(timeline_state.get_clips_for_track, track_id)
                    if ok and track_clips and #track_clips > 0 then
                        processed = true
                        for _, entry in ipairs(track_clips) do
                            if not deleted_lookup[entry.id] then
                                local status, err = process_shift_candidate(entry.id, entry.start_value or 0)
                                if status == false then
                                    logger.error("ripple_delete_selection", tostring(err))
                                    return false
                                end
                            end
                        end
                    end
                end

                if not processed then
                    local shift_query = db:prepare([[SELECT id, timeline_start_frame FROM clips WHERE track_id = ? ORDER BY timeline_start_frame ASC]])
                    if not shift_query then
                        logger.error("ripple_delete_selection", "Failed to prepare per-track shift query")
                        return false
                    end
                    shift_query:bind_value(1, track_id)

                    if shift_query:exec() then
                        while shift_query:next() do
                            local shifted_id = shift_query:value(0)
                            local original_start = tonumber(shift_query:value(1))
                            if original_start == nil then
                                shift_query:finalize()
                                error("FATAL: RippleDeleteSelection: shift query returned nil timeline_start_frame")
                            end
                            local status, err = process_shift_candidate(shifted_id, original_start)
                            if status == false then
                                shift_query:finalize()
                                logger.error("ripple_delete_selection", tostring(err))
                                return false
                            end
                        end
                    else
                        shift_query:finalize()
                        logger.error("ripple_delete_selection", "Failed to execute per-track shift query")
                        return false
                    end

                    shift_query:finalize()
                end
            end
        end

        command:set_parameters({
            ["ripple_selection_deleted_clips"] = deleted_states,
            ["ripple_selection_shifted"] = shifted_clips,
            ["ripple_selection_shift_amount"] = total_removed_duration,
            ["ripple_selection_total_removed"] = total_removed_duration,
            ["ripple_selection_window_start"] = window_start,
            ["ripple_selection_window_end"] = window_end,
            ["ripple_selection_sequence_id"] = sequence_id,
        })
        if timeline_state then
            if timeline_state.set_selection then
                timeline_state.set_selection({})
            end
            if timeline_state.clear_edge_selection then
                timeline_state.clear_edge_selection()
            end
            if timeline_state.clear_gap_selection then
                timeline_state.clear_gap_selection()
            end
            if timeline_state.persist_state_to_db then
                timeline_state.persist_state_to_db()
            end
        end

        debug_log(string.format("Ripple delete selection: removed %d clip(s), shifted %d clip(s) by %s",
            #clips, #shifted_clips, tostring(shift_amount)))
        return true
    end

    command_undoers["RippleDeleteSelection"] = function(command)
        local args = command:get_all_parameters()
        local deleted_states = args.ripple_selection_deleted_clips or {}
        local shifted_clips = args.ripple_selection_shifted or {}


        local failed = false

        if not args.ripple_selection_sequence_id or args.ripple_selection_sequence_id == "" then
            error("FATAL: RippleDeleteSelection undo requires ripple_selection_sequence_id")
        end

        local sequence_fps_num, sequence_fps_den = load_sequence_rate(args.ripple_selection_sequence_id)

        table.sort(shifted_clips, function(a, b)
            return require_number(a.original_start, "shifted_clip.original_start") > require_number(b.original_start, "shifted_clip.original_start")
        end)

        for _, info in ipairs(shifted_clips) do
            local clip = Clip.load_optional(info.clip_id)
            if clip and info.original_start then
                clip.timeline_start = Rational.new(info.original_start, sequence_fps_num, sequence_fps_den)
                if not clip:save({skip_occlusion = true}) then
                    logger.warn("ripple_delete_selection", string.format("Undo: Failed to restore shifted clip %s", tostring(info.clip_id)))
                    failed = true
                else
                    local update_payload = command_helper.clip_update_payload(clip, args.ripple_selection_sequence_id)
                    if update_payload then
                        command_helper.add_update_mutation(command, update_payload.track_sequence_id or args.ripple_selection_sequence_id, update_payload)
                    end
                end
            end
        end

        for _, state in ipairs(deleted_states) do
            local restored = command_helper.restore_clip_state(state)
            if restored then
                if restored.timeline_start and restored.timeline_start.frames ~= nil then
                    restored.timeline_start = Rational.new(tonumber(restored.timeline_start.frames), sequence_fps_num, sequence_fps_den)
                end
                if restored.duration and restored.duration.frames ~= nil then
                    restored.duration = Rational.new(tonumber(restored.duration.frames), sequence_fps_num, sequence_fps_den)
                end

                local ok = restored:save({skip_occlusion = true})
                if not ok then
                    logger.warn("ripple_delete_selection", string.format("Undo: Failed to reinsert deleted clip %s", tostring(restored.id)))
                    failed = true
                else
                    local insert_payload = command_helper.clip_insert_payload(restored, args.ripple_selection_sequence_id or restored.owner_sequence_id)
                    if insert_payload then
                        command_helper.add_insert_mutation(command, insert_payload.track_sequence_id or args.ripple_selection_sequence_id, insert_payload)
                    end
                end
            end
        end

        -- flush_timeline_mutations assumed handled by manager

        debug_log(string.format("Undo RippleDeleteSelection: restored %d clip(s)", #deleted_states))
        if failed then
            return false, "RippleDeleteSelection undo: one or more clips failed to restore (overlap/DB error)"
        end
        return true
    end

    return {
        executor = command_executors["RippleDeleteSelection"],
        undoer = command_undoers["RippleDeleteSelection"],
        spec = SPEC,
    }
end

return M
