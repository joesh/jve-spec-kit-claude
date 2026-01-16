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
-- Size: ~265 LOC
-- Volatility: unknown
--
-- @file timeline_view_drag_handler.lua
-- Original intent (unreviewed):
-- Timeline View Drag Handler
-- Handles completion of drag operations (executing commands)
local M = {}
local Command = require("command")
local command_manager = require("core.command_manager")
local json = require("dkjson")
local logger = require("core.logger")

function M.handle_release(view, drag_state, modifiers)
    local state_module = view.state
    local drag_type = drag_state.type
    local current_y = drag_state.current_y or drag_state.start_y
    local height = select(2, timeline.get_dimensions(view.widget))
    local target_track_id = view.get_track_id_at_y(current_y, height)

    if drag_type == "clips" then
        local delta_rat = drag_state.delta_rational
        assert(delta_rat and delta_rat.frames ~= nil, "timeline_view_drag_handler: missing delta_rational for clip drag")
        -- alt-copy semantics are tracked on drag_state for potential future use.
        local active_seq = state_module.get_sequence_id()
        local active_proj = state_module.get_project_id()
        local clips = drag_state.clips or {}

        -- Reload clip snapshots via stable lookup (avoid scanning thousands of clips).
        local current_clips = {}
        if state_module.get_clip_by_id then
            for _, drag_clip in ipairs(clips) do
                local clip = drag_clip and drag_clip.id and state_module.get_clip_by_id(drag_clip.id) or nil
                if clip then
                    table.insert(current_clips, clip)
                end
            end
        else
            local all_clips = state_module.get_clips()
            local clip_lookup = {}
            for _, clip in ipairs(all_clips) do
                if clip and clip.id then
                    clip_lookup[clip.id] = clip
                end
            end
            for _, drag_clip in ipairs(clips) do
                local clip = drag_clip and drag_clip.id and clip_lookup[drag_clip.id] or nil
                if clip then
                    table.insert(current_clips, clip)
                end
            end
        end
        if #current_clips == 0 then
            logger.warn("timeline_drag", "Drag release - no current clips found for drag state")
            return
        end

        local all_tracks = state_module.get_all_tracks()
        local track_index_lookup = {}
        for idx, track in ipairs(all_tracks or {}) do
            track_index_lookup[track.id] = idx
        end
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
        local reference_track_index = track_index_lookup[reference_clip.track_id]
        local target_track_index = track_index_lookup[target_track_id]

        local track_offset = 0
        if reference_track_index and target_track_index then
            track_offset = target_track_index - reference_track_index
        end

        if drag_state.alt_copy then
            local ids = {}
            for _, c in ipairs(current_clips) do
                if c and c.id then
                    table.insert(ids, c.id)
                end
            end

            if target_track_id == reference_clip.track_id and delta_rat.frames == 0 then
                return
            end

            local result = command_manager.execute("DuplicateClips", {
                ["project_id"] = active_proj,
                                ["sequence_id"] = active_seq,
                                ["__snapshot_sequence_ids"] = {active_seq},
                                ["clip_ids"] = ids,
                                ["delta_rat"] = delta_rat,
                                ["target_track_id"] = target_track_id,
                                ["anchor_clip_id"] = reference_clip.id,
            })
            if not result.success then
                logger.error("timeline_drag", string.format("DuplicateClips failed: %s", result.error_message or "unknown"))
            end
            return
        end

        local command_specs = {}

        -- Track moves: embed pending_new_start when there is a time delta.
        if track_offset ~= 0 then
            if track_offset > 0 then
                table.sort(current_clips, function(a, b)
                    return (track_index_lookup[a.track_id] or 0) > (track_index_lookup[b.track_id] or 0)
                end)
            elseif track_offset < 0 then
                table.sort(current_clips, function(a, b)
                    return (track_index_lookup[a.track_id] or 0) < (track_index_lookup[b.track_id] or 0)
                end)
            end

            -- Build pending_clips so occlusion resolution ignores other clips in the same drag batch.
            local pending_clips = {}
            for _, c in ipairs(current_clips) do
                pending_clips[c.id] = {
                    timeline_start = c.timeline_start,
                    duration = c.duration,
                }
            end

            for _, clip in ipairs(current_clips) do
                local clip_track_index = track_index_lookup[clip.track_id]

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
                            if delta_rat.frames ~= 0 then
                                local fps_num = delta_rat.fps_numerator
                                local fps_den = delta_rat.fps_denominator
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
        if track_offset == 0 and delta_rat.frames ~= 0 then
            local ids = {}
            for _, c in ipairs(clips) do table.insert(ids, c.id) end
            local fps_num = delta_rat.fps_numerator
            local fps_den = delta_rat.fps_denominator
            table.insert(command_specs, {
                command_type = "Nudge",
                parameters = {
                    sequence_id = active_seq,
                    project_id = active_proj,
                    fps_numerator = fps_num,
                    fps_denominator = fps_den,
                    nudge_amount_rat = delta_rat,
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
                logger.error("timeline_drag", string.format("%s failed: %s", spec.command_type, result.error_message or "unknown"))
            end
        else
            local batch_cmd_params = {
                project_id = active_proj,
            }
            batch_cmd_params.commands_json = json.encode(command_specs)
            if active_seq and active_seq ~= "" then
                for key, value in pairs({
                    ["sequence_id"] = active_seq,
                    ["__snapshot_sequence_ids"] = {active_seq},
                }) do
                    batch_cmd_params[key] = value
                end
            end
            local result = command_manager.execute("BatchCommand", batch_cmd_params)
            if not result.success then
                logger.error("timeline_drag", string.format("Batch drag failed: %s", result.error_message or "unknown"))
            end
        end

    elseif drag_type == "edges" then
        local active_seq = state_module.get_sequence_id()
        local active_proj = state_module.get_project_id()
        local edges = drag_state.edges or {}
        local lead_edge = drag_state.lead_edge

        if #edges == 0 then return end

        local delta_rat = drag_state.preview_clamped_delta or drag_state.delta_rational
        assert(delta_rat and delta_rat.frames ~= nil, "timeline_view_drag_handler: missing delta for edge drag")
        if delta_rat.frames == 0 then
            return
        end

        -- Lookup track_id for each edge
        local track_by_clip = nil
        if type(drag_state.preloaded_clip_snapshot) == "table" then
            track_by_clip = drag_state.preloaded_clip_snapshot.clip_track_lookup
        end
        if type(track_by_clip) ~= "table" then
            track_by_clip = {}
            for _, edge in ipairs(edges) do
                if edge and edge.clip_id and not track_by_clip[edge.clip_id] then
                    local clip = state_module.get_clip_by_id and state_module.get_clip_by_id(edge.clip_id) or nil
                    if clip and clip.track_id then
                        track_by_clip[edge.clip_id] = clip.track_id
                    end
                end
            end
            if lead_edge and lead_edge.clip_id and not track_by_clip[lead_edge.clip_id] then
                local clip = state_module.get_clip_by_id and state_module.get_clip_by_id(lead_edge.clip_id) or nil
                if clip and clip.track_id then
                    track_by_clip[lead_edge.clip_id] = clip.track_id
                end
            end
        end

        local function normalize_edge_entry(edge)
            if not edge then return nil end
            return {
                clip_id = edge.clip_id,
                edge_type = edge.edge_type,
                track_id = edge.track_id or track_by_clip[edge.clip_id],
                trim_type = edge.trim_type
            }
        end

        local edge_infos = {}
        for _, e in ipairs(edges) do
            local normalized = normalize_edge_entry(e)
            if normalized then
                table.insert(edge_infos, normalized)
            end
        end

        local lead_edge_info = normalize_edge_entry(lead_edge)

        local cmd = Command.create("BatchRippleEdit", active_proj)
        cmd:set_parameters({
            ["edge_infos"] = edge_infos,
            ["delta_frames"] = delta_rat.frames,
        })
        if lead_edge_info then
            cmd:set_parameter("lead_edge", lead_edge_info)
        end
        if active_seq then
            cmd:set_parameter("sequence_id", active_seq)
            -- Required by CommandManager snapshotting.
            cmd:set_parameter("__snapshot_sequence_ids", {active_seq})
        end

        -- UI-only optimization: allow BatchRippleEdit to reuse the already-loaded
        -- in-memory timeline clip indices during execution (avoid DB reload).
        cmd:set_parameter("__use_timeline_state_cache", true)

        -- Provide the interaction snapshot/region so BatchRippleEdit can avoid
        -- loading the full sequence for roll-only edits.
        if drag_state.preloaded_clip_snapshot then
            cmd:set_parameter("__preloaded_clip_snapshot", drag_state.preloaded_clip_snapshot)
        end
        if drag_state.timeline_active_region then
            cmd:set_parameter("__timeline_active_region", drag_state.timeline_active_region)
        end
        local result = command_manager.execute(cmd)
        if not result.success then
            logger.error("timeline_drag", string.format("BatchRippleEdit failed: %s", result.error_message or "unknown"))
        end
    end
end

return M
