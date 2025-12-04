-- Timeline View Drag Handler
-- Handles completion of drag operations (executing commands)

local M = {}
local Command = require("command")
local command_manager = require("core.command_manager")
local frame_utils = require("core.frame_utils")
local Rational = require("core.rational")
local json = require("dkjson")

function M.handle_release(view, drag_state, modifiers)
    local state_module = view.state
    local drag_type = drag_state.type
    local delta_ms = drag_state.delta_ms or 0
    local delta_rational = drag_state.delta_rational
    local current_y = drag_state.current_y or drag_state.start_y
    local height = select(2, timeline.get_dimensions(view.widget))
    local target_track_id = view.get_track_id_at_y(current_y, height)
    local alt_copy = (modifiers and modifiers.alt) or drag_state.alt_copy

    if drag_type == "clips" then
        local active_seq = state_module.get_sequence_id()
        local active_proj = state_module.get_project_id()
        local clips = drag_state.clips or {}

        -- Reload clip snapshots to ensure we operate on current state.
        local all_clips = state_module.get_clips()
        local current_clips = {}
        for _, drag_clip in ipairs(clips) do
            for _, clip in ipairs(all_clips) do
                if clip.id == drag_clip.id then
                    table.insert(current_clips, clip)
                    break
                end
            end
        end
        if #current_clips == 0 then
            print("WARNING: Drag release - no current clips found for drag state")
            return
        end

        local all_tracks = state_module.get_all_tracks()
        -- Prefer the anchor clip (the one the user grabbed) as the reference for track offset.
        local reference_clip = current_clips[1]
        if drag_state.anchor_clip_id then
            for _, c in ipairs(current_clips) do
                if c.id == drag_state.anchor_clip_id then
                    reference_clip = c
                    break
                end
            end
        end
        local reference_track_index = nil
        local target_track_index = nil

        for i, track in ipairs(all_tracks) do
            if track.id == reference_clip.track_id then
                reference_track_index = i
            end
            if track.id == target_track_id then
                target_track_index = i
            end
        end

        local track_offset = 0
        if reference_track_index and target_track_index then
            track_offset = target_track_index - reference_track_index
        end

        local command_specs = {}

        -- Track moves: embed pending_new_start when there is a time delta.
        if track_offset ~= 0 then
            -- Build pending_clips so occlusion resolution ignores other clips in the same drag batch.
            local pending_clips = {}
            for _, c in ipairs(current_clips) do
                pending_clips[c.id] = {
                    timeline_start = c.timeline_start,
                    duration = c.duration,
                }
            end

            for _, clip in ipairs(current_clips) do
                local clip_track_index = nil
                for i, track in ipairs(all_tracks) do
                    if track.id == clip.track_id then
                        clip_track_index = i
                        break
                    end
                end

                if clip_track_index then
                    local new_track_index = clip_track_index + track_offset
                    if new_track_index >= 1 and new_track_index <= #all_tracks then
                        local new_track = all_tracks[new_track_index]
                        local old_track = all_tracks[clip_track_index]
                        if new_track.track_type == old_track.track_type then
                            local params = {
                                clip_id = clip.id,
                                target_track_id = new_track.id,
                                skip_occlusion = true,
                                pending_clips = pending_clips
                            }
                            if delta_ms ~= 0 then
                                local rate = state_module.get_sequence_frame_rate and state_module.get_sequence_frame_rate() or {fps_numerator = 30, fps_denominator = 1}
                                local fps_num = rate.fps_numerator or 30
                                local fps_den = rate.fps_denominator or 1
                                local delta_rat = drag_state.delta_rational
                                if not delta_rat then
                                    delta_rat = Rational.from_seconds(delta_ms / 1000.0, fps_num, fps_den)
                                end
                                local pending_start = clip.timeline_start + delta_rat
                                params.pending_new_start_rat = {
                                    frames = pending_start.frames,
                                    fps_numerator = fps_num,
                                    fps_denominator = fps_den
                                }
                                params.pending_duration_rat = {
                                    frames = clip.duration.frames,
                                    fps_numerator = fps_num,
                                    fps_denominator = fps_den
                                }
                                params.sequence_id = active_seq
                                -- Update pending_clips for this clip to the new start to keep occlusion consistent.
                                if pending_clips[clip.id] then
                                    pending_clips[clip.id].timeline_start = pending_start
                                end
                            end
                            table.insert(command_specs, {
                                command_type = "MoveClipToTrack",
                                parameters = params
                            })
                        end
                    end
                end
            end
        end

        -- Time nudge when staying on the same track.
        if track_offset == 0 and delta_ms ~= 0 then
            local ids = {}
            for _, c in ipairs(clips) do table.insert(ids, c.id) end
            local rate = state_module.get_sequence_frame_rate and state_module.get_sequence_frame_rate() or {fps_numerator = 30, fps_denominator = 1}
            local fps_num = rate.fps_numerator or 30
            local fps_den = rate.fps_denominator or 1
            local nudge_rat = Rational.from_seconds(delta_ms / 1000.0, fps_num, fps_den)
            table.insert(command_specs, {
                command_type = "Nudge",
                parameters = {
                    sequence_id = active_seq,
                    project_id = active_proj,
                    fps_numerator = fps_num,
                    fps_denominator = fps_den,
                    nudge_amount_ms = delta_ms,
                    nudge_amount_rat = nudge_rat,
                    selected_clip_ids = ids
                }
            })
        end

        if #command_specs == 0 then
            return
        elseif #command_specs == 1 then
            local spec = command_specs[1]
            local cmd = Command.create(spec.command_type, active_proj)
            for k, v in pairs(spec.parameters) do
                cmd:set_parameter(k, v)
            end
            if active_seq and not cmd:get_parameter("sequence_id") then
                cmd:set_parameter("sequence_id", active_seq)
            end
            local result = command_manager.execute(cmd)
            if not result.success then
                print(string.format("ERROR: %s failed: %s", spec.command_type, result.error_message or "unknown"))
            end
        else
            local batch_cmd = Command.create("BatchCommand", active_proj)
            batch_cmd:set_parameter("commands_json", json.encode(command_specs))
            if active_seq and active_seq ~= "" then
                batch_cmd:set_parameter("sequence_id", active_seq)
                batch_cmd:set_parameter("__snapshot_sequence_ids", {active_seq})
            end
            local result = command_manager.execute(batch_cmd)
            if not result.success then
                print(string.format("ERROR: Batch drag failed: %s", result.error_message or "unknown"))
            end
        end

    elseif drag_type == "edges" then
        local active_seq = state_module.get_sequence_id()
        local active_proj = state_module.get_project_id()
        local edges = drag_state.edges or {}

        if #edges == 0 then return end

        local rate = state_module.get_sequence_frame_rate and state_module.get_sequence_frame_rate() or {fps_numerator = 30, fps_denominator = 1}
        local fps_num = rate.fps_numerator or 30
        local fps_den = rate.fps_denominator or 1

        local delta_rat = drag_state.delta_rational
        if not delta_rat and delta_ms ~= 0 then
            delta_rat = Rational.from_seconds(delta_ms / 1000.0, fps_num, fps_den)
        end
        if not delta_rat then
            delta_rat = Rational.new(0, fps_num, fps_den)
        end
        if delta_rat.frames == 0 then
            return
        end

        -- Lookup track_id for each edge
        local track_by_clip = {}
        for _, c in ipairs(state_module.get_clips() or {}) do
            track_by_clip[c.id] = c.track_id
        end

        local edge_infos = {}
        for _, e in ipairs(edges) do
            table.insert(edge_infos, {
                clip_id = e.clip_id,
                edge_type = e.edge_type,
                track_id = e.track_id or track_by_clip[e.clip_id],
                trim_type = e.trim_type
            })
        end

        local cmd = Command.create("BatchRippleEdit", active_proj)
        cmd:set_parameter("edge_infos", edge_infos)
        cmd:set_parameter("delta_frames", delta_rat.frames)
        if active_seq then cmd:set_parameter("sequence_id", active_seq) end
        local result = command_manager.execute(cmd)
        if not result.success then
            print(string.format("ERROR: BatchRippleEdit failed: %s", result.error_message or "unknown"))
        end
    end
end

return M
