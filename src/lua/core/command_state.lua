-- CommandState: Manages state hashing and selection snapshots
-- Extracted from command_manager.lua

local M = {}

local db = nil
local profile_scope = require("core.profile_scope")
local json = require("dkjson")

-- State tracking
local current_state_hash = ""
local state_hash_cache = {}

local sequence_initial_state = {
    clips = {},
    media = {},
    master = {},
    timeline = {}
}

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
    current_state_hash = ""
    state_hash_cache = {}
end

-- Calculate state hash for a project
function M.calculate_state_hash(project_id)
    if not db then
        print("WARNING: No database connection for state hash calculation")
        return "00000000"
    end

    local scope = profile_scope.begin("command_manager.state_hash_query")
    local parts = {}

    local function append_query(sql, bind_values, column_count, label)
        local stmt = db:prepare(sql)
        if not stmt then
            print(string.format("WARNING: Failed to prepare %s query for state hash", label or sql:sub(1, 32)))
            return
        end
        if bind_values then
            for index, value in ipairs(bind_values) do
                stmt:bind_value(index, value)
            end
        end

        local ok = stmt:exec()
        if ok then
            while stmt:next() do
                for column = 0, column_count - 1 do
                    local value = stmt:value(column)
                    parts[#parts + 1] = tostring(value)
                    parts[#parts + 1] = "|"
                end
                parts[#parts + 1] = "\n"
            end
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

    local success_clips, clips_json = pcall(qt_json_encode, clip_ids)
    if not success_clips then
        clips_json = "[]"
    end

    local success_edges, edges_json = pcall(qt_json_encode, edge_descriptors)
    if not success_edges then
        edges_json = "[]"
    end

    local selected_gaps = timeline_state.get_selected_gaps and timeline_state.get_selected_gaps() or {}
    local gap_descriptors = {}
    for _, gap in ipairs(selected_gaps) do
        if gap and gap.track_id and gap.start_value and gap.duration then
            table.insert(gap_descriptors, {
                track_id = gap.track_id,
                start_value = gap.start_value,
                duration = gap.duration
            })
        end
    end

    local success_gaps, gaps_json = pcall(qt_json_encode, gap_descriptors)
    if not success_gaps then
        gaps_json = "[]"
    end

    return clips_json, edges_json, gaps_json
end

function M.restore_selection_from_serialized(clips_json, edges_json, gaps_json)
    local timeline_state = require('ui.timeline.timeline_state')
    local Clip = require('models.clip')

local function safe_load_clip(clip_id)
    if not clip_id then
        return nil
    end
    local clip = Clip.load_optional(clip_id, db)
    if not clip then
        print(string.format("WARNING: Failed to restore selection for clip %s (clip not found)", tostring(clip_id)))
    end
    return clip
end

    local function decode(json_text)
        if not json_text or json_text == "" then
            return {}
        end
        local ok, value = pcall(qt_json_decode, json_text)
        if ok and type(value) == "table" then
            return value
        end
        return {}
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
            if timeline_state.set_edge_selection_raw then
                timeline_state.set_edge_selection_raw(restored_edges, {normalize = false})
            else
                timeline_state.set_edge_selection(restored_edges)
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
            timeline_state.set_selection(restored_clips)
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
            timeline_state.set_gap_selection(restored_gaps)
            return
        end
    end

    timeline_state.set_selection({})
    if timeline_state.set_gap_selection then
        timeline_state.set_gap_selection({})
    end
end

function M.update_command_hashes(command, pre_hash)
    command.pre_hash = pre_hash
end

return M
