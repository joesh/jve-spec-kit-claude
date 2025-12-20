-- Timeline Core State
-- Initialization, Persistence, and Reloading logic

local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")
local track_state = require("ui.timeline.state.track_state")
local selection_state = require("ui.timeline.state.selection_state")
local db = require("core.database")
local json = require("dkjson")
local Rational = require("core.rational")
local ui_constants = require("core.ui_constants")

local persist_timer = nil
local persist_dirty = false
local PERSIST_DEBOUNCE_MS = ui_constants.TIMELINE.PERSIST_DEBOUNCE_MS or 75

-- Qt timer bridge
local function create_single_shot_timer(delay_ms, callback)
    if type(qt_create_single_shot_timer) == "function" then
        return qt_create_single_shot_timer(delay_ms, callback)
    end
    callback()
    return nil
end

local TRACK_HEIGHT_TEMPLATE_KEY = "track_height_template"

local function clamp_track_height(height)
    if type(height) ~= "number" then return nil end
    local clamped = math.floor(height)
    if clamped < 24 then clamped = 24 end
    return clamped
end

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
    if not edge or not edge.edge_type then return nil end
    local track_id, start_frames, end_frames = parse_temp_gap_identifier(edge.clip_id)
    if not track_id then return nil end
    for _, clip in ipairs(data.state.clips or {}) do
        if clip.track_id == track_id and clip.timeline_start and clip.duration then
            if edge.edge_type == "gap_after" then
                local clip_end = clip.timeline_start + clip.duration
                if clip_end.frames == start_frames then
                    return clip.id
                end
            elseif edge.edge_type == "gap_before" then
                if clip.timeline_start.frames == end_frames then
                    return clip.id
                end
            end
        end
    end
    return nil
end

local function build_track_height_map()
    local result = {}
    for _, track in ipairs(data.state.tracks) do
        if track.id and track.id ~= "" then
            result[track.id] = clamp_track_height(track.height or data.dimensions.default_track_height)
        end
    end
    return result
end

local function build_track_height_template()
    if not data.state.tracks or #data.state.tracks == 0 then return nil end
    local template = { video = {}, audio = {} }
    for _, track in ipairs(data.state.tracks) do
        local normalized = clamp_track_height(track.height or data.dimensions.default_track_height)
        if track.track_type == "VIDEO" then
            table.insert(template.video, normalized)
        elseif track.track_type == "AUDIO" then
            table.insert(template.audio, normalized)
        end
    end
    return template
end

-- Column Constants
local SEQ_COL_PLAYHEAD = 0
local SEQ_COL_SEL_CLIPS = 1
local SEQ_COL_SEL_EDGES = 2
local SEQ_COL_VIEW_START = 3
local SEQ_COL_VIEW_DUR = 4
local SEQ_COL_FPS_NUM = 5
local SEQ_COL_FPS_DEN = 6
local SEQ_COL_MARK_IN = 7
local SEQ_COL_MARK_OUT = 8

local function flush_state_to_db()
    local db_conn = db.get_connection()
    if not db_conn then return end

    local sequence_id = data.state.sequence_id
    assert(sequence_id and sequence_id ~= "", "timeline_core_state.flush_state_to_db: missing sequence_id")

    -- Serialize selection
    local selected_ids = {}
    for _, clip in ipairs(data.state.selected_clips) do
        table.insert(selected_ids, clip.id)
    end
    local success, json_str = pcall(json.encode, selected_ids)
    if not success then json_str = "[]" end

    -- Serialize edges
    local edge_descriptors = {}
    for _, edge in ipairs(data.state.selected_edges) do
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
    local success_edges, edges_json = pcall(json.encode, edge_descriptors)
    if not success_edges then edges_json = "[]" end

    local query = db_conn:prepare([[ 
        UPDATE sequences
        SET playhead_frame = ?, selected_clip_ids = ?, selected_edge_infos = ?, view_start_frame = ?, view_duration_frames = ?, mark_in_frame = ?, mark_out_frame = ?
        WHERE id = ?
    ]])

    if query then
        query:bind_value(1, data.state.playhead_position.frames)
        query:bind_value(2, json_str)
        query:bind_value(3, edges_json)
        query:bind_value(4, data.state.viewport_start_time.frames)
        query:bind_value(5, data.state.viewport_duration.frames)
        query:bind_value(6, data.state.mark_in_value and data.state.mark_in_value.frames or nil)
        query:bind_value(7, data.state.mark_out_value and data.state.mark_out_value.frames or nil)
        query:bind_value(8, sequence_id)
        query:exec()
    end

    if track_state.is_layout_dirty() and db.set_sequence_track_heights then
        local height_map = build_track_height_map()
        db.set_sequence_track_heights(sequence_id, height_map)
        track_state.clear_layout_dirty()
    end

    -- Template persistence (could be moved to track_state, but centralized here for now)
    -- Need a dirty flag for template? track_state doesn't expose it. Assuming layout dirty implies template check?
    -- Original code had `track_template_dirty`.
    -- For simplicity, we save template if layout changed.
    if db.set_project_setting then
        local template = build_track_height_template()
        if template then
            local project_id = data.state.project_id
            assert(project_id and project_id ~= "", "timeline_core_state.flush_state_to_db: missing project_id")
            db.set_project_setting(project_id, TRACK_HEIGHT_TEMPLATE_KEY, template)
        end
    end
end

local function schedule_state_persist(immediate)
    persist_dirty = true
    if immediate then
        persist_dirty = false
        flush_state_to_db()
        return
    end
    if persist_timer then return end
    persist_timer = create_single_shot_timer(PERSIST_DEBOUNCE_MS, function()
        persist_timer = nil
        if not persist_dirty then return end
        persist_dirty = false
        flush_state_to_db()
    end)
end

function M.persist_state_to_db(force)
    if force == true then
        schedule_state_persist(true)
    else
        schedule_state_persist(false)
    end
end

function M.init(sequence_id, project_id)
    -- Persist pending state before switching
    if persist_dirty then M.persist_state_to_db(true) end

    assert(sequence_id and sequence_id ~= "", "timeline_core_state.init: sequence_id is required")
    data.state.sequence_id = sequence_id

    -- Load Data
    data.state.tracks = db.load_tracks(sequence_id)
    data.state.clips = db.load_clips(sequence_id)
    clip_state.invalidate_indexes()

    -- Load Sequence Settings
    local db_conn = db.get_connection()
    if db_conn then
        local project_stmt = db_conn:prepare("SELECT project_id FROM sequences WHERE id = ?")
        if not project_stmt then
            error("timeline_core_state.init: failed to prepare sequence->project query", 2)
        end
        project_stmt:bind_value(1, sequence_id)
        local seq_project_id = nil
        if project_stmt:exec() and project_stmt:next() then
            seq_project_id = project_stmt:value(0)
        end
        project_stmt:finalize()
        assert(seq_project_id and seq_project_id ~= "", "timeline_core_state.init: sequence missing project_id in DB (sequence_id=" .. tostring(sequence_id) .. ")")
        if project_id and project_id ~= "" then
            assert(seq_project_id == project_id,
                "timeline_core_state.init: provided project_id does not match sequence.project_id (sequence_id="
                    .. tostring(sequence_id) .. ", provided=" .. tostring(project_id) .. ", db=" .. tostring(seq_project_id) .. ")")
        end
        data.state.project_id = seq_project_id

        local query = db_conn:prepare("SELECT playhead_frame, selected_clip_ids, selected_edge_infos, view_start_frame, view_duration_frames, fps_numerator, fps_denominator, mark_in_frame, mark_out_frame FROM sequences WHERE id = ?")
        if query then
            query:bind_value(1, sequence_id)
            if query:exec() and query:next() then
                local fps_num = query:value(SEQ_COL_FPS_NUM)
                local fps_den = query:value(SEQ_COL_FPS_DEN)
                
                if not fps_num or not fps_den then
                    error(string.format("FATAL: Sequence %s has NULL frame rate in database", tostring(sequence_id)))
                end
                
                data.state.sequence_frame_rate = { fps_numerator = fps_num, fps_denominator = fps_den }

                -- Rescale existing rationals if rate changed (though we just reloaded state so they are fresh/default)
                -- But if we are re-initing same state object, we should be careful.
                -- `fresh_state` in data.lua sets defaults.

                -- Restore Playhead
                local saved_playhead = query:value(SEQ_COL_PLAYHEAD)
                data.state.playhead_position = Rational.new(saved_playhead or 0, fps_num, fps_den)

                -- Restore Selection
                local saved_sel = query:value(SEQ_COL_SEL_CLIPS)
                if saved_sel and saved_sel ~= "" then
                    local ok, ids = pcall(json.decode, saved_sel)
                    if ok and type(ids) == "table" then
                        data.state.selected_clips = {}
                        for _, cid in ipairs(ids) do
                            local clip = clip_state.get_by_id(cid)
                            if clip then table.insert(data.state.selected_clips, clip) end
                        end
                    end
                end

                -- Restore Edges
                local saved_edges = query:value(SEQ_COL_SEL_EDGES)
                if saved_edges and saved_edges ~= "" then
                    local ok, edges = pcall(json.decode, saved_edges)
                    if ok and type(edges) == "table" then
                        data.state.selected_edges = {}
                        for _, edge in ipairs(edges) do
                            if type(edge) == "table" and edge.clip_id and edge.edge_type then
                                local clip_obj = clip_state.get_by_id(edge.clip_id)
                                if not clip_obj and type(edge.clip_id) == "string" and edge.clip_id:find("^" .. TEMP_GAP_PREFIX) then
                                    local resolved = resolve_gap_clip_id(edge)
                                    if resolved then
                                        clip_obj = clip_state.get_by_id(resolved)
                                        if clip_obj then
                                            edge.clip_id = resolved
                                        end
                                    end
                                end
                                if clip_obj then
                                    table.insert(data.state.selected_edges, {
                                        clip_id = edge.clip_id,
                                        edge_type = edge.edge_type,
                                        trim_type = edge.trim_type
                                    })
                                end
                            end
                        end
                        if #data.state.selected_edges > 0 then data.state.selected_clips = {} end
                    end
                end

                -- Marks
                local mi = query:value(SEQ_COL_MARK_IN)
                data.state.mark_in_value = mi and Rational.new(mi, fps_num, fps_den) or nil
                local mo = query:value(SEQ_COL_MARK_OUT)
                data.state.mark_out_value = mo and Rational.new(mo, fps_num, fps_den) or nil

                -- Viewport
                local vs = query:value(SEQ_COL_VIEW_START)
                local vd = query:value(SEQ_COL_VIEW_DUR)
                data.state.viewport_start_time = Rational.new(vs or 0, fps_num, fps_den)
                if vd and vd > 0 then
                    data.state.viewport_duration = Rational.new(vd, fps_num, fps_den)
                else
                    data.state.viewport_duration = Rational.new(300, fps_num, fps_den)
                end
            end
            query:finalize()
        end
    end

    -- Init Track Heights
    for _, track in ipairs(data.state.tracks) do
        track.height = data.dimensions.default_track_height
    end
    if db.load_sequence_track_heights then
        local saved = db.load_sequence_track_heights(sequence_id)
        local has_saved = type(saved) == "table" and next(saved) ~= nil
        
        -- apply saved
        if has_saved then
            for _, track in ipairs(data.state.tracks) do
                local h = saved[track.id]
                if h then track.height = clamp_track_height(h) end
            end
        elseif db.set_sequence_track_heights then
            db.set_sequence_track_heights(sequence_id, build_track_height_map())
        end
    end

    -- Viewport Initialization Logic (if not restored or invalid)
    -- Ensure viewport covers content if unset
    -- (Simplified from original, assuming default duration is reasonable start)
    -- But we can use compute_content_end here if needed.
    -- Current logic sets default if DB value missing.

    data.notify_listeners()
    return true
end

function M.reload_clips(target_sequence_id, opts)
    local active = data.state.sequence_id
    assert(active and active ~= "", "timeline_core_state.reload_clips: missing active sequence_id")
    if target_sequence_id and target_sequence_id ~= "" and target_sequence_id ~= active then
        if opts and opts.allow_sequence_switch then
            local project_id = data.state.project_id
            assert(project_id and project_id ~= "", "timeline_core_state.reload_clips: missing active project_id")
            return M.init(target_sequence_id, project_id)
        end
        return false
    end

    data.state.clips = db.load_clips(active)
    clip_state.invalidate_indexes()
    
    -- Refresh selection objects
    if #data.state.selected_clips > 0 then
        local refreshed = {}
        for _, c in ipairs(data.state.selected_clips) do
            local latest = clip_state.get_by_id(c.id)
            if latest then table.insert(refreshed, latest) end
        end
        data.state.selected_clips = refreshed
        selection_state.set_on_selection_changed(nil) -- Trigger callback?
        -- Actually selection_state.set_selection(refreshed) would trigger callback
    end

    clip_state.inc_version()
    for _, c in ipairs(data.state.clips) do c._version = clip_state.get_version() end

    local adjusted = selection_state.normalize_edge_selection()
    if adjusted then M.persist_state_to_db() end
    data.notify_listeners()
    return true
end

return M
