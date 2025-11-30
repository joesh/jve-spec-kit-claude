local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local timeline_state = require('ui.timeline.timeline_state')

function M.register(command_executors, command_undoers, db, set_last_error)
    local function normalize_segments(segments)
        if not segments or #segments == 0 then
            return {}
        end

        table.sort(segments, function(a, b)
            if a.start_value == b.start_value then
                return (a.duration or 0) < (b.duration or 0)
            end
            return (a.start_value or 0) < (b.start_value or 0)
        end)

        local merged = {}
        for _, seg in ipairs(segments) do
            local start_value = seg.start_value or 0
            local duration = math.max(0, seg.duration or 0)
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
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing RippleDeleteSelection command")
        end

        local clip_ids = command:get_parameter("clip_ids")

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
            print("RippleDeleteSelection: No clips selected")
            return false
        end

        local clips = {}
        local clip_ids_for_delete = {}
        local window_start = nil
        local window_end = nil

        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load_optional(clip_id, db)
            if clip then
                clips[#clips + 1] = clip
                local clip_start = clip.start_value or 0
                local clip_end = clip_start + (clip.duration or 0)
                window_start = window_start and math.min(window_start, clip_start) or clip_start
                window_end = window_end and math.max(window_end, clip_end) or clip_end
                table.insert(clip_ids_for_delete, clip.id)
            else
                print(string.format("WARNING: RippleDeleteSelection: Clip %s not found", tostring(clip_id)))
            end
        end

        if #clips == 0 then
            print("RippleDeleteSelection: No valid clips to delete")
            return false
        end

        window_start = window_start or 0
        window_end = window_end or window_start
        local shift_amount = window_end - window_start
        if shift_amount < 0 then
            shift_amount = 0
        end

        local sequence_id = command:get_parameter("sequence_id")
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
            print("RippleDeleteSelection: Unable to determine sequence_id")
            return false
        end

        if dry_run then
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
            total_removed_duration = total_removed_duration + (clip.duration or 0)
            selected_by_track[clip.track_id] = selected_by_track[clip.track_id] or {}
            table.insert(selected_by_track[clip.track_id], {
                start_value = clip.start_value or 0,
                duration = clip.duration or 0
            })
            table.insert(global_segments_raw, {
                start_value = clip.start_value or 0,
                duration = clip.duration or 0
            })
        end

        for _, clip in ipairs(clips) do
            if not clip:delete(db) then
                print(string.format("ERROR: RippleDeleteSelection: Failed to delete clip %s", tostring(clip.id)))
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

        local active_sequence_id = nil
        if timeline_state and timeline_state.get_sequence_id then
            local ok, seq = pcall(timeline_state.get_sequence_id)
            if ok then
                active_sequence_id = seq
            end
        end
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
                    while seg_index <= #segments and (segments[seg_index].end_time or (segments[seg_index].start_value + (segments[seg_index].duration or 0))) <= original_start do
                        cumulative_removed = cumulative_removed + (segments[seg_index].duration or 0)
                        seg_index = seg_index + 1
                    end

                    if cumulative_removed > 0 then
                        local shift_clip = Clip.load_optional(shifted_id, db)
                        if shift_clip then
                            local new_start = math.max(0, original_start - cumulative_removed)
                            shift_clip.start_value = new_start
                            if shift_clip:save(db, {skip_occlusion = true}) then
                                table.insert(shifted_clips, {
                                    clip_id = shifted_id,
                                    original_start = original_start,
                                    new_start = new_start,
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
                                    print(err)
                                    return false
                                end
                            end
                        end
                    end
                end

                if not processed then
                    local shift_query = db:prepare([[SELECT id, start_value FROM clips WHERE track_id = ? ORDER BY start_value ASC]])
                    if not shift_query then
                        print("ERROR: RippleDeleteSelection: Failed to prepare per-track shift query")
                        return false
                    end
                    shift_query:bind_value(1, track_id)

                    if shift_query:exec() then
                        while shift_query:next() do
                            local shifted_id = shift_query:value(0)
                            local original_start = shift_query:value(1) or 0
                            local status, err = process_shift_candidate(shifted_id, original_start)
                            if status == false then
                                shift_query:finalize()
                                print(err)
                                return false
                            end
                        end
                    else
                        shift_query:finalize()
                        print("ERROR: RippleDeleteSelection: Failed to execute per-track shift query")
                        return false
                    end

                    shift_query:finalize()
                end
            end
        end

        command:set_parameter("ripple_selection_deleted_clips", deleted_states)
        command:set_parameter("ripple_selection_shifted", shifted_clips)
        command:set_parameter("ripple_selection_shift_amount", total_removed_duration)
        command:set_parameter("ripple_selection_total_removed", total_removed_duration)
        command:set_parameter("ripple_selection_window_start", window_start)
        command:set_parameter("ripple_selection_window_end", window_end)
        command:set_parameter("ripple_selection_sequence_id", sequence_id)

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

        print(string.format("✅ Ripple delete selection: removed %d clip(s), shifted %d clip(s) by %dms",
            #clips, #shifted_clips, shift_amount))
        return true
    end

    command_undoers["RippleDeleteSelection"] = function(command)
        local deleted_states = command:get_parameter("ripple_selection_deleted_clips") or {}
        local shifted_clips = command:get_parameter("ripple_selection_shifted") or {}
        local shift_amount = command:get_parameter("ripple_selection_shift_amount") or command:get_parameter("ripple_selection_total_removed") or 0
        local sequence_id = command:get_parameter("ripple_selection_sequence_id")

        for _, info in ipairs(shifted_clips) do
            local clip = Clip.load_optional(info.clip_id, db)
            if clip and info.original_start then
                clip.start_value = info.original_start
                if not clip:save(db, {skip_occlusion = true}) then
                    print(string.format("WARNING: RippleDeleteSelection undo: Failed to restore shifted clip %s", tostring(info.clip_id)))
                else
                    local update_payload = command_helper.clip_update_payload(clip, sequence_id)
                    if update_payload then
                        command_helper.add_update_mutation(command, update_payload.track_sequence_id or sequence_id, update_payload)
                    end
                end
            end
        end

        for _, state in ipairs(deleted_states) do
            local restored = command_helper.restore_clip_state(state)
            if restored then
                local insert_payload = command_helper.clip_insert_payload(restored, sequence_id or restored.owner_sequence_id)
                if insert_payload then
                    command_helper.add_insert_mutation(command, insert_payload.track_sequence_id or sequence_id, insert_payload)
                end
            end
        end

        -- flush_timeline_mutations assumed handled by manager

        print(string.format("✅ Undo RippleDeleteSelection: restored %d clip(s)", #deleted_states))
        return true
    end

    return {
        executor = command_executors["RippleDeleteSelection"],
        undoer = command_undoers["RippleDeleteSelection"]
    }
end

return M
