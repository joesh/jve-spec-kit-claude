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
-- Size: ~310 LOC
-- Volatility: unknown
--
-- @file timeline_core_state.lua
-- Original intent (unreviewed):
-- Timeline Core State
-- Initialization, Persistence, and Reloading logic
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")
local track_state = require("ui.timeline.state.track_state")
local selection_state = require("ui.timeline.state.selection_state")
local db = require("core.database")
local json = require("dkjson")
local ui_constants = require("core.ui_constants")
local command_manager = require("core.command_manager")
local Command = require("command")

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

local function flush_state_to_db()
    local sequence_id = data.state.sequence_id
    assert(sequence_id and sequence_id ~= "", "timeline_core_state.flush_state_to_db: missing sequence_id")

    local project_id = data.state.project_id
    assert(project_id and project_id ~= "", "timeline_core_state.flush_state_to_db: missing project_id")

    -- Skip persistence if command_manager is not initialized or undo/redo is in progress.
    -- This prevents recursive command execution during undo/redo operations and allows
    -- tests that don't initialize command_manager to still use timeline_state.
    local active_project = command_manager.get_active_project_id and command_manager.get_active_project_id()
    if not active_project or active_project == "" then
        return
    end
    if command_manager.is_undo_redo_in_progress and command_manager.is_undo_redo_in_progress() then
        return
    end

    -- Skip persistence if the sequence no longer exists in the database.
    -- This can happen after undo of an import - timeline_state has stale cached values
    -- for a deleted sequence. Persisting those would overwrite correct values when
    -- the sequence is recreated by redo.
    local Sequence = require("models.sequence")
    local sequence = Sequence.load(sequence_id)
    if not sequence then
        return
    end

    -- Begin command event context for UI-driven persistence.
    -- All persistence commands below are non-undoable "scriptable" commands,
    -- but they still require an active command event to execute.
    command_manager.begin_command_event("ui")

    -- Use pcall to ensure we always end the command event even if commands fail
    local ok, err = pcall(function()
        -- Persist playhead
    local playhead_cmd = Command.create("SetPlayhead", project_id)
    playhead_cmd:set_parameters({
        project_id = project_id,
        sequence_id = sequence_id,
        playhead_position = data.state.playhead_position,
    })
    command_manager.execute(playhead_cmd)

    -- Persist viewport
    local viewport_cmd = Command.create("SetViewport", project_id)
    viewport_cmd:set_parameters({
        project_id = project_id,
        sequence_id = sequence_id,
        viewport_start_time = data.state.viewport_start_time,
        viewport_duration = data.state.viewport_duration,
    })
    command_manager.execute(viewport_cmd)

    -- Persist marks
    local marks_cmd = Command.create("SetMarks", project_id)
    marks_cmd:set_parameters({
        project_id = project_id,
        sequence_id = sequence_id,
        mark_in = data.state.mark_in_value,
        mark_out = data.state.mark_out_value,
    })
    command_manager.execute(marks_cmd)

    -- Serialize and persist selection
    local selected_ids = {}
    for _, clip in ipairs(data.state.selected_clips) do
        table.insert(selected_ids, clip.id)
    end
    local success, json_str = pcall(json.encode, selected_ids)
    local selected_clip_ids_json = success and json_str or "[]"

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
    local selected_edge_infos_json = success_edges and edges_json or "[]"

    local selection_cmd = Command.create("SetSelection", project_id)
    selection_cmd:set_parameters({
        project_id = project_id,
        sequence_id = sequence_id,
        selected_clip_ids_json = selected_clip_ids_json,
        selected_edge_infos_json = selected_edge_infos_json,
    })
    command_manager.execute(selection_cmd)

    if track_state.is_layout_dirty() then
        local height_map = build_track_height_map()

        -- Persist track heights via command (scriptable, non-undoable)
        local heights_cmd = Command.create("SetTrackHeights", project_id)
        heights_cmd:set_parameter("project_id", project_id)
        heights_cmd:set_parameter("sequence_id", sequence_id)
        heights_cmd:set_parameter("track_heights", height_map)
        command_manager.execute(heights_cmd)

        -- Template persistence via command
        local template = build_track_height_template()
        if template then
            local template_cmd = Command.create("SetProjectSetting", project_id)
            template_cmd:set_parameter("project_id", project_id)
            template_cmd:set_parameter("key", TRACK_HEIGHT_TEMPLATE_KEY)
            template_cmd:set_parameter("value", template)
            command_manager.execute(template_cmd)
        end

        track_state.clear_layout_dirty()
    end
    end) -- end pcall

    -- Always end the command event, even if persistence failed
    command_manager.end_command_event()

    -- Re-raise any error that occurred during persistence
    if not ok then
        error(err)
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
    -- Persist pending state before switching to a DIFFERENT sequence.
    -- Skip persist if re-initializing the SAME sequence - our cached values may be stale
    -- (e.g., after undo deleted the sequence and redo recreated it with fresh values).
    local is_same_sequence = data.state.sequence_id == sequence_id
    if persist_dirty and not is_same_sequence then
        M.persist_state_to_db(true)
    end
    -- Clear dirty flag when switching or re-initializing - we're about to load fresh data
    persist_dirty = false

    assert(sequence_id and sequence_id ~= "", "timeline_core_state.init: sequence_id is required")
    data.state.sequence_id = sequence_id

    -- Load Data
    data.state.tracks = db.load_tracks(sequence_id)
    data.state.clips = db.load_clips(sequence_id)
    clip_state.invalidate_indexes()

    -- Load Sequence Settings using Sequence model
    local Sequence = require("models.sequence")
    local sequence = Sequence.load(sequence_id)
    assert(sequence, string.format("timeline_core_state.init: failed to load sequence_id=%s", tostring(sequence_id)))
    assert(sequence.project_id and sequence.project_id ~= "",
        string.format("timeline_core_state.init: sequence missing project_id (sequence_id=%s)", tostring(sequence_id)))

    if project_id and project_id ~= "" then
        assert(sequence.project_id == project_id, string.format(
            "timeline_core_state.init: provided project_id does not match sequence.project_id (sequence_id=%s, provided=%s, db=%s)",
            tostring(sequence_id), tostring(project_id), tostring(sequence.project_id)
        ))
    end

    data.state.project_id = sequence.project_id
    data.state.sequence_frame_rate = sequence.frame_rate

    assert(sequence.frame_rate.fps_numerator and sequence.frame_rate.fps_denominator,
        string.format("FATAL: Sequence %s has NULL frame rate in database", tostring(sequence_id)))

    -- Restore Playhead from sequence model
    data.state.playhead_position = sequence.playhead_position

    -- Restore Selection from sequence model (JSON strings)
    if sequence.selected_clip_ids_json and sequence.selected_clip_ids_json ~= "" then
        local ok, ids = pcall(json.decode, sequence.selected_clip_ids_json)
        if ok and type(ids) == "table" then
            data.state.selected_clips = {}
            for _, cid in ipairs(ids) do
                local clip = clip_state.get_by_id(cid)
                if clip then table.insert(data.state.selected_clips, clip) end
            end
        end
    end

    -- Restore Edges from sequence model (JSON strings)
    if sequence.selected_edge_infos_json and sequence.selected_edge_infos_json ~= "" then
        local ok, edges = pcall(json.decode, sequence.selected_edge_infos_json)
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

    -- Marks from sequence model
    data.state.mark_in_value = sequence.mark_in
    data.state.mark_out_value = sequence.mark_out

    -- Viewport from sequence model
    data.state.viewport_start_time = sequence.viewport_start_time
    data.state.viewport_duration = sequence.viewport_duration

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
