-- CommandManager: Manages command execution, sequencing, and replay
--
-- Constitutional requirements:
-- - Deterministic command execution and replay
-- - Sequence number management with integrity validation
-- - State hash tracking for constitutional compliance
-- - Performance optimization for batch operations
-- - Undo/redo functionality with state consistency

local M = {}

-- Database connection (set externally)
local db = nil

local profile_scope = require("core.profile_scope")
local event_log = require("core.event_log")
local command_scope = require("core.command_scope")
local frame_utils = require("core.frame_utils")
local json = require("dkjson")

-- State tracking
local last_sequence_number = 0
local current_state_hash = ""
local state_hash_cache = {}
local last_error_message = ""

-- Active context
local active_sequence_id = "default_sequence"
local active_project_id = "default_project"

local non_recording_commands = {
    SelectAll = true,
    DeselectAll = true,
    GoToStart = true,
    GoToEnd = true,
    GoToPrevEdit = true,
    GoToNextEdit = true,
    ActivateBrowserSelection = true,
    ToggleMaximizePanel = true,
    MatchFrame = true,
    RevealInFilesystem = true,
}

local command_event_listeners = {}

local function notify_command_event(event)
    if not event then
        return
    end
    for _, listener in ipairs(command_event_listeners) do
        local ok, err = pcall(listener, event)
        if not ok then
            print(string.format("WARNING: Command listener failed: %s", tostring(err)))
        end
    end
end

local GLOBAL_STACK_ID = "global"
local TIMELINE_STACK_PREFIX = "timeline:"

local undo_stack_states = {
    [GLOBAL_STACK_ID] = {
        current_sequence_number = nil,
        current_branch_path = {},
        sequence_id = nil,
        position_initialized = false,
    }
}

local active_stack_id = GLOBAL_STACK_ID
local current_sequence_number = undo_stack_states[GLOBAL_STACK_ID].current_sequence_number
local current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path

local multi_stack_enabled = false
if os and os.getenv then
    multi_stack_enabled = os.getenv("JVE_ENABLE_MULTI_STACK_UNDO") == "1"
end

local initialize_stack_position_from_db

-- Registry that callers can use to route commands to specific undo stacks.
local command_stack_resolvers = {}

local sequence_initial_state = {
    clips = {},
    media = {},
    master = {},
    timeline = {}
}

local function clone_clip_entry(clip)
    return {
        id = clip.id,
        project_id = clip.project_id,
        clip_kind = clip.clip_kind,
        name = clip.name,
        track_id = clip.track_id,
        media_id = clip.media_id,
        parent_clip_id = clip.parent_clip_id,
        owner_sequence_id = clip.owner_sequence_id,
        source_sequence_id = clip.source_sequence_id,
        start_value = clip.start_value,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        enabled = clip.enabled,
        offline = clip.offline
    }
end

local function clone_media_entry(media)
    return {
        id = media.id,
        project_id = media.project_id,
        file_path = media.file_path,
        name = media.name,
        duration = media.duration,
        frame_rate = media.frame_rate,
        width = media.width,
        height = media.height,
        audio_channels = media.audio_channels,
        codec = media.codec,
        created_at = media.created_at,
        modified_at = media.modified_at,
        metadata = media.metadata
    }
end

local function clone_list(source, cloner)
    local result = {}
    if source then
        for _, item in ipairs(source) do
            table.insert(result, cloner(item))
        end
    end
    return result
end

local function format_timecode_for_log(time_ms)
    local ok, formatted = pcall(frame_utils.format_timecode, time_ms or 0)
    if ok and formatted then
        return formatted
    end
    return tostring(time_ms or 0) .. "ms"
end

local function gather_master_initial_state(project_id)
    local master_state = {
        sequences = {},
        tracks = {},
        clips = {}
    }

    if not project_id then
        return master_state
    end

    local database = require('core.database')
    local conn = database.get_connection()
    if not conn then
        return master_state
    end

    local seq_query = conn:prepare([[ 
        SELECT id, project_id, name, kind, frame_rate, width, height,
               timecode_start_frame,
               playhead_value,
               selected_clip_ids, selected_edge_infos,
               viewport_start_value,
               viewport_duration_frames_value,
               mark_in_value,
               mark_out_value,
               current_sequence_number,
               audio_sample_rate
        FROM sequences
        WHERE project_id = ? AND kind != 'timeline'
    ]])

    local sequence_ids = {}
    if seq_query then
        seq_query:bind_value(1, project_id)
        if seq_query:exec() then
            while seq_query:next() do
                local seq = {
                    id = seq_query:value(0),
                    project_id = seq_query:value(1),
                    name = seq_query:value(2),
                    kind = seq_query:value(3),
                    frame_rate = tonumber(seq_query:value(4)) or 0,
                    width = tonumber(seq_query:value(5)) or 0,
                    height = tonumber(seq_query:value(6)) or 0,
                    timecode_start_frame = tonumber(seq_query:value(7)) or 0,
                    playhead_value = tonumber(seq_query:value(8)) or 0,
                    selected_clip_ids = seq_query:value(9),
                    selected_edge_infos = seq_query:value(10),
                    viewport_start_value = tonumber(seq_query:value(11)) or 0,
                    viewport_duration_frames_value = tonumber(seq_query:value(12)) or 10000,
                    mark_in_value = seq_query:value(13),
                    mark_out_value = seq_query:value(14),
                current_sequence_number = seq_query:value(15),
                audio_sample_rate = tonumber(seq_query:value(16))
            }
                table.insert(master_state.sequences, seq)
                table.insert(sequence_ids, seq.id)
            end
        end
        seq_query:finalize()
    end

    if #sequence_ids == 0 then
        return master_state
    end

    local track_query = conn:prepare([[ 
        SELECT id, sequence_id, name, track_type, track_index,
               enabled, locked, muted, soloed, volume, pan, timebase_type, timebase_rate
        FROM tracks
        WHERE sequence_id = ?
    ]])

    if track_query then
        for _, seq_id in ipairs(sequence_ids) do
            track_query:bind_value(1, seq_id)
            if track_query:exec() then
                while track_query:next() do
                    local track = {
                        id = track_query:value(0),
                        sequence_id = track_query:value(1),
                        name = track_query:value(2),
                        track_type = track_query:value(3),
                        track_index = tonumber(track_query:value(4)) or 0,
                        enabled = track_query:value(5) == 1 or track_query:value(5) == true,
                        locked = track_query:value(6) == 1 or track_query:value(6) == true,
                        muted = track_query:value(7) == 1 or track_query:value(7) == true,
                        soloed = track_query:value(8) == 1 or track_query:value(8) == true,
                        volume = tonumber(track_query:value(9)) or 1.0,
                        pan = tonumber(track_query:value(10)) or 0.0,
                        timebase_type = track_query:value(11),
                        timebase_rate = track_query:value(12)
                    }
                    table.insert(master_state.tracks, track)
                end
            end
            track_query:reset()
            track_query:clear_bindings()
        end
        track_query:finalize()
    end

    local seen_clip_ids = {}
    local master_clip_query = conn:prepare([[ 
        SELECT id, project_id, clip_kind, name, track_id, media_id,
               source_sequence_id, parent_clip_id, owner_sequence_id,
               timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
               fps_numerator, fps_denominator, enabled, offline
        FROM clips
        WHERE clip_kind = 'master' AND source_sequence_id = ?
    ]])

    local child_clip_query = conn:prepare([[ 
        SELECT id, project_id, clip_kind, name, track_id, media_id,
               source_sequence_id, parent_clip_id, owner_sequence_id,
               timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
               fps_numerator, fps_denominator, enabled, offline
        FROM clips
        WHERE owner_sequence_id = ?
    ]])

    if master_clip_query and child_clip_query then
        for _, seq_id in ipairs(sequence_ids) do
            master_clip_query:bind_value(1, seq_id)
            if master_clip_query:exec() then
                while master_clip_query:next() do
                    local clip = {
                        id = master_clip_query:value(0),
                        project_id = master_clip_query:value(1),
                        clip_kind = master_clip_query:value(2),
                        name = master_clip_query:value(3),
                        track_id = master_clip_query:value(4),
                        media_id = master_clip_query:value(5),
                        source_sequence_id = master_clip_query:value(6),
                        parent_clip_id = master_clip_query:value(7),
                        owner_sequence_id = master_clip_query:value(8) or seq_id,
                        timeline_start_frame = tonumber(master_clip_query:value(9)) or 0,
                        duration_frames = tonumber(master_clip_query:value(10)) or 0,
                        source_in_frame = tonumber(master_clip_query:value(11)) or 0,
                        source_out_frame = tonumber(master_clip_query:value(12)) or 0,
                        fps_numerator = master_clip_query:value(13),
                        fps_denominator = master_clip_query:value(14),
                        enabled = master_clip_query:value(15) == 1 or master_clip_query:value(15) == true,
                        offline = master_clip_query:value(16) == 1 or master_clip_query:value(16) == true
                    }
                    if not seen_clip_ids[clip.id] then
                        table.insert(master_state.clips, clip)
                        seen_clip_ids[clip.id] = true
                    end
                end
            end
            master_clip_query:reset()
            master_clip_query:clear_bindings()

            child_clip_query:bind_value(1, seq_id)
            if child_clip_query:exec() then
                while child_clip_query:next() do
                    local clip = {
                        id = child_clip_query:value(0),
                        project_id = child_clip_query:value(1),
                        clip_kind = child_clip_query:value(2),
                        name = child_clip_query:value(3),
                        track_id = child_clip_query:value(4),
                        media_id = child_clip_query:value(5),
                        source_sequence_id = child_clip_query:value(6),
                        parent_clip_id = child_clip_query:value(7),
                        owner_sequence_id = child_clip_query:value(8) or seq_id,
                        timeline_start_frame = tonumber(child_clip_query:value(9)) or 0,
                        duration_frames = tonumber(child_clip_query:value(10)) or 0,
                        source_in_frame = tonumber(child_clip_query:value(11)) or 0,
                        source_out_frame = tonumber(child_clip_query:value(12)) or 0,
                        fps_numerator = child_clip_query:value(13),
                        fps_denominator = child_clip_query:value(14),
                        enabled = child_clip_query:value(15) == 1 or child_clip_query:value(15) == true,
                        offline = child_clip_query:value(16) == 1 or child_clip_query:value(16) == true
                    }
                    if not seen_clip_ids[clip.id] then
                        table.insert(master_state.clips, clip)
                        seen_clip_ids[clip.id] = true
                    end
                end
            end
            child_clip_query:reset()
            child_clip_query:clear_bindings()
        end
        master_clip_query:finalize()
        child_clip_query:finalize()
    else
        if master_clip_query then
            master_clip_query:finalize()
        end
        if child_clip_query then
            child_clip_query:finalize()
        end
    end

    return master_state
end

local function cache_initial_state(sequence_id, project_id)
    local scope = profile_scope.begin("command_manager.cache_initial_state", {
        details_fn = function()
            return string.format("sequence=%s project=%s", tostring(sequence_id), tostring(project_id))
        end
    })
    local database = require('core.database')

    if project_id and not sequence_initial_state.timeline[project_id] then
        local initial_set = {}
        local ok, sequences = pcall(database.load_sequences, project_id)
        if ok and type(sequences) == "table" then
            for _, seq in ipairs(sequences) do
                if not seq.kind or seq.kind == "timeline" then
                    initial_set[seq.id] = true
                end
            end
        end
        sequence_initial_state.timeline[project_id] = initial_set
        if sequence_id and sequence_id ~= '' then
            initial_set[sequence_id] = true
        end
        for k in pairs(initial_set) do
        end
    end

    local initial_timelines = project_id and sequence_initial_state.timeline[project_id] or nil

    if sequence_id then
        local preexisting = initial_timelines and initial_timelines[sequence_id]
        if preexisting then
            if not sequence_initial_state.clips[sequence_id] then
                local ok, clips = pcall(database.load_clips, sequence_id)
                if ok and type(clips) == "table" then
                    sequence_initial_state.clips[sequence_id] = clone_list(clips, clone_clip_entry)
                else
                    sequence_initial_state.clips[sequence_id] = {}
                end
            end
        else
            -- Sequence did not exist at startup: always treat baseline as empty.
            sequence_initial_state.clips[sequence_id] = {}
        end
    end

    if project_id and not sequence_initial_state.media[project_id] then
        local ok, media_items = pcall(database.load_media)
        if ok and type(media_items) == "table" then
            local filtered = {}
            for _, media in ipairs(media_items) do
                if media.project_id == project_id then
                    table.insert(filtered, clone_media_entry(media))
                end
            end
            sequence_initial_state.media[project_id] = filtered
        else
            sequence_initial_state.media[project_id] = {}
        end
    end

    if project_id and not sequence_initial_state.master[project_id] then
        sequence_initial_state.master[project_id] = gather_master_initial_state(project_id)
    end
    scope:finish()
end

local function ensure_stack_state(stack_id)
    stack_id = stack_id or GLOBAL_STACK_ID
    local state = undo_stack_states[stack_id]
    if not state then
        state = {
            current_sequence_number = nil,
            current_branch_path = {},
            sequence_id = nil,
            position_initialized = false,
        }
        undo_stack_states[stack_id] = state
    end
    return state
end

local function apply_stack_state(stack_id)
    active_stack_id = stack_id or GLOBAL_STACK_ID
    local state = ensure_stack_state(active_stack_id)
    current_sequence_number = state.current_sequence_number
    current_branch_path = state.current_branch_path
    return state
end

local function set_active_stack(stack_id, opts)
    local state = apply_stack_state(stack_id)
    if opts and opts.sequence_id then
        state.sequence_id = opts.sequence_id
    end
    if state.sequence_id and not state.position_initialized then
        initialize_stack_position_from_db(stack_id, state.sequence_id)
    end
end

local function set_current_sequence_number(value)
    current_sequence_number = value
    local state = ensure_stack_state(active_stack_id)
    state.current_sequence_number = value
    state.position_initialized = true
end

local function find_latest_child_command(parent_sequence)
    if not db then
        return nil
    end

    local query = db:prepare([[ 
        SELECT sequence_number, command_type, command_args
        FROM commands
        WHERE parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0)
        ORDER BY sequence_number DESC
        LIMIT 1
    ]])

    if not query then
        return nil
    end

    query:bind_value(1, parent_sequence)
    query:bind_value(2, parent_sequence)

    local command = nil
    local ok = query:exec()
    if ok and query:next() then
        command = {
            sequence_number = query:value(0),
            command_type = query:value(1),
            command_args = query:value(2)
        }
        if command.command_args and command.command_args ~= "" then
            local success, params = pcall(qt_json_decode, command.command_args)
            if success and type(params) == "table" then
                command.parameters = params
            end
        end
        command.get_parameter = function(self, key)
            if not self.parameters then
                return nil
            end
            return self.parameters[key]
        end
    end
    query:finalize()
    return command
end

local function get_current_stack_id()
    return active_stack_id
end

local function get_current_stack_sequence_id(fallback_to_active_sequence)
    local state = ensure_stack_state(active_stack_id)
    if state.sequence_id and state.sequence_id ~= "" then
        return state.sequence_id
    end
    if fallback_to_active_sequence then
        return active_sequence_id
    end
    return nil
end

local function stack_id_for_sequence(sequence_id)
    if not sequence_id or sequence_id == "" then
        return GLOBAL_STACK_ID
    end
    return TIMELINE_STACK_PREFIX .. sequence_id
end

local function sequence_exists(sequence_id)
    if not db or not sequence_id or sequence_id == "" then
        return false
    end
    local stmt = db:prepare("SELECT 1 FROM sequences WHERE id = ? LIMIT 1")
    if not stmt then
        return false
    end
    stmt:bind_value(1, sequence_id)
    local exists = stmt:exec() and stmt:next()
    stmt:finalize()
    return exists
end

local function invalidate_sequence_stack(sequence_id)
    if not sequence_id or sequence_id == "" then
        return
    end
    local stack_id = stack_id_for_sequence(sequence_id)
    local state = undo_stack_states[stack_id]
    if state then
        state.current_sequence_number = nil
        state.current_branch_path = {}
        state.position_initialized = false
        state.sequence_id = nil
    end
end

local function extract_sequence_id(command)
    if not command then
        return nil
    end

    if command.get_parameter then
        local value = command:get_parameter("sequence_id")
        if value and value ~= "" then
            return value
        end
    end

    if command.parameters and command.parameters.sequence_id and command.parameters.sequence_id ~= "" then
        return command.parameters.sequence_id
    end

    return nil
end

local function resolve_stack_for_command(command)
    if not multi_stack_enabled then
        return GLOBAL_STACK_ID, nil
    end

    if command.stack_id then
        if type(command.stack_id) == "string" then
            return command.stack_id, nil
        elseif type(command.stack_id) == "table" then
            return command.stack_id.stack_id or GLOBAL_STACK_ID, command.stack_id
        end
    end

    local resolver = command_stack_resolvers[command.type]
    if resolver then
        local ok, stack_info = pcall(resolver, command)
        if ok and stack_info then
            if type(stack_info) == "string" then
                return stack_info, nil
            elseif type(stack_info) == "table" then
                return stack_info.stack_id or GLOBAL_STACK_ID, stack_info
            end
        elseif not ok then
            print(string.format("WARNING: stack resolver for %s threw error: %s",
                command.type, tostring(stack_info)))
        end
    end

    if command.get_parameter then
        local sequence_param = command:get_parameter("sequence_id")
        if sequence_param and sequence_param ~= "" then
            return stack_id_for_sequence(sequence_param), {sequence_id = sequence_param}
        end
    end

    return GLOBAL_STACK_ID, nil
end

local function select_fallback_sequence(exclude_lookup)
    exclude_lookup = exclude_lookup or {}
    if sequence_exists("default_sequence") and not exclude_lookup["default_sequence"] then
        return "default_sequence"
    end
    if not db then
        return nil
    end
    local stmt = db:prepare("SELECT id FROM sequences LIMIT 1")
    if not stmt then
        return nil
    end
    local fallback = nil
    if stmt:exec() and stmt:next() then
        local candidate = stmt:value(0)
        if candidate and candidate ~= "" and not exclude_lookup[candidate] then
            fallback = candidate
        end
    end
    stmt:finalize()
    return fallback
end

local function ensure_active_project_id()
    if not active_project_id or active_project_id == "" then
        error("CommandManager.execute: active project_id is not set")
    end
    return active_project_id
end

local function normalize_command(command_or_name, params)
    local Command = require('command')

    if type(command_or_name) == "string" then
        local project_id = ensure_active_project_id()
        local command = Command.create(command_or_name, project_id)

        if params then
            for key, value in pairs(params) do
                command:set_parameter(key, value)
            end
        end

        local param_project_id = command:get_parameter("project_id")
        if param_project_id and param_project_id ~= "" then
            command.project_id = param_project_id
        else
            command:set_parameter("project_id", project_id)
            command.project_id = project_id
        end

        return command
    elseif type(command_or_name) == "table" then
        local command = command_or_name

        local mt = getmetatable(command)
        if not mt or mt.__index ~= Command then
            setmetatable(command, {__index = Command})
        end

        local param_project_id = nil
        if command.get_parameter then
            param_project_id = command:get_parameter("project_id")
        elseif command.parameters then
            param_project_id = command.parameters.project_id
        end

        if not command.project_id or command.project_id == "" then
            if param_project_id and param_project_id ~= "" then
                command.project_id = param_project_id
            else
                command.project_id = ensure_active_project_id()
            end
        end

        if command.get_parameter then
            if not param_project_id or param_project_id == "" then
                command:set_parameter("project_id", command.project_id)
            end
        elseif command.parameters then
            command.parameters.project_id = command.project_id
        end

        return command
    else
        error(string.format("CommandManager.execute: Unsupported command argument type '%s'", type(command_or_name)))
    end
end

local function normalize_executor_result(exec_result)
    if exec_result == nil then
        return false, ""
    end

    if type(exec_result) == "table" then
        local success_field = exec_result.success
        if success_field == nil then
            success_field = true
        end
        local error_message = exec_result.error_message or ""
        local result_data = exec_result.result_data or ""
        return success_field ~= false, error_message, result_data
    end

    return exec_result ~= false, ""
end

-- Command type implementations
local command_executors = {}
local command_undoers = {}
local command_redoers = {}

-- Auto-loading logic for commands
local function load_command_module(command_type)
    -- Convert CamelCase to snake_case for file path
    local filename = command_type:gsub("%u", function(c) return "_" .. c:lower() end):sub(2)
    local module_path = "core.commands." .. filename
    
    local status, mod = pcall(require, module_path)
    if status and type(mod) == "table" and mod.register then
        local registered = mod.register(command_executors, command_undoers, db, M.set_last_error)
        if registered and registered.executor then
            M.register_executor(command_type, registered.executor, registered.undoer)
            return true
        end
    end
    return false
end

local function capture_selection_snapshot()
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
            table.insert(edge_descriptors, {
                clip_id = edge.clip_id,
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



local function ensure_command_selection_columns()
    if not db then
        return
    end

    local pragma = db:prepare("PRAGMA table_info(commands)")
    if not pragma then
        return
    end

    local has_clip_pre = false
    local has_edge_pre = false
    local has_gap = false
    local has_gap_pre = false

    if pragma:exec() then
        while pragma:next() do
            local column_name = pragma:value(1)
            if column_name == "selected_clip_ids_pre" then
                has_clip_pre = true
            elseif column_name == "selected_edge_infos_pre" then
                has_edge_pre = true
            elseif column_name == "selected_gap_infos" then
                has_gap = true
            elseif column_name == "selected_gap_infos_pre" then
                has_gap_pre = true
            end
        end
    end

    pragma:finalize()

    if not has_clip_pre then
        local ok, err = db:exec("ALTER TABLE commands ADD COLUMN selected_clip_ids_pre TEXT DEFAULT '[]'")
        if not ok then
            print("WARNING: Failed to add selected_clip_ids_pre column: " .. tostring(err or "unknown error"))
        end
    end

    if not has_edge_pre then
        local ok, err = db:exec("ALTER TABLE commands ADD COLUMN selected_edge_infos_pre TEXT DEFAULT '[]'")
        if not ok then
            print("WARNING: Failed to add selected_edge_infos_pre column: " .. tostring(err or "unknown error"))
        end
    end

    if not has_gap then
        local ok, err = db:exec("ALTER TABLE commands ADD COLUMN selected_gap_infos TEXT DEFAULT '[]'")
        if not ok then
            print("WARNING: Failed to add selected_gap_infos column: " .. tostring(err or "unknown error"))
        end
    end

    if not has_gap_pre then
        local ok, err = db:exec("ALTER TABLE commands ADD COLUMN selected_gap_infos_pre TEXT DEFAULT '[]'")
        if not ok then
            print("WARNING: Failed to add selected_gap_infos_pre column: " .. tostring(err or "unknown error"))
        end
    end
end

local function capture_pre_selection_for_command(command)
    local scope = profile_scope.begin("command_manager.capture_selection_pre")
    local clips_json, edges_json, gaps_json = capture_selection_snapshot()
    command.selected_clip_ids_pre = clips_json
    command.selected_edge_infos_pre = edges_json
    command.selected_gap_infos_pre = gaps_json
    scope:finish()
end

local function capture_post_selection_for_command(command)
    local scope = profile_scope.begin("command_manager.capture_selection_post")
    local clips_json, edges_json, gaps_json = capture_selection_snapshot()
    command.selected_clip_ids = clips_json
    command.selected_edge_infos = edges_json
    command.selected_gap_infos = gaps_json
    scope:finish()
end

local function restore_selection_from_serialized(clips_json, edges_json, gaps_json)
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
                local clip = safe_load_clip(info.clip_id)
                if clip then
                    table.insert(restored_edges, {
                        clip_id = info.clip_id,
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

local function command_flag(command, property, param_key)
    if command[property] ~= nil then
        return command[property] and true or false
    end
    if command.get_parameter and param_key then
        local value = command:get_parameter(param_key)
        if value ~= nil then
            return value and true or false
        end
    end
    return false
end

local function sequence_exists(sequence_id)
    if not db or not sequence_id or sequence_id == "" then
        return false
    end
    local query = db:prepare("SELECT 1 FROM sequences WHERE id = ? LIMIT 1")
    if not query then
        return false
    end
    query:bind_value(1, sequence_id)
    local exists = query:exec() and query:next()
    query:finalize()
    return exists
end

local function fetch_first_timeline_sequence(project_id)
    if not db or not project_id or project_id == "" then
        return nil
    end
    local query = db:prepare([[ 
        SELECT id FROM sequences
        WHERE project_id = ? AND kind = 'timeline'
        ORDER BY name LIMIT 1
    ]])
    if not query then
        return nil
    end
    query:bind_value(1, project_id)
    local sequence_id = nil
    if query:exec() and query:next() then
        sequence_id = query:value(0)
    end
    query:finalize()
    return sequence_id
end

function M.set_last_error(message)
    if type(message) == "string" and message ~= "" then
        last_error_message = message
    else
        last_error_message = ""
    end
end

function M.shutdown()
    db = nil
    last_sequence_number = 0
    current_sequence_number = nil
    active_sequence_id = "default_sequence"
    active_project_id = "default_project"
    current_state_hash = ""
    state_hash_cache = {}
    last_error_message = ""
    undo_stack_states = {
        [GLOBAL_STACK_ID] = {
            current_sequence_number = nil,
            current_branch_path = {},
            sequence_id = nil,
            position_initialized = false,
        }
    }
    active_stack_id = GLOBAL_STACK_ID
    command_executors = {}
    command_undoers = {}
    sequence_initial_state = {
        clips = {},
        media = {},
        master = {},
        timeline = {}
    }
end

-- Initialize CommandManager with database connection
function M.init(database, sequence_id, project_id)
    db = database
    active_sequence_id = sequence_id or "default_sequence"
    active_project_id = project_id or "default_project"

    undo_stack_states = {
        [GLOBAL_STACK_ID] = {
            current_sequence_number = nil,
            current_branch_path = {},
            sequence_id = nil,
            position_initialized = false,
        }
    }
    active_stack_id = GLOBAL_STACK_ID
    current_sequence_number = nil
    current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path

    ensure_command_selection_columns()

    -- Query last sequence number from database
    local query = db:prepare("SELECT MAX(sequence_number) FROM commands")
    if query then
        if query:exec() and query:next() then
            last_sequence_number = query:value(0) or 0
        end
        query:finalize()
    end

    local global_state = ensure_stack_state(GLOBAL_STACK_ID)
    global_state.sequence_id = active_sequence_id
    set_active_stack(GLOBAL_STACK_ID, {sequence_id = active_sequence_id})

    -- Commands are now auto-loaded via load_command_module when executed.
    -- Legacy explicit registration loop removed.

    print(string.format("CommandManager initialized, last sequence: %d, current position: %s",
        last_sequence_number, tostring(current_sequence_number)))

    cache_initial_state(active_sequence_id, active_project_id)

    -- Validate and repair broken parent chains (defensive data integrity check)
    -- DISABLED: repair_broken_parent_chains()
    -- TODO: Enable after verifying all bugs are fixed and understanding root causes
end

-- Repair commands with NULL parent_sequence_number (except the first command)
-- This fixes data corruption from earlier bugs where init() mishandled NULL positions
local function repair_broken_parent_chains()
    if not db then
        return
    end

    -- Find all commands with NULL parent except sequence 1
    local find_query = db:prepare([[ 
        SELECT sequence_number
        FROM commands
        WHERE parent_sequence_number IS NULL
        AND sequence_number > 1
        ORDER BY sequence_number
    ]])

    if not find_query or not find_query:exec() then
        if find_query then find_query:finalize() end
        return
    end

    local broken_commands = {}
    while find_query:next() do
        table.insert(broken_commands, find_query:value(0))
    end
    find_query:finalize()

    if #broken_commands == 0 then
        return  -- No repairs needed
    end

    print(string.format("⚠️  Found %d command(s) with NULL parent - repairing command chain...", #broken_commands))

    -- For each broken command, set parent to sequence_number - 1
    for _, seq_num in ipairs(broken_commands) do
        local expected_parent = seq_num - 1

        -- Verify the expected parent exists
        local verify_query = db:prepare("SELECT 1 FROM commands WHERE sequence_number = ?")
        if verify_query then
            verify_query:bind_value(1, expected_parent)
            if verify_query:exec() and verify_query:next() then
                -- Parent exists, repair the link
                local update_query = db:prepare([[ 
                    UPDATE commands
                    SET parent_sequence_number = ?
                    WHERE sequence_number = ?
                ]])

                if update_query then
                    update_query:bind_value(1, expected_parent)
                    update_query:bind_value(2, seq_num)
                    if update_query:exec() then
                        print(string.format("  ✅ Repaired command %d: set parent to %d", seq_num, expected_parent))
                    else
                        print(string.format("  ❌ Failed to repair command %d", seq_num))
                    end
                    update_query:finalize()
                end
            else
                print(string.format("  ⚠️  Command %d has no predecessor - cannot repair", seq_num))
            end
            verify_query:finalize()
        end
    end

    print("✅ Command chain repair complete")
end

-- Get next sequence number
local function get_next_sequence_number()
    last_sequence_number = last_sequence_number + 1
    print(string.format("DEBUG: Assigned sequence number %d (current=%s)",
        last_sequence_number, tostring(current_sequence_number)))
    return last_sequence_number
end

-- Save current undo position to database (persists across sessions)
local function save_undo_position()
    if not db then
        return false
    end

    local sequence_id = get_current_stack_sequence_id(true)
    if not sequence_id or sequence_id == "" then
        return false
    end

    local update = db:prepare([[ 
        UPDATE sequences
        SET current_sequence_number = ?
        WHERE id = ?
    ]])

    if not update then
        print("WARNING: Failed to prepare undo position update")
        return false
    end

    local stored_position = current_sequence_number
    if stored_position == nil then
        stored_position = 0
    end
    update:bind_value(1, stored_position)
    update:bind_value(2, sequence_id)
    local success = update:exec()
    update:finalize()

    if not success then
        print("WARNING: Failed to save undo position to database")
        return false
    end

    return true
end

local function load_sequence_undo_position(sequence_id)
    if not db or not sequence_id or sequence_id == "" then
        return nil, false
    end

    local query = db:prepare([[ 
        SELECT current_sequence_number
        FROM sequences
        WHERE id = ?
    ]])

    if not query then
        return nil, false
    end

    query:bind_value(1, sequence_id)
    local has_row = false
    local value = nil
    if query:exec() and query:next() then
        has_row = true
        value = query:value(0)
    end
    query:finalize()
    return value, has_row
end

initialize_stack_position_from_db = function(stack_id, sequence_id)
    if not sequence_id or sequence_id == "" then
        return
    end

    local saved_value, has_row = load_sequence_undo_position(sequence_id)
    local state = ensure_stack_state(stack_id)

    if saved_value and saved_value > 0 then
        set_current_sequence_number(saved_value)
    elseif saved_value == 0 then
        set_current_sequence_number(nil)
    elseif has_row then
        if last_sequence_number > 0 then
            set_current_sequence_number(last_sequence_number)
        else
            set_current_sequence_number(nil)
        end
    else
        set_current_sequence_number(nil)
    end

    state.position_initialized = true
end

-- Calculate state hash for a project
local function calculate_state_hash(project_id)
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

-- Validate command parameters
local function validate_command_parameters(command)
    if not command.type or command.type == "" then
        return false
    end

    if not command.project_id or command.project_id == "" then
        return false
    end

    return true
end

-- Update command hashes
local function update_command_hashes(command, pre_hash)
    command.pre_hash = pre_hash
end

-- Load commands from sequence number
local function mutation_summary_string(mutations)
    if not mutations then
        return "none"
    end
    local function collect_buckets(source)
        if not source then
            return {}
        end
        if source.sequence_id or source.inserts or source.updates or source.deletes then
            return {source}
        end
        local buckets = {}
        for _, bucket in pairs(source) do
            if type(bucket) == "table" and (bucket.sequence_id or bucket.inserts or bucket.updates or bucket.deletes) then
                table.insert(buckets, bucket)
            end
        end
        return buckets
    end

    local buckets = collect_buckets(mutations)
    if #buckets == 0 then
        return "empty"
    end
    local parts = {}
    for _, bucket in ipairs(buckets) do
        local inserts = (bucket.inserts and #bucket.inserts) or 0
        local updates = (bucket.updates and #bucket.updates) or 0
        local deletes = (bucket.deletes and #bucket.deletes) or 0
        table.insert(parts, string.format("%s:ins=%d upd=%d del=%d", tostring(bucket.sequence_id or "nil"), inserts, updates, deletes))
    end
    return table.concat(parts, "; ")
end

local function load_commands_from_sequence(start_sequence)
    -- Get project ID from projects table
    local project_id = nil
    local project_query = db:prepare("SELECT id FROM projects LIMIT 1")
    if project_query:exec() and project_query:next() then
        project_id = project_query:value(0)
    end

    local query = db:prepare("SELECT * FROM commands WHERE sequence_number >= ? ORDER BY sequence_number")
    query:bind_value(1, start_sequence)

    local commands = {}
    if query:exec() then
        while query:next() do
            local command = require('command').parse_from_query(query, project_id)
            if command and command.id ~= "" then
                table.insert(commands, command)
            end
        end
    end
    query:finalize()

    return commands
end

-- Execute command implementation (routes to specific handlers)
local function execute_command_implementation(command)
    local scope = profile_scope.begin("command_manager.exec_impl", {
        details_fn = function() 
            return string.format("command=%s status=%s", command and command.type or "unknown", tostring(last_error_message == "" and "ok" or "error"))
        end
    })

    local executor = command_executors[command.type]
    
    if not executor then
        -- Attempt auto-load
        load_command_module(command.type)
        executor = command_executors[command.type]
    end

    if executor then
        local success, result = pcall(executor, command)
        if not success then
            print(string.format("ERROR: Executor failed: %s", tostring(result)))
            last_error_message = tostring(result)
            scope:finish("executor_error")
            return false
        end
        scope:finish(result and "executor_success" or "executor_false")
        return result
    elseif command.type == "FastOperation" or
           command.type == "BatchOperation" or
           command.type == "ComplexOperation" then
        scope:finish("test_command")
        return true
    else
        local error_msg = string.format("Unknown command type: %s", command.type)
        print("ERROR: " .. error_msg)
        last_error_message = error_msg
        scope:finish("unknown_command")
        return false
    end
end

local function execute_non_recording(command)
    local ok, exec_result = pcall(execute_command_implementation, command)
    if not ok then
        return {
            success = false,
            error_message = tostring(exec_result),
            result_data = ""
        }
    end

    local success, error_message, result_data = normalize_executor_result(exec_result)
    if not success then
        if error_message == "" then
            error_message = last_error_message ~= "" and last_error_message or "Command execution failed"
        end
        last_error_message = ""
        return {
            success = false,
            error_message = error_message,
            result_data = result_data or ""
        }
    end

    last_error_message = ""
    return {
        success = true,
        error_message = "",
        result_data = result_data or ""
    }
end

-- Main execute function
function M.execute(command_or_name, params)
    local command
    local ok, normalize_err = pcall(function()
        command = normalize_command(command_or_name, params)
    end)
    if not ok then
        return {
            success = false,
            error_message = tostring(normalize_err),
            result_data = ""
        }
    end

    local exec_scope = profile_scope.begin("command_manager.execute", {
        details_fn = function() 
            return string.format("command=%s", command and command.type or tostring(command_or_name))
        end
    })
    local result = {
        success = false,
        error_message = "",
        result_data = ""
    }

    if not validate_command_parameters(command) then
        result.error_message = "Invalid command parameters"
        exec_scope:finish("invalid_params")
        return result
    end

    local scope_ok, scope_err = command_scope.check(command)
    if not scope_ok then
        result.error_message = scope_err or "Command cannot execute in current scope"
        exec_scope:finish("scope_violation")
        return result
    end

    if non_recording_commands[command.type] then
        local non_record_result = execute_non_recording(command)
        exec_scope:finish("non_recording")
        return non_record_result
    end

    local stack_id, stack_info = resolve_stack_for_command(command)
    local stack_opts = nil
    if stack_info and type(stack_info) == "table" and stack_info.sequence_id then
        stack_opts = {sequence_id = stack_info.sequence_id}
    end
    if not stack_opts or not stack_opts.sequence_id then
        local seq_param = extract_sequence_id(command)
        if seq_param and seq_param ~= "" then
            stack_opts = stack_opts or {}
            stack_opts.sequence_id = seq_param
        end
    end
    set_active_stack(stack_id, stack_opts)
    command.stack_id = stack_id

    local active_sequence = get_current_stack_sequence_id(true)
    local skip_timeline_cache = command_flag(command, "skip_timeline_cache", "__skip_timeline_cache")
    if not skip_timeline_cache then
        cache_initial_state(active_sequence, command.project_id or active_project_id)
    end

    -- BEGIN TRANSACTION: All database changes (command save + state changes) are atomic
    -- If anything fails, everything rolls back automatically
    local begin_tx = db:prepare("BEGIN TRANSACTION")
    if not (begin_tx and begin_tx:exec()) then
        if begin_tx then begin_tx:finalize() end
        result.error_message = "Failed to begin transaction"
        exec_scope:finish("begin_tx_failed")
        return result
    end
    begin_tx:finalize()

    -- Calculate pre-execution state hash
    local pre_hash = calculate_state_hash(command.project_id)

    -- Assign sequence number
    local sequence_number = get_next_sequence_number()
    command.sequence_number = sequence_number

    -- Set parent_sequence_number for undo tree
    -- This creates branches when executing after undo
    command.parent_sequence_number = current_sequence_number

    -- VALIDATION: parent_sequence_number should never be NULL after first command
    -- NULL parent is only valid for the very first command (sequence 1)
    if not command.parent_sequence_number then
        local executing_from_root = current_sequence_number == nil
        if not executing_from_root and sequence_number > 1 then
            print(string.format("ERROR: Command %d has NULL parent but is not the first command!", sequence_number))
            print(string.format("ERROR: current_sequence_number = %s, last_sequence_number = %d",
                tostring(current_sequence_number), last_sequence_number))
            print("ERROR: This indicates a bug in undo position tracking!")
            local rollback_tx = db:prepare("ROLLBACK")
            if rollback_tx then 
                rollback_tx:exec()
                rollback_tx:finalize()
            end
            last_sequence_number = last_sequence_number - 1
            result.error_message = "FATAL: Cannot execute command with NULL parent (would break undo tree)"
            exec_scope:finish("null_parent")
            return result
        end
    end

    -- VALIDATION: If parent exists, verify it actually exists in database
    if command.parent_sequence_number then
        local verify_parent = db:prepare("SELECT 1 FROM commands WHERE sequence_number = ?")
        if verify_parent then
            verify_parent:bind_value(1, command.parent_sequence_number)
            if not (verify_parent:exec() and verify_parent:next()) then
                verify_parent:finalize()
                print(string.format("ERROR: Command %d references non-existent parent %d!",
                    sequence_number, command.parent_sequence_number))
                print("ERROR: Parent command was deleted or never existed - broken referential integrity")
                local rollback_tx = db:prepare("ROLLBACK")
                if rollback_tx then 
                    rollback_tx:exec()
                    rollback_tx:finalize()
                end
                last_sequence_number = last_sequence_number - 1
                result.error_message = "FATAL: Cannot execute command with non-existent parent (would break undo tree)"
                exec_scope:finish("missing_parent")
                return result
            end
            verify_parent:finalize()
        end
    end

    -- Update command with state hashes
    update_command_hashes(command, pre_hash)

    -- Capture playhead and selection state BEFORE command execution (pre-state model)
    local timeline_state = require('ui.timeline.timeline_state')
    command.playhead_value = timeline_state.get_playhead_position()
    command.playhead_rate = timeline_state.get_sequence_frame_rate()
    local skip_selection_snapshot = command_flag(command, "skip_selection_snapshot", "__skip_selection_snapshot")
    if not skip_selection_snapshot then
        capture_pre_selection_for_command(command)
    end

    -- Execute the actual command logic
    local execution_success = execute_command_implementation(command)

    if execution_success then
        command.status = "Executed"
        command.executed_at = os.time()

        if not skip_selection_snapshot then
            capture_post_selection_for_command(command)
        end

        -- Calculate post-execution hash
        local post_hash = calculate_state_hash(command.project_id)
        command.post_hash = post_hash

        -- Detect no-op commands (state hash unchanged); suppress undo entry
        local suppress_noop = command_flag(command, "suppress_if_unchanged", "__suppress_if_unchanged")
        if suppress_noop and post_hash == pre_hash then
            local rollback_tx = db:prepare("ROLLBACK")
            if rollback_tx then 
                rollback_tx:exec()
                rollback_tx:finalize()
            end
            last_sequence_number = last_sequence_number - 1
            current_state_hash = pre_hash
            result.success = true
            result.result_data = ""
            exec_scope:finish("no_state_change")
            return result
        end

        -- Save command to database
        local save_scope = profile_scope.begin("command_manager.command_save")
        local saved = command:save(db)
        save_scope:finish()
        if saved then
            local event_context = {
                sequence_number = sequence_number,
                stack_id = stack_id,
                sequence_id = active_sequence,
                project_id = command.project_id or active_project_id,
                scope = nil,
            }
            local event_scope = profile_scope.begin("command_manager.event_log")
            local record_ok, record_err = event_log.record_command(command, event_context)
            event_scope:finish()
            if not record_ok then
                print("ERROR: Failed to append event log entry: " .. tostring(record_err))
                local rollback_tx = db:prepare("ROLLBACK")
                if rollback_tx then 
                    rollback_tx:exec()
                    rollback_tx:finalize()
                end
                last_sequence_number = last_sequence_number - 1
                result.success = false
                result.error_message = "Failed to append event log entry"
                exec_scope:finish("event_log_failure")
                return result
            end

            result.success = true
            result.result_data = command:serialize()
            current_state_hash = post_hash

            -- Move to HEAD after executing new command
            set_current_sequence_number(sequence_number)

            -- Save undo position to database (persists across sessions)
            save_undo_position()

            -- Create snapshot every N commands for fast event replay
            local snapshot_mgr = require('core.snapshot_manager')
            local force_snapshot = command_flag(command, "force_snapshot", "__force_snapshot")
            local snapshot_targets = command:get_parameter("__snapshot_sequence_ids")
            if type(snapshot_targets) ~= "table" or #snapshot_targets == 0 then
                snapshot_targets = {}
                local default_sequence_id = get_current_stack_sequence_id(true)
                if default_sequence_id then
                    table.insert(snapshot_targets, default_sequence_id)
                end
            end

            if #snapshot_targets > 0 and (force_snapshot or snapshot_mgr.should_snapshot(sequence_number)) then
                local snapshot_scope = profile_scope.begin("command_manager.snapshot", {
                    details_fn = function() 
                        return string.format("targets=%d", #snapshot_targets)
                    end
                })
                local db_module = require('core.database')
                for _, seq_id in ipairs(snapshot_targets) do
                    local clips = db_module.load_clips(seq_id)
                    snapshot_mgr.create_snapshot(db, seq_id, sequence_number, clips)
                end
                snapshot_scope:finish()
            end

            -- COMMIT TRANSACTION: Everything succeeded
            local commit_scope = profile_scope.begin("command_manager.commit_tx")
            local commit_tx = db:prepare("COMMIT")
            if commit_tx then 
                commit_tx:exec()
                commit_tx:finalize()
            end
            commit_scope:finish()

            -- Reload timeline state to pick up database changes
            -- This triggers listener notifications → automatic view redraws
            local skip_timeline_reload = command_flag(command, "skip_timeline_reload", "__skip_timeline_reload")
            if not skip_timeline_reload then
                local reload_sequence_id = extract_sequence_id(command)
                local applied_mutations = false
                local mutations = command:get_parameter("__timeline_mutations")
                local mutation_debug_summary = nil
                if mutations and timeline_state.apply_mutations then
                    local mutation_scope = profile_scope.begin("command_manager.apply_mutations")
                    local function apply_mutation_bucket(bucket)
                        if not bucket then
                            return false
                        end
                        local target_sequence = bucket.sequence_id or reload_sequence_id
                        return timeline_state.apply_mutations(target_sequence, bucket)
                    end

                    if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
                        applied_mutations = apply_mutation_bucket(mutations)
                    else
                        for _, bucket in pairs(mutations) do
                            if apply_mutation_bucket(bucket) then
                                applied_mutations = true
                            end
                        end
                    end
                    local ok_summary, summary = pcall(mutation_summary_string, mutations)
                    if ok_summary then
                        mutation_debug_summary = summary
                    else
                        print(string.format("WARNING: Failed to summarize mutations for %s: %s", tostring(command.type), tostring(summary)))
                        mutation_debug_summary = nil
                    end
                    command:clear_parameter("__timeline_mutations")
                    mutation_scope:finish(string.format("applied=%s", tostring(applied_mutations)))
                end
                local mutation_failure_info = nil
                if timeline_state.consume_mutation_failure then
                    mutation_failure_info = timeline_state.consume_mutation_failure()
                end
                if mutation_failure_info and not applied_mutations then
                    local context = mutation_failure_info.context or {}
                    if mutation_failure_info.kind == "sequence_mismatch" then
                        applied_mutations = true
                        print(string.format(
                            "Timeline mutation skipped for inactive sequence %s (active=%s)",
                            tostring(context.requested_sequence or "unknown"),
                            tostring(context.active_sequence or "unknown")))
                    elseif mutation_failure_info.kind == "inactive_timeline_state" then
                        applied_mutations = true
                        print(string.format(
                            "Timeline mutation skipped (timeline_state not initialized for sequence %s)",
                            tostring(context.requested_sequence or "unknown")))
                    else
                        local keys = context.update_keys and table.concat(context.update_keys, ", ") or "n/a"
                        print(string.format(
                            "Timeline mutation failure (%s): clip=%s keys=[%s] idx=%s/%s",
                            tostring(mutation_failure_info.kind),
                            tostring(context.clip_id or "unknown"),
                            keys,
                            tostring(context.update_index or "?"),
                            tostring(context.total_updates or "?")))
                        if mutation_failure_info.stack then
                            print(mutation_failure_info.stack)
                        end
                    end
                end
                if not applied_mutations then
                    local allow_empty = command_flag(command, "allow_empty_mutations", "__allow_empty_mutations")
                    if allow_empty and mutations then
                        applied_mutations = true
                    end
                end

                if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
                    local fallback_command_type = (command and command.type) or (command and command.command_type) or "unknown"
                    local active_sequence = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or "unknown"
                    print(string.format(
                        "Timeline reload fallback for %s (command=%s, active=%s, mutations=%s, failure=%s)",
                        tostring(reload_sequence_id),
                        tostring(fallback_command_type),
                        tostring(active_sequence),
                        mutation_debug_summary or "none",
                        mutation_failure_info and mutation_failure_info.kind or "none"))
                    local reload_scope = profile_scope.begin("command_manager.reload_clips")
                    timeline_state.reload_clips(reload_sequence_id)
                    reload_scope:finish()
                end
            end

            local notify_scope = profile_scope.begin("command_manager.notify_listeners")
            notify_command_event({
                event = "execute",
                command = command,
                project_id = command.project_id,
                stack_id = stack_id,
                sequence_number = sequence_number
            })
            notify_scope:finish()
        else
            result.error_message = "Failed to save command to database"
            -- ROLLBACK: Command execution succeeded but save failed
            local rollback_tx = db:prepare("ROLLBACK")
            if rollback_tx then 
                rollback_tx:exec()
                rollback_tx:finalize()
            end
            last_sequence_number = last_sequence_number - 1  -- Revert sequence number
        end
    else
        command.status = "Failed"
        result.error_message = last_error_message ~= "" and last_error_message or "Command execution failed"
        last_error_message = ""
        -- ROLLBACK: Command execution failed
        local rollback_tx = db:prepare("ROLLBACK")
        if rollback_tx then 
            rollback_tx:exec()
            rollback_tx:finalize()
        end
        last_sequence_number = last_sequence_number - 1  -- Revert sequence number
    end

    exec_scope:finish(result.success and "success" or "failure")
    return result
end

-- Get last executed command (at current position in undo tree)
function M.get_last_command(project_id)
    if not db then
        print("WARNING: No database connection")
        return nil
    end

    -- If current_sequence_number is nil, we're before all commands (fully undone)
    if not current_sequence_number then
        return nil  -- Nothing to undo
    end

    -- Get command at current position
    local query = db:prepare([[
        SELECT id, command_type, command_args, sequence_number, parent_sequence_number, pre_hash, post_hash, timestamp, playhead_value, playhead_rate,
               selected_clip_ids, selected_edge_infos, selected_gap_infos,
               selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre
        FROM commands
        WHERE sequence_number = ? AND command_type NOT LIKE 'Undo%'
    ]])
    if not query then
        print("WARNING: Failed to prepare get_last_command query")
        return nil
    end
    query:bind_value(1, current_sequence_number)

    if query:exec() and query:next() then
        -- Manually construct command from query results
        local command = {
            id = query:value(0),
            type = query:value(1),
            project_id = project_id,
            sequence_number = query:value(3) or 0,
            parent_sequence_number = query:value(4),  -- May be nil
            status = "Executed",
            parameters = {},
            pre_hash = query:value(5) or "",
            post_hash = query:value(6) or "",
            created_at = query:value(7) or os.time(),
            executed_at = query:value(7),
            playhead_value = query:value(8),
            playhead_rate = query:value(9),
            selected_clip_ids = query:value(10) or "[]",
            selected_edge_infos = query:value(11) or "[]",
            selected_gap_infos = query:value(12) or "[]",
            selected_clip_ids_pre = query:value(13) or "[]",
            selected_edge_infos_pre = query:value(14) or "[]",
            selected_gap_infos_pre = query:value(15) or "[]",
        }

        -- Parse command_args JSON to populate parameters
        local command_args_json = query:value(2)
        if command_args_json and command_args_json ~= "" and command_args_json ~= "{}" then
            local success, params = pcall(json.decode, command_args_json)
            if success and params then
                command.parameters = params
            end
        end

        if not command.playhead_value or not command.playhead_rate or command.playhead_rate <= 0 then
            query:finalize()
            error("FATAL: command missing playhead_value/playhead_rate in get_last_command")
        end

        local Command = require('command')
        setmetatable(command, {__index = Command})
        query:finalize()
        return command
    end
    query:finalize()

    return nil
end

function M.can_undo()
    if not db then
        return false
    end
    return M.get_last_command(active_project_id) ~= nil
end

function M.can_redo()
    if not db then
        return false
    end
    local parent_sequence = current_sequence_number or 0
    return find_latest_child_command(parent_sequence) ~= nil
end

-- Execute undo
function M.execute_undo(original_command)
    print(string.format("Executing undo for command: %s", original_command.type))

    local undo_command = original_command:create_undo()

    -- Execute undo logic without saving to command history
    -- (we don't want undo commands appearing in the command list)
    local result = {
        success = false,
        error_message = "",
        result_data = ""
    }

    -- Execute the undo command logic directly
    local execution_success = execute_command_implementation(undo_command)

    if execution_success then
        result.success = true
        result.result_data = undo_command:serialize()

        -- Move to parent in undo tree
        set_current_sequence_number(original_command.parent_sequence_number)
        print(string.format("  Undo successful! Moved to position: %s", tostring(current_sequence_number)))
    else
        result.error_message = last_error_message or "Undo execution failed"
    end

    return result
end

-- Execute batch
function M.execute_batch(commands)
    print(string.format("Executing batch of %d commands", #commands))

    local results = {}

    for _, command in ipairs(commands) do
        local result = M.execute(command)
        table.insert(results, result)

        -- Stop batch if any command fails (atomic operation)
        if not result.success then
            print(string.format("Batch execution failed at command: %s", command.type))
            break
        end
    end

    return results
end

-- Revert to sequence
function M.revert_to_sequence(sequence_number)
    print(string.format("Reverting to sequence: %d", sequence_number))

    local query = db:prepare("UPDATE commands SET status = 'Undone' WHERE sequence_number > ?")
    query:bind_value(1, sequence_number)

    if not query:exec() then
        print(string.format("ERROR: Failed to revert commands: %s", query:last_error()))
        return
    end

    last_sequence_number = sequence_number
    state_hash_cache = {}
end

-- Get project state
function M.get_project_state(project_id)
    print(string.format("Getting project state for: %s", project_id))

    if state_hash_cache[project_id] then
        return state_hash_cache[project_id]
    end

    local state_hash = calculate_state_hash(project_id)
    state_hash_cache[project_id] = state_hash

    return state_hash
end

-- Get current state
function M.get_current_state()
    local state_command = require('command').create("StateSnapshot", "current-project")
    state_command:set_parameter("state_hash", current_state_hash)
    state_command:set_parameter("sequence_number", last_sequence_number)
    state_command:set_parameter("timestamp", os.time())

    return state_command
end

-- Replay from sequence
function M.replay_from_sequence(start_sequence_number)
    print(string.format("Replaying commands from sequence: %d", start_sequence_number))

    local result = {
        success = true,
        commands_replayed = 0,
        error_message = "",
        failed_commands = {}
    }

    local commands_to_replay = load_commands_from_sequence(start_sequence_number)

    for _, command in ipairs(commands_to_replay) do
        -- Reset status and re-execute
        command.status = "Created"
        local exec_result = M.execute(command)

        if exec_result.success then
            result.commands_replayed = result.commands_replayed + 1
        else
            result.success = false
            result.error_message = exec_result.error_message
            table.insert(result.failed_commands, command.id)
            break -- Stop on first failure
        end
    end

    return result
end

-- Replay all
function M.replay_all()
    print("Replaying all commands")
    return M.replay_from_sequence(1)
end

-- Test/extension hook: register additional executors at runtime (e.g. for Lua tests)
function M.register_executor(command_type, executor, undoer)
    if type(command_type) ~= "string" or command_type == "" then
        error("register_executor requires a command type string")
    end
    if type(executor) ~= "function" then
        error("register_executor requires an executor function")
    end

    command_executors[command_type] = executor

    if undoer ~= nil then
        if type(undoer) ~= "function" then
            error("register_executor undoer must be a function if provided")
        end
        command_undoers[command_type] = undoer
    end
end

function M.unregister_executor(command_type)
    command_executors[command_type] = nil
    command_undoers[command_type] = nil
end

function M.add_listener(callback)
    if type(callback) ~= "function" then
        error("CommandManager.add_listener requires a callback function")
    end
    table.insert(command_event_listeners, callback)
    return callback
end

function M.remove_listener(callback)
    for index = #command_event_listeners, 1, -1 do
        if command_event_listeners[index] == callback then
            table.remove(command_event_listeners, index)
            return true
        end
    end
    return false
end

-- Validate sequence integrity
function M.validate_sequence_integrity()
    print("Validating command sequence integrity")

    local query = db:prepare("SELECT sequence_number, pre_hash, post_hash FROM commands ORDER BY sequence_number")

    if not query:exec() then
        print("WARNING: Failed to query commands for validation")
        return false
    end

    local expected_hash = ""
    while query:next() do
        local sequence = query:value(0)
        local pre_hash = query:value(1)
        local post_hash = query:value(2)

        -- For first command, any pre-hash is valid
        if sequence == 1 then
            expected_hash = post_hash
        else
            -- Check hash chain continuity
            if pre_hash ~= expected_hash then
                print(string.format("WARNING: Hash chain break at sequence: %d", sequence))
                return false
            end

            expected_hash = post_hash
        end
    end

    return true
end

-- Repair sequence numbers
function M.repair_sequence_numbers()
    print("Repairing command sequence numbers")

    local select_query = db:prepare("SELECT id FROM commands ORDER BY timestamp")
    if not select_query then
        print("ERROR: resequence_commands: Failed to prepare SELECT query")
        return
    end

    if select_query:exec() then
        local new_sequence = 1
        while select_query:next() do
            local command_id = select_query:value(0)

            local update_query = db:prepare("UPDATE commands SET sequence_number = ? WHERE id = ?")
            if not update_query then
                print(string.format("ERROR: resequence_commands: Failed to prepare UPDATE query for command %s", command_id))
                goto continue
            end

            update_query:bind_value(1, new_sequence)
            update_query:bind_value(2, command_id)

            if not update_query:exec() then
                print(string.format("ERROR: resequence_commands: Failed to update sequence for command %s", command_id))
            end

            ::continue::
            new_sequence = new_sequence + 1
        end

        last_sequence_number = new_sequence - 1
    else
        print("ERROR: resequence_commands: Failed to execute SELECT query")
    end
end

-- Event Replay: Reconstruct state by replaying commands from scratch
-- This is the core of event sourcing - state is derived from events, not stored directly
-- Parameters:
--   sequence_id: Which sequence to reconstruct (e.g., "default_sequence")
--   target_sequence_number: Replay up to and including this command number
-- Returns: true if successful, false otherwise
function M.replay_events(sequence_id, target_sequence_number)
    if not db then
        print("WARNING: replay_events: No database connection")
        return false
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local viewport_snapshot = timeline_state.capture_viewport()
    timeline_state.push_viewport_guard()

    local function cleanup()
        timeline_state.pop_viewport_guard()
        timeline_state.restore_viewport(viewport_snapshot)
    end

    local function replay_body()
        print(string.format("Replaying events for sequence '%s' up to command %d",
            sequence_id, target_sequence_number))

        local function require_snapshot_field(context, field, value)
            if value == nil then
                error(string.format("FATAL: %s missing required field '%s'", context, field))
            end
            return value
        end

        local project_id = nil
        do
            local project_query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
            if project_query then
                project_query:bind_value(1, sequence_id)
                if project_query:exec() and project_query:next() then
                    project_id = project_query:value(0)
                end
                project_query:finalize()
            end
        end

        if not project_id then
            project_id = active_project_id
            if not project_id then
                error(string.format("FATAL: Cannot determine project_id for sequence '%s' - cannot safely clear media table", sequence_id))
            else
                print(string.format("WARNING: Sequence '%s' missing project_id row; defaulting to active project '%s'", tostring(sequence_id), tostring(project_id)))
            end
        end

        -- Step 1: Load snapshot data (active + project-wide) if available
        local snapshot_mgr = require('core.snapshot_manager')
        local db_module = require('core.database')
        local snapshots_by_sequence = {}

        local snapshot = snapshot_mgr.load_snapshot(db, sequence_id)

        local start_sequence = 0

        if snapshot and snapshot.sequence_number <= target_sequence_number then
            snapshots_by_sequence[sequence_id] = snapshot
            start_sequence = snapshot.sequence_number
            local clip_count = snapshot.clips and #snapshot.clips or 0
            print(string.format("Starting from snapshot at sequence %d with %d clips",
                start_sequence, clip_count))
        else
            print("No snapshot available, replaying from beginning")
            start_sequence = 0
        end

        local additional_snapshots = snapshot_mgr.load_project_snapshots(db, project_id, target_sequence_number, sequence_id)
        for seq_id, snap in pairs(additional_snapshots) do
            snapshots_by_sequence[seq_id] = snap
        end

        local cached_initial_clips = sequence_initial_state.clips[sequence_id]
        local cached_initial_media = sequence_initial_state.media[project_id]
        local cached_initial_master = sequence_initial_state.master[project_id]

        local ClipModel = require('models.clip')
        if cached_initial_clips and #cached_initial_clips > 0 then
            local filtered = {}
            for _, clip_info in ipairs(cached_initial_clips) do
                local exists = ClipModel.load_optional(clip_info.id, db)
                if exists then
                    table.insert(filtered, clip_info)
                end
            end
            cached_initial_clips = filtered
        end

        local using_snapshot = snapshots_by_sequence[sequence_id] ~= nil

        -- Step 2: Determine which clips to preserve (initial state before any commands)
        local initial_clips = {}
        if using_snapshot then
            initial_clips = snapshots_by_sequence[sequence_id].clips or {}
            print(string.format("Using snapshot with %d clips as initial state", #initial_clips))
        elseif start_sequence > 0 then
            initial_clips = db_module.load_clips(sequence_id) or {}
            if #initial_clips > 0 then
                print(string.format("Starting from current database state with %d clips as baseline", #initial_clips))
            else
                print("Starting from empty initial state (no snapshot)")
            end
        elseif cached_initial_clips then
            initial_clips = clone_list(cached_initial_clips, clone_clip_entry)
            print(string.format("Using cached initial clip state with %d clip(s)", #initial_clips))
        else
            print("Starting from empty initial state (no snapshot)")
        end

        local initial_media = {}
        local media_seen = {}

        local function add_media_entries(media_list)
            if not media_list then
                return
            end
            for _, media in ipairs(media_list) do
                if media.id and not media_seen[media.id] then
                    media_seen[media.id] = true
                    initial_media[#initial_media + 1] = clone_media_entry(media)
                end
            end
        end

        if using_snapshot then
            for _, snap in pairs(snapshots_by_sequence) do
                add_media_entries(snap.media)
            end
        end

        add_media_entries(cached_initial_media)

        if #initial_media > 0 then
            print(string.format("Prepared initial media state with %d item(s)", #initial_media))
        end

        if using_snapshot then
            for _, clip in ipairs(initial_clips) do
                if clip.media_id and clip.media_id ~= "" then
                    assert(media_seen[clip.media_id], string.format(
                        "FATAL: Replay snapshot missing media record for clip %s (media_id=%s)",
                        tostring(clip.id), tostring(clip.media_id)))
                end
            end
        end

        local snapshot_timeline_restores = {}
        if using_snapshot then
            for seq_id, snap in pairs(snapshots_by_sequence) do
                snapshot_timeline_restores[seq_id] = {
                    sequence = snap.sequence,
                    tracks = snap.tracks or {},
                    clips = snap.clips or {}
                }
            end
        end

        -- Step 3: Clear ALL clips and media (we'll restore initial state + replay commands)
        local delete_clips_query = db:prepare("DELETE FROM clips WHERE track_id IN (SELECT id FROM tracks WHERE sequence_id = ?)")
        if delete_clips_query then
            delete_clips_query:bind_value(1, sequence_id)
            delete_clips_query:exec()
            delete_clips_query:finalize()
            print("Cleared all clips from database")
        end

        local delete_master_clips = db:prepare([[
            DELETE FROM clips
            WHERE clip_kind = 'master'
               OR owner_sequence_id IN (
                    SELECT id FROM sequences WHERE project_id = ? AND kind != 'timeline'
               )
        ]])
        if delete_master_clips then
            delete_master_clips:bind_value(1, project_id)
            delete_master_clips:exec()
            delete_master_clips:finalize()
            print("Cleared master clips and their children for replay")
        end

        local delete_master_tracks = db:prepare([[
            DELETE FROM tracks
            WHERE sequence_id IN (
                SELECT id FROM sequences WHERE project_id = ? AND kind != 'timeline'
            )
        ]])
        if delete_master_tracks then
            delete_master_tracks:bind_value(1, project_id)
            delete_master_tracks:exec()
            delete_master_tracks:finalize()
            print("Cleared master tracks for replay")
        end

        local delete_master_sequences = db:prepare([[
            DELETE FROM sequences
            WHERE project_id = ? AND kind != 'timeline'
        ]])
        if delete_master_sequences then
            delete_master_sequences:bind_value(1, project_id)
            delete_master_sequences:exec()
            delete_master_sequences:finalize()
            print("Cleared master sequences for replay")
        end

        local initial_timelines = sequence_initial_state.timeline[project_id] or {}
        local retain_timelines = {}
        for seq_id in pairs(initial_timelines) do
            retain_timelines[seq_id] = true
        end
        for k,v in pairs(retain_timelines) do
        end

        if using_snapshot then
            for seq_id, snap in pairs(snapshot_timeline_restores) do
                if snap.sequence then
                    local kind = snap.sequence.kind or "timeline"
                    if kind == "timeline" then
                        retain_timelines[seq_id] = true
                    end
                end
            end
        end
        local timeline_query = db:prepare([[
            SELECT id
            FROM sequences
            WHERE project_id = ? AND kind = 'timeline'
        ]])
        local timelines_to_delete = {}
        if timeline_query then
            timeline_query:bind_value(1, project_id)
            if timeline_query:exec() then
                while timeline_query:next() do
                    local seq_id = timeline_query:value(0)
                    if not retain_timelines[seq_id] then
                        table.insert(timelines_to_delete, seq_id)
                    end
                end
            end
            timeline_query:finalize()
        end

        if #timelines_to_delete > 0 then
            local delete_clips_stmt = db:prepare([[DELETE FROM clips WHERE track_id IN (SELECT id FROM tracks WHERE sequence_id = ?)]])
            local delete_tracks_stmt = db:prepare([[DELETE FROM tracks WHERE sequence_id = ?]])
            local delete_sequences_stmt = db:prepare([[DELETE FROM sequences WHERE id = ?]])

            for _, seq_id in ipairs(timelines_to_delete) do
                if delete_clips_stmt then
                    delete_clips_stmt:bind_value(1, seq_id)
                    delete_clips_stmt:exec()
                    delete_clips_stmt:reset()
                    delete_clips_stmt:clear_bindings()
                end

                if delete_tracks_stmt then
                    delete_tracks_stmt:bind_value(1, seq_id)
                    delete_tracks_stmt:exec()
                    delete_tracks_stmt:reset()
                    delete_tracks_stmt:clear_bindings()
                end

                if delete_sequences_stmt then
                    delete_sequences_stmt:bind_value(1, seq_id)
                    delete_sequences_stmt:exec()
                    delete_sequences_stmt:reset()
                    delete_sequences_stmt:clear_bindings()
                end
            end

            if delete_clips_stmt then delete_clips_stmt:finalize() end
            if delete_tracks_stmt then delete_tracks_stmt:finalize() end
            if delete_sequences_stmt then delete_sequences_stmt:finalize() end

            print(string.format("Removed %d timeline sequence(s) introduced after snapshot", #timelines_to_delete))
        end

        local purge_orphan_properties = db:prepare([[
            DELETE FROM properties
            WHERE clip_id NOT IN (SELECT id FROM clips)
        ]])
        if purge_orphan_properties then
            purge_orphan_properties:exec()
            purge_orphan_properties:finalize()
            print("Cleared orphan clip properties for replay")
        end

        -- Step 4: Restore initial state clips
        if #initial_media > 0 then
            local Media = require('models.media')
            local restored_count = 0
            local restored_ids = {}
            for _, media in ipairs(initial_media) do
                local duration = tonumber(media.duration) or 0
                if duration > 0 then
                    require_snapshot_field("snapshot_media", "id", media.id)
                    require_snapshot_field("snapshot_media", "project_id", media.project_id)
                    require_snapshot_field("snapshot_media", "name", media.name)
                    require_snapshot_field("snapshot_media", "file_path", media.file_path)
                    if not restored_ids[media.id] then
                        local restored_media = Media.create({
                            id = media.id,
                            project_id = media.project_id,
                            name = media.name,
                            file_path = media.file_path,
                            duration = duration,
                            frame_rate = media.frame_rate,
                            width = media.width,
                            height = media.height,
                            audio_channels = media.audio_channels,
                            codec = media.codec,
                            metadata = media.metadata,
                            created_at = media.created_at,
                            modified_at = media.modified_at
                        })
                        if restored_media then
                            restored_media.id = media.id
                            restored_media.project_id = media.project_id
                            if restored_media:save(db) then
                                restored_count = restored_count + 1
                                restored_ids[media.id] = true
                            end
                        end
                    end
                end
            end
            if restored_count > 0 then
                print(string.format("Restored %d media as initial state", restored_count))
            end
        end

        if cached_initial_master and (
            (#cached_initial_master.sequences or 0) > 0 or
            (#cached_initial_master.tracks or 0) > 0 or
            (#cached_initial_master.clips or 0) > 0
        ) then
            if cached_initial_master.sequences and #cached_initial_master.sequences > 0 then
                local seq_insert = db:prepare([[
                    INSERT OR REPLACE INTO sequences
                    (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
                     timecode_start_frame, playhead_value, selected_clip_ids, selected_edge_infos,
                     viewport_start_value, viewport_duration_frames_value, mark_in_value, mark_out_value,
                     current_sequence_number)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]])
                if not seq_insert then
                    error("FATAL: Failed to prepare master sequence restore statement")
                end
                for _, seq in ipairs(cached_initial_master.sequences) do
                    require_snapshot_field("master_sequence", "id", seq.id)
                    require_snapshot_field("master_sequence", "project_id", seq.project_id)
                    require_snapshot_field("master_sequence", "name", seq.name)
                    require_snapshot_field("master_sequence", "kind", seq.kind)
                    require_snapshot_field("master_sequence", "frame_rate", seq.frame_rate)
                    require_snapshot_field("master_sequence", "audio_sample_rate", seq.audio_sample_rate)
                    require_snapshot_field("master_sequence", "width", seq.width)
                    require_snapshot_field("master_sequence", "height", seq.height)
                    require_snapshot_field("master_sequence", "timecode_start_frame", seq.timecode_start_frame)
                    require_snapshot_field("master_sequence", "playhead_value", seq.playhead_value)
                    require_snapshot_field("master_sequence", "viewport_start_value", seq.viewport_start_value)
                    require_snapshot_field("master_sequence", "viewport_duration_frames_value", seq.viewport_duration_frames_value)
                    seq_insert:bind_value(1, seq.id)
                    seq_insert:bind_value(2, seq.project_id)
                    seq_insert:bind_value(3, seq.name)
                    seq_insert:bind_value(4, seq.kind)
                    seq_insert:bind_value(5, seq.frame_rate)
                    seq_insert:bind_value(6, seq.audio_sample_rate)
                    seq_insert:bind_value(7, seq.width)
                    seq_insert:bind_value(8, seq.height)
                    seq_insert:bind_value(9, seq.timecode_start_frame)
                    seq_insert:bind_value(10, seq.playhead_value)
                    seq_insert:bind_value(11, seq.selected_clip_ids)
                    seq_insert:bind_value(12, seq.selected_edge_infos)
                    seq_insert:bind_value(13, seq.viewport_start_value)
                    seq_insert:bind_value(14, seq.viewport_duration_frames_value)
                    seq_insert:bind_value(15, seq.mark_in_value)
                    seq_insert:bind_value(16, seq.mark_out_value)
                    seq_insert:bind_value(17, seq.current_sequence_number)
                    seq_insert:exec()
                    seq_insert:reset()
                    seq_insert:clear_bindings()
                end
                seq_insert:finalize()
                print(string.format("Restored %d master sequences as initial state", #cached_initial_master.sequences))
            end

            if cached_initial_master.tracks and #cached_initial_master.tracks > 0 then
                local track_insert = db:prepare([[
                    INSERT OR REPLACE INTO tracks
                    (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index,
                     enabled, locked, muted, soloed, volume, pan)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]])
                if not track_insert then
                    error("FATAL: Failed to prepare master track restore statement")
                end
                for _, track in ipairs(cached_initial_master.tracks) do
                    require_snapshot_field("master_track", "id", track.id)
                    require_snapshot_field("master_track", "sequence_id", track.sequence_id)
                    require_snapshot_field("master_track", "name", track.name)
                    require_snapshot_field("master_track", "track_type", track.track_type)
                    require_snapshot_field("master_track", "timebase_type", track.timebase_type)
                    require_snapshot_field("master_track", "timebase_rate", track.timebase_rate)
                    require_snapshot_field("master_track", "track_index", track.track_index)
                    require_snapshot_field("master_track", "enabled", track.enabled)
                    require_snapshot_field("master_track", "locked", track.locked)
                    require_snapshot_field("master_track", "muted", track.muted)
                    require_snapshot_field("master_track", "soloed", track.soloed)
                    require_snapshot_field("master_track", "volume", track.volume)
                    require_snapshot_field("master_track", "pan", track.pan)
                    track_insert:bind_value(1, track.id)
                    track_insert:bind_value(2, track.sequence_id)
                    track_insert:bind_value(3, track.name)
                    track_insert:bind_value(4, track.track_type)
                    track_insert:bind_value(5, track.timebase_type)
                    track_insert:bind_value(6, track.timebase_rate)
                    track_insert:bind_value(7, track.track_index)
                    track_insert:bind_value(8, (track.enabled == true or track.enabled == 1) and 1 or 0)
                    track_insert:bind_value(9, (track.locked == true or track.locked == 1) and 1 or 0)
                    track_insert:bind_value(10, (track.muted == true or track.muted == 1) and 1 or 0)
                    track_insert:bind_value(11, (track.soloed == true or track.soloed == 1) and 1 or 0)
                    track_insert:bind_value(12, track.volume)
                    track_insert:bind_value(13, track.pan)
                    track_insert:exec()
                    track_insert:reset()
                    track_insert:clear_bindings()
                end
                track_insert:finalize()
                print(string.format("Restored %d master tracks as initial state", #cached_initial_master.tracks))
            end

            if cached_initial_master.clips and #cached_initial_master.clips > 0 then
                local clip_insert = db:prepare([[
                    INSERT OR REPLACE INTO clips
                    (id, project_id, clip_kind, name, track_id, media_id,
                     source_sequence_id, parent_clip_id, owner_sequence_id,
                     start_value, duration_value, source_in_value, source_out_value,
                     timebase_type, timebase_rate, enabled, offline)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]])

                if not clip_insert then
                    error("FATAL: Failed to prepare master clip restore statement")
                end

                local function insert_clip_row(clip)
                    local context = string.format("master_clip[%s]", tostring(clip.id))
                    require_snapshot_field(context, "id", clip.id)
                    require_snapshot_field(context, "project_id", clip.project_id)
                    require_snapshot_field(context, "clip_kind", clip.clip_kind)
                    require_snapshot_field(context, "owner_sequence_id", clip.owner_sequence_id)
                    require_snapshot_field(context, "start_value", clip.start_value)
                    require_snapshot_field(context, "duration", clip.duration)
                    require_snapshot_field(context, "source_in", clip.source_in)
                    require_snapshot_field(context, "source_out", clip.source_out)
                    require_snapshot_field(context, "timebase_type", clip.timebase_type)
                    require_snapshot_field(context, "timebase_rate", clip.timebase_rate)
                    require_snapshot_field(context, "enabled", clip.enabled)
                    require_snapshot_field(context, "offline", clip.offline)
                    local enabled_flag = (clip.enabled == true) or (clip.enabled == 1)
                    local offline_flag = (clip.offline == true) or (clip.offline == 1)
                    clip_insert:bind_value(1, clip.id)
                    clip_insert:bind_value(2, clip.project_id)
                    clip_insert:bind_value(3, clip.clip_kind)
                    clip_insert:bind_value(4, clip.name or "")
                    clip_insert:bind_value(5, clip.track_id)
                    clip_insert:bind_value(6, clip.media_id)
                    clip_insert:bind_value(7, clip.source_sequence_id)
                    clip_insert:bind_value(8, clip.parent_clip_id)
                    clip_insert:bind_value(9, clip.owner_sequence_id)
                    clip_insert:bind_value(10, clip.start_value)
                    clip_insert:bind_value(11, clip.duration)
                    clip_insert:bind_value(12, clip.source_in)
                    clip_insert:bind_value(13, clip.source_out)
                    clip_insert:bind_value(14, clip.timebase_type)
                    clip_insert:bind_value(15, clip.timebase_rate)
                    clip_insert:bind_value(16, enabled_flag and 1 or 0)
                    clip_insert:bind_value(17, offline_flag and 1 or 0)
                    clip_insert:exec()
                    clip_insert:reset()
                    clip_insert:clear_bindings()
                end

                for _, clip in ipairs(cached_initial_master.clips) do
                    if clip.clip_kind == "master" then
                        insert_clip_row(clip)
                    end
                end
                for _, clip in ipairs(cached_initial_master.clips) do
                    if clip.clip_kind ~= "master" then
                        insert_clip_row(clip)
                    end
                end
                clip_insert:finalize()
                print(string.format("Restored %d master clip rows as initial state", #cached_initial_master.clips))
            end
        end

        if using_snapshot and next(snapshot_timeline_restores) ~= nil then
            local seq_insert = db:prepare([[
                INSERT OR REPLACE INTO sequences
                (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
                 timecode_start_frame, playhead_value, selected_clip_ids, selected_edge_infos,
                 viewport_start_value, viewport_duration_frames_value, mark_in_value, mark_out_value,
                 current_sequence_number)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]])
            local track_insert = db:prepare([[
                INSERT OR REPLACE INTO tracks
                (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index,
                 enabled, locked, muted, soloed, volume, pan)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]])
            local clip_insert = db:prepare([[
                INSERT OR REPLACE INTO clips
                (id, project_id, clip_kind, name, track_id, media_id,
                 source_sequence_id, parent_clip_id, owner_sequence_id,
                 start_value, duration_value, source_in_value, source_out_value,
                 timebase_type, timebase_rate, enabled, offline)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]])

            if not seq_insert or not track_insert or not clip_insert then
                error("FATAL: Failed to prepare snapshot timeline restore statements")
            end

            local restored_sequences = 0

            for seq_id, restore in pairs(snapshot_timeline_restores) do
                local seq_info = restore.sequence
                if seq_info then
                    local context = string.format("snapshot_sequence[%s]", tostring(seq_info.id))
                    require_snapshot_field(context, "id", seq_info.id)
                    require_snapshot_field(context, "project_id", seq_info.project_id)
                    require_snapshot_field(context, "name", seq_info.name)
                    require_snapshot_field(context, "kind", seq_info.kind)
                    require_snapshot_field(context, "frame_rate", seq_info.frame_rate)
                    require_snapshot_field(context, "audio_sample_rate", seq_info.audio_sample_rate)
                    require_snapshot_field(context, "width", seq_info.width)
                    require_snapshot_field(context, "height", seq_info.height)
                    require_snapshot_field(context, "timecode_start_frame", seq_info.timecode_start_frame)
                    require_snapshot_field(context, "playhead_value", seq_info.playhead_value)
                    require_snapshot_field(context, "viewport_start_value", seq_info.viewport_start_value)
                    require_snapshot_field(context, "viewport_duration_frames_value", seq_info.viewport_duration_frames_value)
                    seq_insert:bind_value(1, seq_info.id)
                    seq_insert:bind_value(2, seq_info.project_id)
                    seq_insert:bind_value(3, seq_info.name)
                    seq_insert:bind_value(4, seq_info.kind)
                    seq_insert:bind_value(5, seq_info.frame_rate or 0)
                    seq_insert:bind_value(6, seq_info.audio_sample_rate or 48000)
                    seq_insert:bind_value(7, seq_info.width or 0)
                    seq_insert:bind_value(8, seq_info.height or 0)
                    seq_insert:bind_value(9, seq_info.timecode_start_frame or 0)
                    seq_insert:bind_value(10, seq_info.playhead_value or 0)
                    seq_insert:bind_value(11, seq_info.selected_clip_ids or "[]")
                    seq_insert:bind_value(12, seq_info.selected_edge_infos or "[]")
                    seq_insert:bind_value(13, seq_info.viewport_start_value or 0)
                    seq_insert:bind_value(14, seq_info.viewport_duration_frames_value or 10000)
                    seq_insert:bind_value(15, seq_info.mark_in_value)
                    seq_insert:bind_value(16, seq_info.mark_out_value)
                    seq_insert:bind_value(17, seq_info.current_sequence_number)
                    seq_insert:exec()
                    seq_insert:reset()
                    seq_insert:clear_bindings()
                    restored_sequences = restored_sequences + 1
                end
            end

            for seq_id, restore in pairs(snapshot_timeline_restores) do
                for _, track in ipairs(restore.tracks) do
                    local context = string.format("snapshot_track[%s]", tostring(track.id))
                    require_snapshot_field(context, "id", track.id)
                    require_snapshot_field(context, "sequence_id", track.sequence_id)
                    require_snapshot_field(context, "name", track.name)
                    require_snapshot_field(context, "track_type", track.track_type)
                    require_snapshot_field(context, "track_index", track.track_index)
                    track_insert:bind_value(1, track.id)
                    track_insert:bind_value(2, track.sequence_id)
                    track_insert:bind_value(3, track.name)
                    track_insert:bind_value(4, track.track_type)
                    track_insert:bind_value(5, track.track_index or 0)
                    track_insert:bind_value(6, (track.enabled == true or track.enabled == 1) and 1 or 0)
                    track_insert:bind_value(7, (track.locked == true or track.locked == 1) and 1 or 0)
                    track_insert:bind_value(8, (track.muted == true or track.muted == 1) and 1 or 0)
                    track_insert:bind_value(9, (track.soloed == true or track.soloed == 1) and 1 or 0)
                    track_insert:bind_value(10, track.volume or 1.0)
                    track_insert:bind_value(11, track.pan or 0.0)
                    track_insert:exec()
                    track_insert:reset()
                    track_insert:clear_bindings()
                end
            end

            for seq_id, restore in pairs(snapshot_timeline_restores) do
                for _, clip in ipairs(restore.clips) do
                    local context = string.format("snapshot_clip[%s]", tostring(clip.id))
                    require_snapshot_field(context, "id", clip.id)
                    require_snapshot_field(context, "project_id", clip.project_id)
                    require_snapshot_field(context, "clip_kind", clip.clip_kind)
                    require_snapshot_field(context, "owner_sequence_id", clip.owner_sequence_id)
                    require_snapshot_field(context, "start_value", clip.start_value)
                    require_snapshot_field(context, "duration", clip.duration)
                    require_snapshot_field(context, "source_in", clip.source_in)
                    require_snapshot_field(context, "source_out", clip.source_out)
                    require_snapshot_field(context, "enabled", clip.enabled)
                    require_snapshot_field(context, "offline", clip.offline)
                    local enabled_flag = (clip.enabled == true) or (clip.enabled == 1)
                    local offline_flag = (clip.offline == true) or (clip.offline == 1)
                    clip_insert:bind_value(1, clip.id)
                    clip_insert:bind_value(2, clip.project_id)
                    clip_insert:bind_value(3, clip.clip_kind)
                    clip_insert:bind_value(4, clip.name or "")
                    clip_insert:bind_value(5, clip.track_id)
                    clip_insert:bind_value(6, clip.media_id)
                    clip_insert:bind_value(7, clip.source_sequence_id)
                    clip_insert:bind_value(8, clip.parent_clip_id)
                    clip_insert:bind_value(9, clip.owner_sequence_id)
                    clip_insert:bind_value(10, clip.start_value)
                    clip_insert:bind_value(11, clip.duration)
                    clip_insert:bind_value(12, clip.source_in)
                    clip_insert:bind_value(13, clip.source_out)
                    clip_insert:bind_value(14, enabled_flag and 1 or 0)
                    clip_insert:bind_value(15, offline_flag and 1 or 0)
                    clip_insert:exec()
                    clip_insert:reset()
                    clip_insert:clear_bindings()
                end
            end

            seq_insert:finalize()
            track_insert:finalize()
            clip_insert:finalize()

            print(string.format("Restored %d timeline sequence(s) from snapshot", restored_sequences))
        elseif #initial_clips > 0 then
            local clip_insert = db:prepare([[
                INSERT OR REPLACE INTO clips
                (id, project_id, clip_kind, name, track_id, media_id,
                 source_sequence_id, parent_clip_id, owner_sequence_id,
                 start_value, duration_value, source_in_value, source_out_value,
                 timebase_type, timebase_rate, enabled, offline)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]])

            if not clip_insert then
                error("FATAL: Failed to prepare clip restore statement")
            end

            for _, clip in ipairs(initial_clips) do
                local context = string.format("snapshot_clip[%s]", tostring(clip.id))
                require_snapshot_field(context, "id", clip.id)
                require_snapshot_field(context, "project_id", clip.project_id)
                require_snapshot_field(context, "clip_kind", clip.clip_kind)
                require_snapshot_field(context, "owner_sequence_id", clip.owner_sequence_id)
                require_snapshot_field(context, "start_value", clip.start_value)
                require_snapshot_field(context, "duration", clip.duration)
                require_snapshot_field(context, "source_in", clip.source_in)
                require_snapshot_field(context, "source_out", clip.source_out)
                require_snapshot_field(context, "enabled", clip.enabled)
                require_snapshot_field(context, "offline", clip.offline)
                local enabled_flag = (clip.enabled == true) or (clip.enabled == 1)
                local offline_flag = (clip.offline == true) or (clip.offline == 1)
                clip_insert:bind_value(1, clip.id)
                clip_insert:bind_value(2, clip.project_id)
                clip_insert:bind_value(3, clip.clip_kind)
                clip_insert:bind_value(4, clip.name or "")
                clip_insert:bind_value(5, clip.track_id)
                clip_insert:bind_value(6, clip.media_id)
                clip_insert:bind_value(7, clip.source_sequence_id)
                clip_insert:bind_value(8, clip.parent_clip_id)
                clip_insert:bind_value(9, clip.owner_sequence_id)
                clip_insert:bind_value(10, clip.start_value)
                clip_insert:bind_value(11, clip.duration or clip.duration_value)
                clip_insert:bind_value(12, clip.source_in or clip.source_in_value or 0)
                clip_insert:bind_value(13, clip.source_out or clip.source_out_value or (clip.source_in or 0) + (clip.duration or 0))
                clip_insert:bind_value(14, clip.timebase_type or "video_frames")
                clip_insert:bind_value(15, clip.timebase_rate or 24.0)
                clip_insert:bind_value(16, enabled_flag and 1 or 0)
                clip_insert:bind_value(17, offline_flag and 1 or 0)
                clip_insert:exec()
                clip_insert:reset()
                clip_insert:clear_bindings()
            end
            clip_insert:finalize()

            print(string.format("Restored %d clips as initial state", #initial_clips))
        end

        -- Step 5: Replay commands from start_sequence + 1 to target_sequence_number
        -- IMPORTANT: Follow the parent_sequence_number chain to only replay commands on the active branch
        if target_sequence_number > start_sequence then
            -- Build the command chain by walking backwards from target to start
            local command_chain = {}
            local current_seq = target_sequence_number

            while current_seq > start_sequence do
                local find_query = db:prepare([[
                    SELECT id, command_type, command_args, sequence_number, parent_sequence_number, pre_hash, post_hash, timestamp, playhead_value, playhead_rate,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos,
                           selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre
                    FROM commands
                    WHERE sequence_number = ?
                ]])

                if not find_query then
                    print("WARNING: Failed to prepare find command query")
                    break
                end

                find_query:bind_value(1, current_seq)

                if find_query:exec() and find_query:next() then
                    -- Store this command
                    table.insert(command_chain, 1, {  -- Insert at beginning to reverse order
                        id = find_query:value(0),
                        command_type = find_query:value(1),
                        command_args = find_query:value(2),
                        sequence_number = find_query:value(3),
                        parent_sequence_number = find_query:value(4),
                        pre_hash = find_query:value(5),
                        post_hash = find_query:value(6),
                        timestamp = find_query:value(7),
                        playhead_value = find_query:value(8),
                        playhead_rate = find_query:value(9),
                        selected_clip_ids = find_query:value(10),
                        selected_edge_infos = find_query:value(11),
                        selected_gap_infos = find_query:value(12),
                        selected_clip_ids_pre = find_query:value(13),
                        selected_edge_infos_pre = find_query:value(14),
                        selected_gap_infos_pre = find_query:value(15)
                    })

                    -- Move to parent
                    local parent = find_query:value(4)
                    find_query:finalize()

                    -- Check for NULL parent (only error if not the first command)
                    if not parent then
                        local replaying_from_root = start_sequence == 0
                        if current_seq == 1 or replaying_from_root then
                            -- First command or new branch root from the beginning
                            current_seq = 0
                        elseif current_seq > start_sequence then
                            -- Found NULL parent in middle of chain - treating as root command
                            local warning_key = "orphaned_cmd_" .. current_seq
                            if last_warning_message ~= warning_key then
                                print(string.format("⚠️  Note: Command %d has no parent (orphaned from previous session)", current_seq))
                                print(string.format("    Replay will start from command %d instead of the beginning", current_seq))
                                last_warning_message = warning_key
                            end
                            break
                        else
                            current_seq = 0
                        end
                    else
                        current_seq = parent
                    end
                else
                    find_query:finalize()
                    print(string.format("WARNING: Could not find command with sequence %d", current_seq))
                    break
                end
            end

            print(string.format("Replaying %d commands on active branch to sequence %d", #command_chain, target_sequence_number))

            local Command = require("command")
            local commands_replayed = 0
            local final_playhead_value = 0
            local final_selected_clip_ids = "[]"
            local final_selected_edge_infos = "[]"
            local final_selected_gap_infos = "[]"

            for _, cmd_data in ipairs(command_chain) do
                -- Restore selection state prior to executing this command
                restore_selection_from_serialized(cmd_data.selected_clip_ids_pre, cmd_data.selected_edge_infos_pre, cmd_data.selected_gap_infos_pre)

                -- Create command object from stored data
                local command = Command.create(cmd_data.command_type, active_project_id)
                command.id = cmd_data.id
                command.sequence_number = cmd_data.sequence_number
                command.parent_sequence_number = cmd_data.parent_sequence_number
                command.pre_hash = cmd_data.pre_hash
                command.post_hash = cmd_data.post_hash
                command.timestamp = cmd_data.timestamp

                -- Decode parameters from JSON
                if cmd_data.command_args and cmd_data.command_args ~= "" then
                    local success, params = pcall(qt_json_decode, cmd_data.command_args)
                    if success then
                        command.parameters = params
                    end
                end

                -- Restore playhead BEFORE executing command
                timeline_state.set_playhead_value(cmd_data.playhead_value or 0)

                -- Execute the command (but don't save it again - it's already in commands table)
                local skip_sequence_replay = command_flag(command, "skip_sequence_replay", "__skip_sequence_replay")
                local execution_success = true
                if not skip_sequence_replay then
                    execution_success = execute_command_implementation(command)
                else
                    print(string.format("Skipping replay for command %d (%s) - marked skip_sequence_replay",
                        command.sequence_number, command.type))
                end

                if execution_success then
                    commands_replayed = commands_replayed + 1
                else
                    print(string.format("ERROR: Failed to replay command %d (%s)",
                        command.sequence_number, command.type))
                    print("ERROR: Event log is incomplete or corrupted")
                    print("ERROR: Command replay expected database objects that are missing")
                    print("HINT: Earlier commands may not have persisted generated IDs (e.g., split results)")
                    print("HINT: Re-run the failing command outside undo/redo to refresh its stored parameters")
                    return false
                end
                final_playhead_value = cmd_data.playhead_value or 0
                final_selected_clip_ids = cmd_data.selected_clip_ids or "[]"
                final_selected_edge_infos = cmd_data.selected_edge_infos or "[]"
                final_selected_gap_infos = cmd_data.selected_gap_infos or "[]"
            end

            print(string.format("✅ Replayed %d commands successfully", commands_replayed))
            restore_selection_from_serialized(final_selected_clip_ids, final_selected_edge_infos, final_selected_gap_infos)
        else
            -- No commands to replay; restore snapshot-derived timeline state instead of clearing to zero
            local restored_playhead = 0
            local sequence_record = nil
            if db_module and sequence_id then
                sequence_record = db_module.load_sequence_record(sequence_id)
            end
            if sequence_record and sequence_record.playhead_value then
                restored_playhead = sequence_record.playhead_value
            end

            if timeline_state.reload_clips then
                timeline_state.reload_clips(sequence_id)
            end

            local selected_clip_ids = nil
            local selected_edge_infos = nil
            local selected_gap_infos = nil

            if sequence_record then
                timeline_state.restore_viewport({
                    start_value = sequence_record.viewport_start_value,
                    duration = sequence_record.viewport_duration_frames_value
                })
                selected_clip_ids = sequence_record.selected_clip_ids
                selected_edge_infos = sequence_record.selected_edge_infos
                selected_gap_infos = sequence_record.selected_gap_infos
            end

            restore_selection_from_serialized(selected_clip_ids, selected_edge_infos, selected_gap_infos)

            timeline_state.set_playhead_value(restored_playhead)
            print(string.format("No commands to replay - restored playhead to %s", format_timecode_for_log(restored_playhead)))
        end

        return true
    end

    local ok, result = pcall(replay_body)
    cleanup()

    if not ok then
        error(result)
    end

    return result
end

-- Track last warning message to suppress consecutive duplicates
local last_warning_message = nil

function M.undo(options)
    if type(options) == "string" then
        options = {stack_id = options}
    else
        options = options or {}
    end

    if options.stack_id then
        local stack_opts = nil
        if options.sequence_id then
            stack_opts = {sequence_id = options.sequence_id}
        end
        set_active_stack(options.stack_id, stack_opts)
    end

    local sequence_id = get_current_stack_sequence_id(true) or active_sequence_id

    -- Get the command at current position
    local current_command = M.get_last_command(active_project_id)

    if not current_command then
        print("Nothing to undo")
        return {success = false, error_message = "Nothing to undo"}
    end

    local timeline_state = require('ui.timeline.timeline_state')

    print(string.format("Undoing command: %s (seq %d, parent %s)",
        current_command.type,
        current_command.sequence_number,
        tostring(current_command.parent_sequence_number)))

    local skip_timeline_reload = command_flag(current_command, "skip_timeline_reload", "__skip_timeline_reload")
    local skip_selection_restore = command_flag(current_command, "skip_selection_snapshot", "__skip_selection_snapshot")
    local skip_sequence_replay = command_flag(current_command, "skip_sequence_replay", "__skip_sequence_replay")
    local skip_sequence_replay_on_undo = command_flag(current_command, "skip_sequence_replay_on_undo", "__skip_sequence_replay_on_undo")
    local skip_replay_effective = skip_sequence_replay or skip_sequence_replay_on_undo
    if skip_replay_effective then
        skip_timeline_reload = true
    end
    -- Calculate target sequence (parent of current command for branching support)
    -- In a branching history, undo follows the parent link, not sequence_number - 1
    local target_sequence = current_command.parent_sequence_number or 0

    print(string.format("  Will replay from 0 to %d", target_sequence))

    -- Replay events up to target (or clear all if target is 0)
    local replay_success = true
    if skip_replay_effective then
        replay_success = true
    else
        if target_sequence > 0 then
            replay_success = M.replay_events(sequence_id, target_sequence)
        else
            replay_success = M.replay_events(sequence_id, 0)
        end
    end

    if replay_success then
        if current_command.type == "DeleteSequence" and target_sequence == 0 then
            local payload = current_command:get_parameter("delete_sequence_snapshot")
            if payload then
                local delete_module = require('core.commands.delete_sequence')
                delete_module.restore_from_payload(db, payload, M.set_last_error)
            end
        end
        -- Restore playhead to position BEFORE the undone command (i.e., AFTER the last valid command)
        -- This is stored in current_command.playhead_value
        local restored_playhead = current_command.playhead_value or 0

        local pending_reload_sequence = nil
        if target_sequence == 0 then
            local remains = sequence_exists(sequence_id)
            if not remains then
                local fallback_sequence = fetch_first_timeline_sequence(active_project_id)
                if fallback_sequence and fallback_sequence ~= sequence_id then
                    local fallback_stack = stack_id_for_sequence(fallback_sequence)
                    set_active_stack(fallback_stack, {sequence_id = fallback_sequence})
                    active_sequence_id = fallback_sequence
                    sequence_id = fallback_sequence
                    pending_reload_sequence = fallback_sequence
                end
            end
        end

        if pending_reload_sequence and timeline_state.reload_clips then
            timeline_state.reload_clips(pending_reload_sequence)
            timeline_state.set_playhead_value(restored_playhead)
        elseif not skip_timeline_reload then
            timeline_state.set_playhead_value(restored_playhead)
        end
        print(string.format("Restored playhead to %s", format_timecode_for_log(restored_playhead)))

        -- Move current_sequence_number back
        local new_position = target_sequence > 0 and target_sequence or nil
        set_current_sequence_number(new_position)

        -- Save undo position to database (persists across sessions)
        save_undo_position()

        -- Reload timeline state to pick up database changes
        -- This triggers listener notifications → automatic view redraws
        if not skip_timeline_reload then
            timeline_state.reload_clips(sequence_id)
        end
        if not skip_selection_restore then
            restore_selection_from_serialized(current_command.selected_clip_ids_pre, current_command.selected_edge_infos_pre, current_command.selected_gap_infos_pre)
        end

        local manual_undo = command_undoers[current_command.type]
        if manual_undo then
            local ok, err = pcall(manual_undo, current_command)
            if not ok then
                print(string.format("WARNING: Manual undo for %s failed: %s", tostring(current_command.type), tostring(err)))
            end
        end
        notify_command_event({
            event = "undo",
            command = current_command,
            project_id = active_project_id,
            stack_id = get_current_stack_id(),
            sequence_number = current_command.sequence_number
        })
        print(string.format("Undo complete - moved to position %s", tostring(current_sequence_number)))
        return {success = true}
    else
        local error_msg = string.format(
            "Cannot replay to sequence %d. Event log is corrupted - clips exist that were never created via commands. " ..
            "Consider deleting orphaned clips or rebuilding event log.",
            target_sequence
        )
        return {success = false, error_message = error_msg}
    end
end

-- Redo: Move forward one command in the undo tree using event replay
function M.redo(options)
    if type(options) == "string" then
        options = {stack_id = options}
    else
        options = options or {}
    end

    if options.stack_id then
        local stack_opts = nil
        if options.sequence_id then
            stack_opts = {sequence_id = options.sequence_id}
        end
        set_active_stack(options.stack_id, stack_opts)
    end

    local sequence_id = get_current_stack_sequence_id(true) or active_sequence_id
    local replay_sequence_id = sequence_id
    if replay_sequence_id and not sequence_exists(replay_sequence_id) then
        replay_sequence_id = active_sequence_id
    end
    if replay_sequence_id and not sequence_exists(replay_sequence_id) then
        if active_sequence_id ~= "default_sequence" and sequence_exists("default_sequence") then
            replay_sequence_id = "default_sequence"
        else
            replay_sequence_id = nil
        end
    end
    if not replay_sequence_id then
        replay_sequence_id = sequence_id
    end

    if not db then
        print("No database connection")
        return {success = false, error_message = "No database connection"}
    end

    -- Get the next command in the active branch
    -- In a branching history, redo follows the most recently created child
    -- (highest sequence_number with parent = current_sequence_number)
    local current_pos = current_sequence_number or 0

    local next_command = find_latest_child_command(current_pos)
    if not next_command then
        print("Nothing to redo")
        return {success = false, error_message = "Nothing to redo"}
    end

    local target_sequence = next_command.sequence_number
    local command_type = next_command.command_type
    local skip_sequence_replay = command_flag(next_command, "skip_sequence_replay", "__skip_sequence_replay")
    local skip_sequence_replay_on_redo = command_flag(next_command, "skip_sequence_replay_on_redo", "__skip_sequence_replay_on_redo")
    local skip_replay_effective = skip_sequence_replay or skip_sequence_replay_on_redo
    print(string.format("Redoing command: %s (seq %d)", command_type, target_sequence))

    -- Replay events up to target sequence unless command opts out
    local replay_success = true
    if not skip_replay_effective then
        replay_success = M.replay_events(replay_sequence_id, target_sequence)
    end

    if replay_success then
        -- Move current_sequence_number forward
        set_current_sequence_number(target_sequence)

        -- Save undo position to database (persists across sessions)
        save_undo_position()

        local restored_command = M.get_last_command(active_project_id)
        local skip_timeline_reload = restored_command and command_flag(restored_command, "skip_timeline_reload", "__skip_timeline_reload") or false
        local skip_selection_restore = restored_command and command_flag(restored_command, "skip_selection_snapshot", "__skip_selection_snapshot") or false
        local skip_sequence_replay_flag = restored_command and command_flag(restored_command, "skip_sequence_replay", "__skip_sequence_replay") or false
        local skip_sequence_replay_on_redo_flag = restored_command and command_flag(restored_command, "skip_sequence_replay_on_redo", "__skip_sequence_replay_on_redo") or false
        local skip_replay_effective_flag = skip_sequence_replay_flag or skip_sequence_replay_on_redo_flag
        if skip_replay_effective_flag then
            skip_timeline_reload = true
        end
        -- Reload timeline state to pick up database changes
        -- This triggers listener notifications → automatic view redraws
        local timeline_state = require('ui.timeline.timeline_state')
        if not skip_timeline_reload then
            timeline_state.reload_clips(sequence_id)
        end

        if restored_command and not skip_selection_restore then
            local selection_restored = false

            if db and current_sequence_number then
                local next_query = db:prepare([[
                    SELECT sequence_number, selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre
                    FROM commands
                    WHERE parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0)
                    ORDER BY sequence_number DESC
                    LIMIT 1
                ]])

                if next_query then
                    next_query:bind_value(1, current_sequence_number)
                    next_query:bind_value(2, current_sequence_number)

                    if next_query:exec() and next_query:next() then
                        local next_sequence = next_query:value(0)
                        if next_sequence and next_sequence > current_sequence_number then
                            local next_clip_ids_pre = next_query:value(1)
                            local next_edge_infos_pre = next_query:value(2)
                            local next_gap_infos_pre = next_query:value(3)
                            if next_clip_ids_pre ~= nil or next_edge_infos_pre ~= nil or next_gap_infos_pre ~= nil then
                                restore_selection_from_serialized(next_clip_ids_pre, next_edge_infos_pre, next_gap_infos_pre)
                                selection_restored = true
                            end
                        end
                    end
                end
            end

            if not selection_restored then
                restore_selection_from_serialized(restored_command.selected_clip_ids, restored_command.selected_edge_infos, restored_command.selected_gap_infos)
            end
        end

        if skip_replay_effective_flag and restored_command then
            local manual_redo = command_redoers[restored_command.type]
            if manual_redo then
                local ok, err = pcall(manual_redo, restored_command)
                if not ok then
                    print(string.format("WARNING: Manual redo for %s failed: %s",
                        tostring(restored_command.type), tostring(err)))
                end
            end
        end

        notify_command_event({
            event = "redo",
            command = restored_command or {type = command_type},
            project_id = active_project_id,
            stack_id = get_current_stack_id(),
            sequence_number = current_sequence_number
        })

        print(string.format("Redo complete - moved to position %d", current_sequence_number))

        return {success = true}
    else
        return {success = false, error_message = "Redo replay failed"}
    end
end

function M.enable_multi_stack(value)
    multi_stack_enabled = value and true or false
end

function M.is_multi_stack_enabled()
    return multi_stack_enabled
end

function M.stack_id_for_sequence(sequence_id)
    return stack_id_for_sequence(sequence_id)
end

function M.activate_stack(stack_id, opts)
    if opts and opts.sequence_id then
        set_active_stack(stack_id, {sequence_id = opts.sequence_id})
    else
        set_active_stack(stack_id)
    end
end

function M.activate_timeline_stack(sequence_id)
    local seq = sequence_id or active_sequence_id
    active_sequence_id = seq
    local stack_id = stack_id_for_sequence(seq)
    set_active_stack(stack_id, {sequence_id = seq})

    if db and seq and seq ~= "" then
        local project_id = nil
        local query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
        if query then
            query:bind_value(1, seq)
            if query:exec() and query:next() then
                project_id = query:value(0)
            end
            query:finalize()
        end

        if project_id and project_id ~= "" then
            cache_initial_state(seq, project_id)
        else
            cache_initial_state(seq, active_project_id)
        end
    end

    return stack_id
end

function M.get_active_stack_id()
    return get_current_stack_id()
end

function M.get_stack_state(stack_id)
    local state = ensure_stack_state(stack_id or get_current_stack_id())
    return {
        current_sequence_number = state.current_sequence_number,
        sequence_id = state.sequence_id,
    }
end

function M.register_stack_resolver(command_type, resolver)
    if type(command_type) ~= "string" or command_type == "" then
        error("register_stack_resolver: command_type must be a non-empty string")
    end
    if type(resolver) ~= "function" then
        error("register_stack_resolver: resolver must be a function")
    end
    command_stack_resolvers[command_type] = resolver
end

-- LinkClips: Create A/V sync relationship between clips
-- clips parameter: array of {clip_id, role, time_offset?}
command_executors["LinkClips"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing LinkClips command")
    end

    local clips_to_link = command:get_parameter("clips")

    if not clips_to_link or #clips_to_link < 2 then
        print("ERROR: LinkClips requires at least 2 clips")
        return false
    end

    if dry_run then
        return true  -- Preview is valid
    end

    local clip_links = require('core.clip_links')
    local link_group_id, error_msg = clip_links.create_link_group(clips_to_link, db)

    if not link_group_id then
        print(string.format("ERROR: LinkClips failed: %s", error_msg or "unknown error"))
        return false
    end

    -- Store link group ID for undo
    command:set_parameter("link_group_id", link_group_id)

    print(string.format("✅ Linked %d clips (group %s)", #clips_to_link, link_group_id:sub(1,8)))
    return true
end

command_undoers["LinkClips"] = function(command)
    local link_group_id = command:get_parameter("link_group_id")

    if not link_group_id then
        return false
    end

    -- Delete the entire link group
    local query = db:prepare([[
        DELETE FROM clip_links WHERE link_group_id = ?
    ]])

    if not query then
        return false
    end

    query:bind_value(1, link_group_id)
    local result = query:exec()
    query:finalize()

    return result
end

-- UnlinkClip: Remove a clip from its link group
command_executors["UnlinkClip"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing UnlinkClip command")
    end

    local clip_id = command:get_parameter("clip_id")

    if not clip_id then
        print("ERROR: UnlinkClip missing clip_id")
        return false
    end

    if dry_run then
        return true
    end

    local clip_links = require('core.clip_links')

    -- Save original link info for undo
    local link_group = clip_links.get_link_group(clip_id, db)
    if link_group then
        command:set_parameter("original_link_group", link_group)

        -- Find this clip's info in the group
        for _, link_info in ipairs(link_group) do
            if link_info.clip_id == clip_id then
                command:set_parameter("original_role", link_info.role)
                command:set_parameter("original_time_offset", link_info.time_offset)
                break
            end
        end
    end

    local success = clip_links.unlink_clip(clip_id, db)

    if success then
        print(string.format("✅ Unlinked clip %s", clip_id:sub(1,8)))
    else
        print(string.format("ERROR: Failed to unlink clip %s", clip_id:sub(1,8)))
    end

    return success
end

command_undoers["UnlinkClip"] = function(command)
    local clip_id = command:get_parameter("clip_id")
    local original_link_group = command:get_parameter("original_link_group")

    if not clip_id or not original_link_group or #original_link_group == 0 then
        return true  -- Clip was not linked, nothing to restore
    end

    -- Restore the link
    local link_group_id = nil
    for _, link_info in ipairs(original_link_group) do
        if link_info.clip_id ~= clip_id then
            -- Find the existing link group ID from another clip
            local query = db:prepare([[
                SELECT link_group_id FROM clip_links WHERE clip_id = ? LIMIT 1
            ]])
            if query then
                query:bind_value(1, link_info.clip_id)
                if query:exec() and query:next() then
                    link_group_id = query:value(0)
                end
                query:finalize()
                if link_group_id then
                    break
                end
            end
        end
    end

    if not link_group_id then
        -- The entire link group was deleted, recreate it
        local uuid = require('uuid')
        link_group_id = uuid.generate()
    end

    -- Re-insert this clip into the link group
    local role = command:get_parameter("original_role")
    local time_offset = command:get_parameter("original_time_offset") or 0

    local insert_query = db:prepare([[
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES (?, ?, ?, ?, 1)
    ]])

    if not insert_query then
        return false
    end

    insert_query:bind_value(1, link_group_id)
    insert_query:bind_value(2, clip_id)
    insert_query:bind_value(3, role)
    insert_query:bind_value(4, time_offset)

    local result = insert_query:exec()
    insert_query:finalize()

    return result
end

-- Alias plural menu command to singular implementation
command_executors["UnlinkClips"] = command_executors["UnlinkClip"]
command_undoers["UnlinkClips"] = command_undoers["UnlinkClip"]

command_executors["ToggleMaximizePanel"] = function(command)
    local panel_manager = require("ui.panel_manager")
    local panel_id = command:get_parameter("panel_id")
    local ok, err = panel_manager.toggle_maximize(panel_id)
    if not ok and err then
        print(string.format("WARNING: ToggleMaximizePanel: %s", err))
    end
    return true
end

-- ImportFCP7XML: Import Final Cut Pro 7 XML sequence
command_executors["ImportFCP7XML"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing ImportFCP7XML command")
    end

    local xml_path = command:get_parameter("xml_path")
    local xml_contents = command:get_parameter("xml_contents")
    local project_id = command:get_parameter("project_id") or "default_project"

    if not xml_path then
        print("ERROR: ImportFCP7XML missing xml_path")
        return false
    end

    if dry_run then
        return true  -- Validation would happen here
    end

    local fcp7_importer = require('importers.fcp7_xml_importer')

    -- Parse XML
    if xml_path and xml_path ~= "" then
        print(string.format("Parsing FCP7 XML: %s", xml_path))
    else
        print("Parsing FCP7 XML from stored content")
    end
    local parse_result = fcp7_importer.import_xml(xml_path, project_id, {
        xml_content = xml_contents
    })

    if not parse_result.success then
        for _, error_msg in ipairs(parse_result.errors) do
            print(string.format("ERROR: %s", error_msg))
        end
        return false
    end

    print(string.format("Found %d sequence(s)", #parse_result.sequences))

    -- Prepare replay context so importer can reuse deterministic IDs
    local replay_context = {
        sequence_id_map = command:get_parameter("sequence_id_map") or command:get_parameter("created_sequence_id_map"),
        track_id_map = command:get_parameter("track_id_map"),
        clip_id_map = command:get_parameter("clip_id_map"),
        media_id_map = command:get_parameter("media_id_map"),
        sequence_ids = command:get_parameter("created_sequence_ids"),
        track_ids = command:get_parameter("created_track_ids"),
        clip_ids = command:get_parameter("created_clip_ids"),
        media_ids = command:get_parameter("created_media_ids")
    }

    -- Create entities in database
    local create_result = fcp7_importer.create_entities(parse_result, db, project_id, replay_context)

    if not create_result.success then
        print(string.format("ERROR: %s", create_result.error or "Failed to create entities"))
        return false
    end

    -- Store created IDs for undo
    command:set_parameter("created_sequence_ids", create_result.sequence_ids)
    command:set_parameter("created_track_ids", create_result.track_ids)
    command:set_parameter("created_clip_ids", create_result.clip_ids)
    command:set_parameter("created_media_ids", create_result.media_ids)
    command:set_parameter("sequence_id_map", create_result.sequence_id_map)
    command:set_parameter("track_id_map", create_result.track_id_map)
    command:set_parameter("clip_id_map", create_result.clip_id_map)
    command:set_parameter("media_id_map", create_result.media_id_map)
    if parse_result.xml_content and (not xml_contents or xml_contents == "") then
        command:set_parameter("xml_contents", parse_result.xml_content)
    end
    command:set_parameter("__skip_sequence_replay_on_undo", true)

    print(string.format("✅ Imported %d sequence(s), %d track(s), %d clip(s)",
        #create_result.sequence_ids,
        #create_result.track_ids,
        #create_result.clip_ids))

    command:set_parameter("__force_snapshot", true)
    command:set_parameter("__snapshot_sequence_ids", create_result.sequence_ids)

    return true
end

command_undoers["ImportFCP7XML"] = function(command)
    -- Delete all created entities
    local sequence_ids = command:get_parameter("created_sequence_ids") or {}
    local track_ids = command:get_parameter("created_track_ids") or {}
    local clip_ids = command:get_parameter("created_clip_ids") or {}
    local media_ids = command:get_parameter("created_media_ids") or {}

    -- Delete in reverse order (clips, tracks, sequences)
    local deleted_sequence_lookup = {}

    for _, clip_id in ipairs(clip_ids) do
        local delete_query = db:prepare("DELETE FROM clips WHERE id = ?")
        if delete_query then
            delete_query:bind_value(1, clip_id)
            delete_query:exec()
            delete_query:finalize()
        end
    end

    for _, track_id in ipairs(track_ids) do
        local delete_query = db:prepare("DELETE FROM tracks WHERE id = ?")
        if delete_query then
            delete_query:bind_value(1, track_id)
            delete_query:exec()
            delete_query:finalize()
        end
    end

    for _, sequence_id in ipairs(sequence_ids) do
        local delete_query = db:prepare("DELETE FROM sequences WHERE id = ?")
        if delete_query then
            delete_query:bind_value(1, sequence_id)
            delete_query:exec()
            delete_query:finalize()
        end
        deleted_sequence_lookup[sequence_id] = true
        invalidate_sequence_stack(sequence_id)
    end

    for _, media_id in ipairs(media_ids) do
        local delete_query = db:prepare("DELETE FROM media WHERE id = ?")
        if delete_query then
            delete_query:bind_value(1, media_id)
            delete_query:exec()
            delete_query:finalize()
        end
    end

    local timeline_state = nil
    local ok, loaded_state = pcall(require, 'ui.timeline.timeline_state')
    if ok and type(loaded_state) == "table" then
        timeline_state = loaded_state
    end

    local fallback_sequence = nil
    local active_sequence = nil
    if timeline_state and timeline_state.get_sequence_id then
        active_sequence = timeline_state.get_sequence_id()
        if active_sequence and deleted_sequence_lookup[active_sequence] then
            fallback_sequence = select_fallback_sequence(deleted_sequence_lookup)
        end
    end

    if fallback_sequence then
        M.activate_timeline_stack(fallback_sequence)
    end

    if timeline_state and timeline_state.reload_clips then
        local reload_target = fallback_sequence or active_sequence or "default_sequence"
        timeline_state.reload_clips(reload_target)
    end

    print("✅ Import undone - deleted all imported entities")
    return true
end
-- ============================================================================ 
-- RelinkMedia Command
-- ============================================================================ 
-- Updates media file_path to point to a new location
-- Used by media relinking system when files have been moved/renamed
-- 
-- Parameters:
--   - media_id: ID of media record to relink
--   - new_file_path: New absolute path to media file
-- 
-- Stored state (for undo):
--   - old_file_path: Previous file path before relinking

command_executors.RelinkMedia = function(cmd, params) 
    local media_id = params.media_id
    local new_file_path = params.new_file_path

    if not media_id or not new_file_path then
        return {success = false, error_message = "RelinkMedia requires media_id and new_file_path"}
    end

    -- Load media record
    local Media = require("models.media")
    local media = Media.load(media_id, db)

    if not media then
        return {success = false, error_message = "Media not found: " .. media_id}
    end

    -- Store old path for undo
    local old_file_path = media.file_path

    -- Update file path
    media.file_path = new_file_path

    -- Save to database
    if not media:save(db) then
        return {success = false, error_message = "Failed to save relinked media"}
    end

    print(string.format("Relinked media '%s': %s → %s", media.name, old_file_path, new_file_path))

    return {
        success = true,
        old_file_path = old_file_path  -- Store for undo
    }
end

command_undoers.RelinkMedia = function(cmd)
    local media_id = cmd.parameters.media_id
    local old_file_path = cmd.result.old_file_path

    if not media_id or not old_file_path then
        print("ERROR: Cannot undo RelinkMedia - missing stored state")
        return false
    end

    -- Load media and restore old path
    local Media = require("models.media")
    local media = Media.load(media_id, db)

    if not media then
        print("ERROR: Cannot undo RelinkMedia - media not found: " .. media_id)
        return false
    end

    media.file_path = old_file_path

    if not media:save(db) then
        print("ERROR: Failed to restore old media path")
        return false
    end

    print(string.format("Restored media '%s' to original path: %s", media.name, old_file_path))
    return true
end

-- ============================================================================ 
-- BatchRelinkMedia Command
-- ============================================================================ 
-- Relinks multiple media files in a single undo-able operation
-- 
-- Parameters:
--   - relink_map: table mapping media_id → new_file_path
-- 
-- Stored state (for undo):
--   - old_paths: table mapping media_id → old_file_path

command_executors.BatchRelinkMedia = function(cmd, params)
    local relink_map = params.relink_map

    if not relink_map or type(relink_map) ~= "table" then
        return {success = false, error_message = "BatchRelinkMedia requires relink_map table"}
    end

    local Media = require("models.media")
    local old_paths = {}
    local relinked_count = 0

    -- Relink each media file
    for media_id, new_file_path in pairs(relink_map) do
        local media = Media.load(media_id, db)

        if media then
            -- Store old path for undo
            old_paths[media_id] = media.file_path

            -- Update path
            media.file_path = new_file_path

            if media:save(db) then
                relinked_count = relinked_count + 1
            else
                print(string.format("WARNING: Failed to relink media %s", media_id))
            end
        else
            print(string.format("WARNING: Media not found: %s", media_id))
        end
    end

    print(string.format("Batch relinked %d media file(s)", relinked_count))

    return {
        success = true,
        old_paths = old_paths,
        relinked_count = relinked_count
    }
end

command_undoers.BatchRelinkMedia = function(cmd)
    local relink_map = cmd.parameters.relink_map
    local old_paths = cmd.result.old_paths

    if not old_paths then
        print("ERROR: Cannot undo BatchRelinkMedia - missing stored state")
        return false
    end

    local Media = require("models.media")
    local restored_count = 0

    -- Restore each media file to old path
    for media_id, old_file_path in pairs(old_paths) do
        local media = Media.load(media_id, db)

        if media then
            media.file_path = old_file_path

            if media:save(db) then
                restored_count = restored_count + 1
            else
                print(string.format("WARNING: Failed to restore media %s", media_id))
            end
        else
            print(string.format("WARNING: Media not found during undo: %s", media_id))
        end
    end

    print(string.format("Batch undo: restored %d media file path(s)", restored_count))
    return true
end

-- Get the executor function for a command type (used for dry-run preview)
function M.get_executor(command_type)
    return command_executors[command_type]
end

-- ============================================================================ 
-- ImportResolveProject Command
-- ============================================================================ 
-- Imports DaVinci Resolve .drp project file into JVE
-- Creates: project record, media items, timelines, tracks, clips
-- Full undo support: deletes all created entities

command_executors.ImportResolveProject = function(cmd, params)
    local drp_path = params.drp_path

    if not drp_path or drp_path == "" then
        return {success = false, error_message = "No .drp file path provided"}
    end

    -- Parse .drp file
    local drp_importer = require("importers.drp_importer")
    local parse_result = drp_importer.parse_drp_file(drp_path)

    if not parse_result.success then
        return {success = false, error_message = parse_result.error}
    end

    local Project = require("models.project")
    local Media = require("models.media")
    local Clip = require("models.clip")

    -- Create project record
    local project = Project.create({
        name = parse_result.project.name,
        frame_rate = parse_result.project.settings.frame_rate,
        width = parse_result.project.settings.width,
        height = parse_result.project.settings.height
    })

    if not project:save(db) then
        return {success = false, error_message = "Failed to create project"}
    end

    print(string.format("Created project: %s (%dx%d @ %.2ffps)",
        project.name, project.width, project.height, project.frame_rate))

    -- Track created entities for undo
    local created_media_ids = {}
    local created_timeline_ids = {}
    local created_track_ids = {}
    local created_clip_ids = {}

    -- Import media items
    local media_id_map = {}  -- resolve_id -> jve_media_id
    for _, media_item in ipairs(parse_result.media_items) do
        local media = Media.create({
            project_id = project.id,
            name = media_item.name,
            file_path = media_item.file_path,
            duration = media_item.duration,
            width = parse_result.project.settings.width,
            height = parse_result.project.settings.height
        })

        if media:save(db) then
            table.insert(created_media_ids, media.id)
            if media_item.resolve_id then
                media_id_map[media_item.resolve_id] = media.id
            end
            print(string.format("  Imported media: %s", media.name))
        else
            print(string.format("WARNING: Failed to import media: %s", media_item.name))
        end
    end

    -- Import timelines
    for _, timeline_data in ipairs(parse_result.timelines) do
        -- Create sequence (timeline) record
        local stmt = db:prepare([[
            INSERT INTO sequences (id, project_id, name, duration, frame_rate)
            VALUES (?, ?, ?, ?, ?)
        ]])

        local timeline_id = require("models.clip").generate_uuid()  -- Reuse UUID generator
        stmt:bind_values(
            timeline_id,
            project.id,
            timeline_data.name,
            timeline_data.duration,
            parse_result.project.settings.frame_rate
        )

        if stmt:step() == sqlite3.DONE then
            table.insert(created_timeline_ids, timeline_id)
            print(string.format("  Imported timeline: %s", timeline_data.name))

            -- Import tracks
            for _, track_data in ipairs(timeline_data.tracks) do
                local track_stmt = db:prepare([[
                    INSERT INTO tracks (id, sequence_id, track_type, track_index)
                    VALUES (?, ?, ?, ?)
                ]])

                local track_id = require("models.clip").generate_uuid()
                track_stmt:bind_values(
                    track_id,
                    timeline_id,
                    track_data.type,
                    track_data.index
                )

                if track_stmt:step() == sqlite3.DONE then
                    table.insert(created_track_ids, track_id)
                    print(string.format("    Created track: %s%d", track_data.type, track_data.index))

                    -- Import clips
                    for _, clip_data in ipairs(track_data.clips) do
                        -- Find matching media_id (if file_path available)
                        local media_id = nil
                        if clip_data.file_path then
                            for _, media in ipairs(created_media_ids) do
                                local m = Media.load(media, db)
                                if m and m.file_path == clip_data.file_path then
                                    media_id = m.id
                                    break
                                end
                            end
                        end

                        local clip = Clip.create({
                            track_id = track_id,
                            media_id = media_id,
                            start_value = clip_data.start_value,
                            duration = clip_data.duration,
                            source_in = clip_data.source_in,
                            source_out = clip_data.source_out
                        })

                        if clip:save(db) then
                            table.insert(created_clip_ids, clip.id)
                        else
                            print(string.format("WARNING: Failed to import clip: %s", clip_data.name))
                        end
                    end
                else
                    print(string.format("WARNING: Failed to create track: %s%d", track_data.type, track_data.index))
                end

                track_stmt:finalize()
            end
        else
            print(string.format("WARNING: Failed to create timeline: %s", timeline_data.name))
        end

        stmt:finalize()
    end

    print(string.format("Imported Resolve project: %d media, %d timelines, %d tracks, %d clips",
        #created_media_ids, #created_timeline_ids, #created_track_ids, #created_clip_ids))

    return {
        success = true,
        project_id = project.id,
        created_media_ids = created_media_ids,
        created_timeline_ids = created_timeline_ids,
        created_track_ids = created_track_ids,
        created_clip_ids = created_clip_ids
    }
end

command_undoers.ImportResolveProject = function(cmd)
    local result = cmd.result

    if not result or not result.success then
        print("ERROR: Cannot undo ImportResolveProject - command failed")
        return false
    end

    local Clip = require("models.clip")
    local Media = require("models.media")

    -- Delete clips
    for _, clip_id in ipairs(result.created_clip_ids or {}) do
        local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
        stmt:bind_values(clip_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete tracks
    for _, track_id in ipairs(result.created_track_ids or {}) do
        local stmt = db:prepare("DELETE FROM tracks WHERE id = ?")
        stmt:bind_values(track_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete timelines
    for _, timeline_id in ipairs(result.created_timeline_ids or {}) do
        local stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
        stmt:bind_values(timeline_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete media
    for _, media_id in ipairs(result.created_media_ids or {}) do
        local stmt = db:prepare("DELETE FROM media WHERE id = ?")
        stmt:bind_values(media_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete project
    if result.project_id then
        local stmt = db:prepare("DELETE FROM projects WHERE id = ?")
        stmt:bind_values(result.project_id)
        stmt:step()
        stmt:finalize()
    end

    print("Undo: Deleted imported Resolve project and all associated data")
    return true
end

-- ============================================================================ 
-- ImportResolveDatabase Command
-- ============================================================================ 
-- Imports DaVinci Resolve project from SQLite disk database
-- Creates: project record, media items, timelines, tracks, clips
-- Full undo support: deletes all created entities

command_executors.ImportResolveDatabase = function(cmd, params)
    local db_path = params.db_path

    if not db_path or db_path == "" then
        return {success = false, error_message = "No database path provided"}
    end

    -- Import from Resolve database
    local resolve_db_importer = require("importers.resolve_database_importer")
    local import_result = resolve_db_importer.import_from_database(db_path)

    if not import_result.success then
        return {success = false, error_message = import_result.error}
    end

    local Project = require("models.project")
    local Media = require("models.media")
    local Clip = require("models.clip")

    -- Create project record
    local project = Project.create({
        name = import_result.project.name,
        frame_rate = import_result.project.frame_rate,
        width = import_result.project.width,
        height = import_result.project.height
    })

    if not project:save(db) then
        return {success = false, error_message = "Failed to create project"}
    end

    print(string.format("Created project from Resolve DB: %s (%dx%d @ %.2ffps)",
        project.name, project.width, project.height, project.frame_rate))

    -- Track created entities for undo
    local created_media_ids = {}
    local created_timeline_ids = {}
    local created_track_ids = {}
    local created_clip_ids = {}

    -- Import media items
    local media_id_map = {}  -- resolve_id -> jve_media_id
    for _, media_item in ipairs(import_result.media_items) do
        local media = Media.create({
            project_id = project.id,
            name = media_item.name,
            file_path = media_item.file_path,
            duration = media_item.duration,
            width = import_result.project.width,
            height = import_result.project.height
        })

        if media:save(db) then
            table.insert(created_media_ids, media.id)
            if media_item.resolve_id then
                media_id_map[media_item.resolve_id] = media.id
            end
            print(string.format("  Imported media: %s", media.name))
        else
            print(string.format("WARNING: Failed to import media: %s", media_item.name))
        end
    end

    -- Import timelines
    for _, timeline_data in ipairs(import_result.timelines) do
        -- Create sequence (timeline) record
        local stmt = db:prepare([[
            INSERT INTO sequences (id, project_id, name, duration, frame_rate)
            VALUES (?, ?, ?, ?, ?)
        ]])

        local timeline_id = require("models.clip").generate_uuid()
        stmt:bind_values(
            timeline_id,
            project.id,
            timeline_data.name,
            timeline_data.duration,
            timeline_data.frame_rate
        )

        if stmt:step() == sqlite3.DONE then
            table.insert(created_timeline_ids, timeline_id)
            print(string.format("  Imported timeline: %s", timeline_data.name))

            -- Import tracks
            for _, track_data in ipairs(timeline_data.tracks) do
                local track_stmt = db:prepare([[
                    INSERT INTO tracks (id, sequence_id, track_type, track_index)
                    VALUES (?, ?, ?, ?)
                ]])

                local track_id = require("models.clip").generate_uuid()
                track_stmt:bind_values(
                    track_id,
                    timeline_id,
                    track_data.type,
                    track_data.index
                )

                if track_stmt:step() == sqlite3.DONE then
                    table.insert(created_track_ids, track_id)
                    print(string.format("    Created track: %s%d", track_data.type, track_data.index))

                    -- Import clips
                    for _, clip_data in ipairs(track_data.clips) do
                        -- Find matching media_id using resolve_media_id
                        local media_id = media_id_map[clip_data.resolve_media_id]

                        local clip = Clip.create({
                            track_id = track_id,
                            media_id = media_id,
                            start_value = clip_data.start_value,
                            duration = clip_data.duration,
                            source_in = clip_data.source_in,
                            source_out = clip_data.source_out
                        })

                        if clip:save(db) then
                            table.insert(created_clip_ids, clip.id)
                        else
                            print(string.format("WARNING: Failed to import clip: %s", clip_data.name))
                        end
                    end
                else
                    print(string.format("WARNING: Failed to create track: %s%d", track_data.type, track_data.index))
                end

                track_stmt:finalize()
            end
        else
            print(string.format("WARNING: Failed to create timeline: %s", timeline_data.name))
        end

        stmt:finalize()
    end

    print(string.format("Imported Resolve database: %d media, %d timelines, %d tracks, %d clips",
        #created_media_ids, #created_timeline_ids, #created_track_ids, #created_clip_ids))

    return {
        success = true,
        project_id = project.id,
        created_media_ids = created_media_ids,
        created_timeline_ids = created_timeline_ids,
        created_track_ids = created_track_ids,
        created_clip_ids = created_clip_ids
    }
end

command_undoers.ImportResolveDatabase = function(cmd)
    local result = cmd.result

    if not result or not result.success then
        print("ERROR: Cannot undo ImportResolveDatabase - command failed")
        return false
    end

    local Clip = require("models.clip")
    local Media = require("models.media")

    -- Delete clips
    for _, clip_id in ipairs(result.created_clip_ids or {}) do
        local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
        stmt:bind_values(clip_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete tracks
    for _, track_id in ipairs(result.created_track_ids or {}) do
        local stmt = db:prepare("DELETE FROM tracks WHERE id = ?")
        stmt:bind_values(track_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete timelines
    for _, timeline_id in ipairs(result.created_timeline_ids or {}) do
        local stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
        stmt:bind_values(timeline_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete media
    for _, media_id in ipairs(result.created_media_ids or {}) do
        local stmt = db:prepare("DELETE FROM media WHERE id = ?")
        stmt:bind_values(media_id)
        stmt:step()
        stmt:finalize()
    end

    -- Delete project
    if result.project_id then
        local stmt = db:prepare("DELETE FROM projects WHERE id = ?")
        stmt:bind_values(result.project_id)
        stmt:step()
        stmt:finalize()
    end

    print("Undo: Deleted imported Resolve database project and all associated data")
    return true
end

return M