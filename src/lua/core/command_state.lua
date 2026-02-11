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
-- Size: ~294 LOC
-- Volatility: unknown
--
-- @file command_state.lua
-- Original intent (unreviewed):
-- CommandState: Manages state hashing and selection snapshots
-- Extracted from command_manager.lua
local M = {}

local db = nil
local profile_scope = require("core.profile_scope")
local json = require("dkjson")
local logger = require("core.logger")

local TEMP_GAP_PREFIX = "temp_gap_"

local function parse_temp_gap_identifier(clip_id)
    if type(clip_id) ~= "string" then return nil end
    if not clip_id:find("^" .. TEMP_GAP_PREFIX) then return nil end
    local payload = clip_id:sub(#TEMP_GAP_PREFIX + 1)
    local start_str, end_str = payload:match("_(%-?%d+)_(-?%d+)$")
    if not start_str or not end_str then return nil end
    local track_id = payload:sub(1, #payload - (#start_str + #end_str + 2))
    if not track_id or track_id == "" then return nil end
    return track_id, tonumber(start_str), tonumber(end_str)
end

local function resolve_gap_clip_id(edge)
    if not edge or not edge.edge_type or not db then return nil end
    local track_id, start_frames, end_frames = parse_temp_gap_identifier(edge.clip_id)
    if not track_id then return nil end

    local stmt
    if edge.edge_type == "gap_after" then
        stmt = db:prepare([[SELECT id FROM clips WHERE track_id = ? AND (timeline_start_frame + duration_frames) = ? LIMIT 1]])
        if stmt then
            stmt:bind_value(1, track_id)
            stmt:bind_value(2, start_frames)
        end
    elseif edge.edge_type == "gap_before" then
        stmt = db:prepare([[SELECT id FROM clips WHERE track_id = ? AND timeline_start_frame = ? LIMIT 1]])
        if stmt then
            stmt:bind_value(1, track_id)
            stmt:bind_value(2, end_frames)
        end
    end

    if not stmt then return nil end
    local resolved = nil
    if stmt:exec() and stmt:next() then
        resolved = stmt:value(0)
    end
    stmt:finalize()
    return resolved
end

function M.init(database)
    db = database
end

-- Calculate state hash for a project
function M.calculate_state_hash(project_id)
    if not db then
        error("CommandState.calculate_state_hash: No database connection", 2)
    end

    local scope = profile_scope.begin("command_manager.state_hash_query")
    local parts = {}

    local function append_query(sql, bind_values, column_count, label)
        local stmt = db:prepare(sql)
        if not stmt then
            error(string.format("CommandState.calculate_state_hash: Failed to prepare %s query", label or sql:sub(1, 32)), 2)
        end
        if bind_values then
            for index, value in ipairs(bind_values) do
                stmt:bind_value(index, value)
            end
        end

        local ok = stmt:exec()
        if not ok then
            stmt:finalize()
            error(string.format("CommandState.calculate_state_hash: Failed to execute %s query", label or sql:sub(1, 32)), 2)
        end
        while stmt:next() do
            for column = 0, column_count - 1 do
                local value = stmt:value(column)
                parts[#parts + 1] = tostring(value)
                parts[#parts + 1] = "|"
            end
            parts[#parts + 1] = "\n"
        end
        stmt:finalize()
    end

    append_query([[ 
        SELECT id, name, settings
        FROM projects
        WHERE id = ?
    ]], {project_id}, 3, "project")

    append_query([[ 
        SELECT id, name, fps_numerator, fps_denominator, audio_rate, width, height,
               playhead_frame, view_start_frame, view_duration_frames
        FROM sequences
        WHERE project_id = ?
        ORDER BY id
    ]], {project_id}, 10, "sequences")

    append_query([[ 
        SELECT t.sequence_id, t.id, t.track_type, t.track_index, t.enabled
        FROM tracks t
        JOIN sequences s ON t.sequence_id = s.id
        WHERE s.project_id = ?
        ORDER BY t.sequence_id, t.track_index, t.id
    ]], {project_id}, 5, "tracks")

    append_query([[ 
        SELECT t.sequence_id, c.track_id, c.id, c.timeline_start_frame, c.duration_frames,
               c.enabled, c.source_in_frame, c.source_out_frame, c.media_id, c.fps_numerator, c.fps_denominator
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences s ON t.sequence_id = s.id
        WHERE s.project_id = ?
        ORDER BY t.sequence_id, t.track_index, c.timeline_start_frame, c.id
    ]], {project_id}, 11, "clips")

    append_query([[ 
        SELECT id, file_path, duration_frames, fps_numerator, fps_denominator, name
        FROM media
        WHERE project_id = ?
        ORDER BY id
    ]], {project_id}, 6, "media")

    local state_string = table.concat(parts)
    local hash_value = 5381
    for i = 1, #state_string do
        hash_value = ((hash_value * 33) + state_string:byte(i)) % 0x100000000
    end
    local hash = string.format("%08x", hash_value)
    scope:finish(string.format("rows=%d", #parts))
    return hash
end

function M.capture_selection_snapshot()
    -- Lazy load to avoid circular dependency
    local timeline_state = require('ui.timeline.timeline_state')
    
    local selected_clips = timeline_state.get_selected_clips() or {}
    local clip_ids = {}
    for _, clip in ipairs(selected_clips) do
        if clip and clip.id then
            table.insert(clip_ids, clip.id)
        end
    end

    local selected_edges = timeline_state.get_selected_edges() or {}
    local edge_descriptors = {}
    for _, edge in ipairs(selected_edges) do
        if edge and edge.clip_id and edge.edge_type then
            local clip_id = edge.clip_id
            if type(clip_id) == "string" and clip_id:find("^" .. TEMP_GAP_PREFIX) then
                local resolved = resolve_gap_clip_id(edge)
                if resolved then clip_id = resolved end
            end
            table.insert(edge_descriptors, {
                clip_id = clip_id,
                edge_type = edge.edge_type,
                trim_type = edge.trim_type
            })
        end
    end

    local clips_json = json.encode(clip_ids)

    local edges_json = json.encode(edge_descriptors)

    local gap_descriptors = {}
    if type(timeline_state.get_selected_gaps) == "function" then
        local selected_gaps = timeline_state.get_selected_gaps()
        assert(selected_gaps ~= nil, "command_state.capture_selection_snapshot: timeline_state.get_selected_gaps() returned nil")
        for _, gap in ipairs(selected_gaps) do
            if gap and gap.track_id and gap.start_value and gap.duration then
                table.insert(gap_descriptors, {
                    track_id = gap.track_id,
                    start_value = gap.start_value,
                    duration = gap.duration
                })
            end
        end
    end

    local gaps_json = json.encode(gap_descriptors)

    return clips_json, edges_json, gaps_json
end

function M.restore_selection_from_serialized(clips_json, edges_json, gaps_json)
    local timeline_state = require('ui.timeline.timeline_state')
    local Clip = require('models.clip')
    local selection_state = require("ui.timeline.state.selection_state")
    -- Only bypass persistence when using the real timeline_state module and it has not been initialized
    -- with an active sequence. Test stubs often omit get_sequence_id entirely.
    local bypass_persist = false
    if type(timeline_state.get_sequence_id) == "function" then
        local seq = timeline_state.get_sequence_id()
        bypass_persist = (not seq or seq == "")
    end

    local function safe_load_clip(clip_id)
    if not clip_id then
        return nil
    end
    local clip = Clip.load_optional(clip_id, db)
    if not clip then
        logger.warn("command_state", string.format("Failed to restore selection for clip %s (clip not found)", tostring(clip_id)))
    end
    return clip
    end

    local function decode(json_text)
        if not json_text or json_text == "" then
            return {}
        end
        local value, _, err = json.decode(json_text)
        assert(value ~= nil, "command_state.decode: corrupt JSON in undo record: " .. tostring(err))
        assert(type(value) == "table", "command_state.decode: expected table from JSON, got " .. type(value))
        return value
    end

    local edge_infos = decode(edges_json)
    if #edge_infos > 0 then
        local restored_edges = {}
        for _, info in ipairs(edge_infos) do
            if type(info) == "table" and info.clip_id and info.edge_type then
                local clip_id = info.clip_id
                if type(clip_id) == "string" and clip_id:find("^" .. TEMP_GAP_PREFIX) then
                    local resolved = resolve_gap_clip_id(info)
                    if resolved then clip_id = resolved end
                end
                local clip = safe_load_clip(clip_id)
                if clip then
                    table.insert(restored_edges, {
                        clip_id = clip.id,
                        edge_type = info.edge_type,
                        trim_type = info.trim_type
                    })
                end
            end
        end

        if #restored_edges > 0 then
            if bypass_persist then
                selection_state.restore_edge_selection(restored_edges, {normalize = false}, nil)
            else
                if timeline_state.restore_edge_selection then
                    timeline_state.restore_edge_selection(restored_edges, {normalize = false})
                else
                    timeline_state.set_edge_selection(restored_edges)
                end
            end
            return
        end
    end

    local clip_ids = decode(clips_json)
    if #clip_ids > 0 then
        local restored_clips = {}
        for _, clip_id in ipairs(clip_ids) do
            local clip = safe_load_clip(clip_id)
            if clip then
                table.insert(restored_clips, clip)
            end
        end

        if #restored_clips > 0 then
            if bypass_persist then
                selection_state.set_selection(restored_clips, nil)
            else
                timeline_state.set_selection(restored_clips)
            end
            return
        end
    end

    local gap_infos = decode(gaps_json)
    if #gap_infos > 0 and timeline_state.set_gap_selection then
        local restored_gaps = {}
        for _, gap in ipairs(gap_infos) do
            if type(gap) == "table" and gap.track_id and gap.start_value and gap.duration then
                table.insert(restored_gaps, {
                    track_id = gap.track_id,
                    start_value = gap.start_value,
                    duration = gap.duration
                })
            end
        end
        if #restored_gaps > 0 then
            if bypass_persist then
                selection_state.set_gap_selection(restored_gaps)
            else
                timeline_state.set_gap_selection(restored_gaps)
            end
            return
        end
    end

    if bypass_persist then
        selection_state.set_selection({}, nil)
        selection_state.set_gap_selection({})
    else
        timeline_state.set_selection({})
        if timeline_state.set_gap_selection then
            timeline_state.set_gap_selection({})
        end
    end
end

function M.update_command_hashes(command, pre_hash)
    command.pre_hash = pre_hash
end

return M
