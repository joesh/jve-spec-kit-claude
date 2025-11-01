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

local command_scope = require("core.command_scope")
local frame_utils = require("core.frame_utils")

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
}

local GLOBAL_STACK_ID = "global"
local TIMELINE_STACK_PREFIX = "timeline:"

local undo_stack_states = {
    [GLOBAL_STACK_ID] = {
        current_sequence_number = nil,
        current_branch_path = {},
        sequence_id = nil,
    }
}

local active_stack_id = GLOBAL_STACK_ID
local current_sequence_number = undo_stack_states[GLOBAL_STACK_ID].current_sequence_number
local current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path

local multi_stack_enabled = false
if os and os.getenv then
    multi_stack_enabled = os.getenv("JVE_ENABLE_MULTI_STACK_UNDO") == "1"
end

-- Registry that callers can use to route commands to specific undo stacks.
local command_stack_resolvers = {}

local sequence_initial_state = {
    clips = {},
    media = {},
    master = {}
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
        start_time = clip.start_time,
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
               timecode_start, playhead_time, selected_clip_ids, selected_edge_infos,
               viewport_start_time, viewport_duration, mark_in_time, mark_out_time,
               current_sequence_number
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
                    timecode_start = tonumber(seq_query:value(7)) or 0,
                    playhead_time = tonumber(seq_query:value(8)) or 0,
                    selected_clip_ids = seq_query:value(9),
                    selected_edge_infos = seq_query:value(10),
                    viewport_start_time = tonumber(seq_query:value(11)) or 0,
                    viewport_duration = tonumber(seq_query:value(12)) or 10000,
                    mark_in_time = seq_query:value(13),
                    mark_out_time = seq_query:value(14),
                    current_sequence_number = seq_query:value(15)
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
               enabled, locked, muted, soloed, volume, pan
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
                        pan = tonumber(track_query:value(10)) or 0.0
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
               start_time, duration, source_in, source_out, enabled, offline
        FROM clips
        WHERE clip_kind = 'master' AND source_sequence_id = ?
    ]])

    local child_clip_query = conn:prepare([[
        SELECT id, project_id, clip_kind, name, track_id, media_id,
               source_sequence_id, parent_clip_id, owner_sequence_id,
               start_time, duration, source_in, source_out, enabled, offline
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
                        owner_sequence_id = master_clip_query:value(8),
                        start_time = tonumber(master_clip_query:value(9)) or 0,
                        duration = tonumber(master_clip_query:value(10)) or 0,
                        source_in = tonumber(master_clip_query:value(11)) or 0,
                        source_out = tonumber(master_clip_query:value(12)) or 0,
                        enabled = master_clip_query:value(13) == 1 or master_clip_query:value(13) == true,
                        offline = master_clip_query:value(14) == 1 or master_clip_query:value(14) == true
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
                        owner_sequence_id = child_clip_query:value(8),
                        start_time = tonumber(child_clip_query:value(9)) or 0,
                        duration = tonumber(child_clip_query:value(10)) or 0,
                        source_in = tonumber(child_clip_query:value(11)) or 0,
                        source_out = tonumber(child_clip_query:value(12)) or 0,
                        enabled = child_clip_query:value(13) == 1 or child_clip_query:value(13) == true,
                        offline = child_clip_query:value(14) == 1 or child_clip_query:value(14) == true
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
    local database = require('core.database')

    if sequence_id and not sequence_initial_state.clips[sequence_id] then
        local ok, clips = pcall(database.load_clips, sequence_id)
        if ok and type(clips) == "table" then
            sequence_initial_state.clips[sequence_id] = clone_list(clips, clone_clip_entry)
        else
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
end

local function ensure_stack_state(stack_id)
    stack_id = stack_id or GLOBAL_STACK_ID
    local state = undo_stack_states[stack_id]
    if not state then
        state = {
            current_sequence_number = nil,
            current_branch_path = {},
            sequence_id = nil,
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
end

local function set_current_sequence_number(value)
    current_sequence_number = value
    ensure_stack_state(active_stack_id).current_sequence_number = value
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

local function capture_selection_snapshot()
    local timeline_state = require('ui.timeline.timeline_state')
    if timeline_state.normalize_edge_selection then
        timeline_state.normalize_edge_selection()
    end
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

    return clips_json, edges_json
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

    if pragma:exec() then
        while pragma:next() do
            local column_name = pragma:value(1)
            if column_name == "selected_clip_ids_pre" then
                has_clip_pre = true
            elseif column_name == "selected_edge_infos_pre" then
                has_edge_pre = true
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
end

local function capture_pre_selection_for_command(command)
    local clips_json, edges_json = capture_selection_snapshot()
    command.selected_clip_ids_pre = clips_json
    command.selected_edge_infos_pre = edges_json
end

local function capture_post_selection_for_command(command)
    local clips_json, edges_json = capture_selection_snapshot()
    command.selected_clip_ids = clips_json
    command.selected_edge_infos = edges_json
end

local function restore_selection_from_serialized(clips_json, edges_json)
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
            timeline_state.set_edge_selection(restored_edges)
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

    timeline_state.set_selection({})
end

function M.set_last_error(message)
    if type(message) == "string" and message ~= "" then
        last_error_message = message
    else
        last_error_message = ""
    end
end

-- Initialize CommandManager with database connection
function M.init(database, sequence_id, project_id)
    db = database
    active_sequence_id = sequence_id or "default_sequence"
    active_project_id = project_id or "default_project"

    local global_state = ensure_stack_state(GLOBAL_STACK_ID)
    global_state.sequence_id = active_sequence_id
    set_active_stack(GLOBAL_STACK_ID, {sequence_id = active_sequence_id})

    -- Register all command executors and undoers
    local command_implementations = require("core.command_implementations")
    command_implementations.register_commands(command_executors, command_undoers, db, M.set_last_error)

    -- Query last sequence number from database
    local query = db:prepare("SELECT MAX(sequence_number) FROM commands")
    if query and query:exec() and query:next() then
        last_sequence_number = query:value(0) or 0
    end

    -- Load current undo position from sequences table (persisted across sessions)
    local pos_query = db:prepare("SELECT current_sequence_number FROM sequences WHERE id = ?")
    if pos_query then
        pos_query:bind_value(1, active_sequence_id)
    end

    if pos_query and pos_query:exec() and pos_query:next() then
        local saved_position = pos_query:value(0)
        if saved_position and saved_position > 0 then
            set_current_sequence_number(saved_position)
        elseif saved_position == 0 then
            -- 0 means at beginning (all commands undone)
            set_current_sequence_number(0)
        else
            -- NULL means no position saved yet - default to HEAD
            if last_sequence_number > 0 then
                set_current_sequence_number(last_sequence_number)
            else
                set_current_sequence_number(nil)  -- No commands exist yet
            end
        end
    else
        -- If no saved position row exists, default to HEAD if we have commands
        if last_sequence_number > 0 then
            set_current_sequence_number(last_sequence_number)
        end
    end

    print(string.format("CommandManager initialized, last sequence: %d, current position: %s",
        last_sequence_number, tostring(current_sequence_number)))

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
        return
    end

    local broken_commands = {}
    while find_query:next() do
        table.insert(broken_commands, find_query:value(0))
    end

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
                end
            else
                print(string.format("  ⚠️  Command %d has no predecessor - cannot repair", seq_num))
            end
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

    update:bind_value(1, current_sequence_number)
    update:bind_value(2, sequence_id)
    local success = update:exec()

    if not success then
        print("WARNING: Failed to save undo position to database")
        return false
    end

    return true
end

-- Calculate state hash for a project
local function calculate_state_hash(project_id)
    if not db then
        print("WARNING: No database connection for state hash calculation")
        return "00000000"
    end

    -- Query all relevant project state data
    local query = db:prepare([[
        SELECT p.name, p.settings,
               s.name, s.frame_rate, s.width, s.height,
               t.track_type, t.track_index, t.enabled,
               c.start_time, c.duration, c.enabled,
               m.file_path, m.duration, m.frame_rate
        FROM projects p
        LEFT JOIN sequences s ON p.id = s.project_id
        LEFT JOIN tracks t ON s.id = t.sequence_id
        LEFT JOIN clips c ON t.id = c.track_id
        LEFT JOIN media m ON c.media_id = m.id
        WHERE p.id = ?
        ORDER BY s.id, t.track_type, t.track_index, c.start_time
    ]])

    if not query then
        local err = "unknown error"
        if db.last_error then
            err = db:last_error()
        end
        print("WARNING: Failed to prepare state hash query: " .. err)
        return "00000000"
    end

    query:bind_value(1, project_id)

    local state_string = ""
    if query:exec() then
        while query:next() do
            -- Build deterministic state string
            for i = 0, 13 do  -- We select 14 columns (0-13): p.name, p.settings, s.name, s.frame_rate, s.width, s.height, t.track_type, t.track_index, t.enabled, c.start_time, c.duration, c.enabled, m.file_path, m.duration
                local value = query:value(i)
                state_string = state_string .. tostring(value) .. "|"
            end
            state_string = state_string .. "\n"
        end
    end

    -- Calculate simple hash (TODO: implement proper SHA256 via Qt bindings)
    -- For now, use Lua's string hash as a simple checksum
    local hash = string.format("%08x", #state_string)  -- Simple length-based hash
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

    return commands
end

-- Execute command implementation (routes to specific handlers)
local function execute_command_implementation(command)
    local executor = command_executors[command.type]

    if executor then
        local success, result = pcall(executor, command)
        if not success then
            print(string.format("ERROR: Executor failed: %s", tostring(result)))
            return false
        end
        return result
    elseif command.type == "FastOperation" or
           command.type == "BatchOperation" or
           command.type == "ComplexOperation" then
        -- Test commands that should succeed
        return true
    else
        local error_msg = string.format("Unknown command type: %s", command.type)
        print("WARNING: " .. error_msg)
        last_error_message = error_msg
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

    local result = {
        success = false,
        error_message = "",
        result_data = ""
    }

    if not validate_command_parameters(command) then
        result.error_message = "Invalid command parameters"
        return result
    end

    local scope_ok, scope_err = command_scope.check(command)
    if not scope_ok then
        result.error_message = scope_err or "Command cannot execute in current scope"
        return result
    end

    if non_recording_commands[command.type] then
        return execute_non_recording(command)
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
    cache_initial_state(active_sequence, command.project_id or active_project_id)

    -- BEGIN TRANSACTION: All database changes (command save + state changes) are atomic
    -- If anything fails, everything rolls back automatically
    local begin_tx = db:prepare("BEGIN TRANSACTION")
    if not (begin_tx and begin_tx:exec()) then
        result.error_message = "Failed to begin transaction"
        return result
    end

    -- Calculate pre-execution state hash
    local pre_hash = calculate_state_hash(command.project_id)

    -- Assign sequence number
    local sequence_number = get_next_sequence_number()
    command.sequence_number = sequence_number

    -- Set parent_sequence_number for undo tree
    -- This creates branches when executing after undo
    command.parent_sequence_number = current_sequence_number

    -- If we appear to be at the root (nil) but there is existing history,
    -- default to chaining off the latest command so we don't orphan the new entry.
    if not command.parent_sequence_number then
        local candidate_parent = sequence_number - 1
        if candidate_parent > 0 then
            command.parent_sequence_number = candidate_parent
        end
    end

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
            if rollback_tx then rollback_tx:exec() end
            last_sequence_number = last_sequence_number - 1
            result.error_message = "FATAL: Cannot execute command with NULL parent (would break undo tree)"
            return result
        end
    end

    -- VALIDATION: If parent exists, verify it actually exists in database
    if command.parent_sequence_number then
        local verify_parent = db:prepare("SELECT 1 FROM commands WHERE sequence_number = ?")
        if verify_parent then
            verify_parent:bind_value(1, command.parent_sequence_number)
            if not (verify_parent:exec() and verify_parent:next()) then
                print(string.format("ERROR: Command %d references non-existent parent %d!",
                    sequence_number, command.parent_sequence_number))
                print("ERROR: Parent command was deleted or never existed - broken referential integrity")
                local rollback_tx = db:prepare("ROLLBACK")
                if rollback_tx then rollback_tx:exec() end
                last_sequence_number = last_sequence_number - 1
                result.error_message = "FATAL: Cannot execute command with non-existent parent (would break undo tree)"
                return result
            end
        end
    end

    -- Update command with state hashes
    update_command_hashes(command, pre_hash)

    -- Capture playhead and selection state BEFORE command execution (pre-state model)
    local timeline_state = require('ui.timeline.timeline_state')
    command.playhead_time = timeline_state.get_playhead_time()
    capture_pre_selection_for_command(command)

    -- Execute the actual command logic
    local execution_success = execute_command_implementation(command)

    if execution_success then
        command.status = "Executed"
        command.executed_at = os.time()

        capture_post_selection_for_command(command)

        -- Calculate post-execution hash
        local post_hash = calculate_state_hash(command.project_id)
        command.post_hash = post_hash

        -- Save command to database
        if command:save(db) then
            result.success = true
            result.result_data = command:serialize()
            current_state_hash = post_hash

            -- Move to HEAD after executing new command
            set_current_sequence_number(sequence_number)

            -- Save undo position to database (persists across sessions)
            save_undo_position()

            -- Create snapshot every N commands for fast event replay
            local snapshot_mgr = require('core.snapshot_manager')
            local snapshot_sequence_id = get_current_stack_sequence_id(true)
            if snapshot_sequence_id and snapshot_mgr.should_snapshot(sequence_number) then
                local db_module = require('core.database')
                local clips = db_module.load_clips(snapshot_sequence_id)
                snapshot_mgr.create_snapshot(db, snapshot_sequence_id, sequence_number, clips)
            end

            -- COMMIT TRANSACTION: Everything succeeded
            local commit_tx = db:prepare("COMMIT")
            if commit_tx then commit_tx:exec() end

            -- Reload timeline state to pick up database changes
            -- This triggers listener notifications → automatic view redraws
            timeline_state.reload_clips()
        else
            result.error_message = "Failed to save command to database"
            -- ROLLBACK: Command execution succeeded but save failed
            local rollback_tx = db:prepare("ROLLBACK")
            if rollback_tx then rollback_tx:exec() end
            last_sequence_number = last_sequence_number - 1  -- Revert sequence number
        end
    else
        command.status = "Failed"
        result.error_message = last_error_message ~= "" and last_error_message or "Command execution failed"
        last_error_message = ""
        -- ROLLBACK: Command execution failed
        local rollback_tx = db:prepare("ROLLBACK")
        if rollback_tx then rollback_tx:exec() end
        last_sequence_number = last_sequence_number - 1  -- Revert sequence number
    end

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
        SELECT id, command_type, command_args, sequence_number, parent_sequence_number, pre_hash, post_hash, timestamp, playhead_time,
               selected_clip_ids, selected_edge_infos, selected_clip_ids_pre, selected_edge_infos_pre
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
            playhead_time = query:value(8) or 0,  -- Playhead position BEFORE this command
            selected_clip_ids = query:value(9) or "[]",
            selected_edge_infos = query:value(10) or "[]",
            selected_clip_ids_pre = query:value(11) or "[]",
            selected_edge_infos_pre = query:value(12) or "[]",
        }

        -- Parse command_args JSON to populate parameters
        local command_args_json = query:value(2)
        if command_args_json and command_args_json ~= "" and command_args_json ~= "{}" then
            local success, params = pcall(qt_json_decode, command_args_json)
            if success and params then
                command.parameters = params
            end
        end

        local Command = require('command')
        setmetatable(command, {__index = Command})
        return command
    end

    return nil
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

        local project_id = nil
        do
            local project_query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
            if project_query then
                project_query:bind_value(1, sequence_id)
                if project_query:exec() and project_query:next() then
                    project_id = project_query:value(0)
                end
            end
        end

        if not project_id then
            error(string.format("FATAL: Cannot determine project_id for sequence '%s' - cannot safely clear media table", sequence_id))
        end

        -- Step 1: Load snapshot if available
        local snapshot_mgr = require('core.snapshot_manager')
        local snapshot = snapshot_mgr.load_snapshot(db, sequence_id)

        local start_sequence = 0
        local clips = {}

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

        if snapshot and snapshot.sequence_number <= target_sequence_number then
            -- Start from snapshot
            start_sequence = snapshot.sequence_number
            clips = snapshot.clips
            print(string.format("Starting from snapshot at sequence %d with %d clips",
                start_sequence, #clips))
        else
            -- No snapshot or snapshot is ahead of target, start from beginning
            print("No snapshot available, replaying from beginning")
            start_sequence = 0
            clips = {}
        end

        -- Step 2: Determine which clips to preserve (initial state before any commands)
        -- If we have a snapshot, use it. Otherwise, start from EMPTY state.
        local initial_clips = {}
        local initial_media = {}

        if snapshot and #clips > 0 then
            -- We have a snapshot - use it as the base state
            initial_clips = clips
            print(string.format("Using snapshot with %d clips as initial state", #initial_clips))
        elseif start_sequence > 0 then
            -- Fallback: reuse persisted clips if we have prior commands but no snapshot
            local db_module = require('core.database')
            initial_clips = db_module.load_clips(sequence_id) or {}
            if #initial_clips > 0 then
                print(string.format("Using current database state with %d clips as baseline", #initial_clips))
            else
                print("Starting from empty initial state (no snapshot)")
            end
        elseif cached_initial_clips then
            initial_clips = clone_list(cached_initial_clips, clone_clip_entry)
            print(string.format("Using cached initial clip state with %d clip(s)", #initial_clips))
        else
            -- No snapshot and we're replaying from the very beginning; start empty
            print("Starting from empty initial state (no snapshot)")
        end

        if cached_initial_media then
            initial_media = clone_list(cached_initial_media, clone_media_entry)
            print(string.format("Using cached initial media state with %d item(s)", #initial_media))
        end

        -- Step 3: Clear ALL clips and media (we'll restore initial state + replay commands)
        local delete_clips_query = db:prepare("DELETE FROM clips WHERE track_id IN (SELECT id FROM tracks WHERE sequence_id = ?)")
        if delete_clips_query then
            delete_clips_query:bind_value(1, sequence_id)
            delete_clips_query:exec()
            print("Cleared all clips from database")
        end

        -- Also clear all media for the project (ImportMedia commands will recreate them)
        -- Get project_id from sequence
       local delete_media_query = db:prepare("DELETE FROM media WHERE project_id = ?")
        if delete_media_query then
           delete_media_query:bind_value(1, project_id)
           delete_media_query:exec()
           print(string.format("Cleared all media for project '%s' from database for replay", project_id))
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
            print("Cleared master tracks for replay")
        end

        local delete_master_sequences = db:prepare([[
            DELETE FROM sequences
            WHERE project_id = ? AND kind != 'timeline'
        ]])
        if delete_master_sequences then
            delete_master_sequences:bind_value(1, project_id)
            delete_master_sequences:exec()
            print("Cleared master sequences for replay")
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
            for _, media in ipairs(initial_media) do
                local duration = tonumber(media.duration) or 0
                if duration > 0 then
                    local restored_media = Media.create(media)
                    if restored_media then
                        restored_media.id = media.id
                        restored_media.project_id = media.project_id
                        if restored_media:save(db) then
                            restored_count = restored_count + 1
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
                    (id, project_id, name, kind, frame_rate, width, height,
                     timecode_start, playhead_time, selected_clip_ids, selected_edge_infos,
                     viewport_start_time, viewport_duration, mark_in_time, mark_out_time,
                     current_sequence_number)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]])
                if seq_insert then
                    for _, seq in ipairs(cached_initial_master.sequences) do
                        seq_insert:bind_value(1, seq.id)
                        seq_insert:bind_value(2, seq.project_id)
                        seq_insert:bind_value(3, seq.name)
                        seq_insert:bind_value(4, seq.kind)
                        seq_insert:bind_value(5, seq.frame_rate or 0)
                        seq_insert:bind_value(6, seq.width or 0)
                        seq_insert:bind_value(7, seq.height or 0)
                        seq_insert:bind_value(8, seq.timecode_start or 0)
                        seq_insert:bind_value(9, seq.playhead_time or 0)
                        seq_insert:bind_value(10, seq.selected_clip_ids)
                        seq_insert:bind_value(11, seq.selected_edge_infos)
                        seq_insert:bind_value(12, seq.viewport_start_time or 0)
                        seq_insert:bind_value(13, seq.viewport_duration or 10000)
                        seq_insert:bind_value(14, seq.mark_in_time)
                        seq_insert:bind_value(15, seq.mark_out_time)
                        seq_insert:bind_value(16, seq.current_sequence_number)
                        seq_insert:exec()
                        seq_insert:reset()
                        seq_insert:clear_bindings()
                    end
                    seq_insert:finalize()
                    print(string.format("Restored %d master sequences as initial state", #cached_initial_master.sequences))
                end
            end

            if cached_initial_master.tracks and #cached_initial_master.tracks > 0 then
                local track_insert = db:prepare([[
                    INSERT OR REPLACE INTO tracks
                    (id, sequence_id, name, track_type, track_index,
                     enabled, locked, muted, soloed, volume, pan)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]])
                if track_insert then
                    for _, track in ipairs(cached_initial_master.tracks) do
                        track_insert:bind_value(1, track.id)
                        track_insert:bind_value(2, track.sequence_id)
                        track_insert:bind_value(3, track.name)
                        track_insert:bind_value(4, track.track_type)
                        track_insert:bind_value(5, track.track_index or 0)
                        track_insert:bind_value(6, track.enabled and 1 or 0)
                        track_insert:bind_value(7, track.locked and 1 or 0)
                        track_insert:bind_value(8, track.muted and 1 or 0)
                        track_insert:bind_value(9, track.soloed and 1 or 0)
                        track_insert:bind_value(10, track.volume or 1.0)
                        track_insert:bind_value(11, track.pan or 0.0)
                        track_insert:exec()
                        track_insert:reset()
                        track_insert:clear_bindings()
                    end
                    track_insert:finalize()
                    print(string.format("Restored %d master tracks as initial state", #cached_initial_master.tracks))
                end
            end

            if cached_initial_master.clips and #cached_initial_master.clips > 0 then
                local clip_insert = db:prepare([[
                    INSERT OR REPLACE INTO clips
                    (id, project_id, clip_kind, name, track_id, media_id,
                     source_sequence_id, parent_clip_id, owner_sequence_id,
                     start_time, duration, source_in, source_out, enabled, offline)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]])

                local function insert_clip_row(clip)
                    clip_insert:bind_value(1, clip.id)
                    clip_insert:bind_value(2, clip.project_id)
                    clip_insert:bind_value(3, clip.clip_kind)
                    clip_insert:bind_value(4, clip.name or "")
                    clip_insert:bind_value(5, clip.track_id)
                    clip_insert:bind_value(6, clip.media_id)
                    clip_insert:bind_value(7, clip.source_sequence_id)
                    clip_insert:bind_value(8, clip.parent_clip_id)
                    clip_insert:bind_value(9, clip.owner_sequence_id)
                    clip_insert:bind_value(10, clip.start_time or 0)
                    clip_insert:bind_value(11, clip.duration or 1)
                    clip_insert:bind_value(12, clip.source_in or 0)
                    clip_insert:bind_value(13, clip.source_out or ((clip.source_in or 0) + (clip.duration or 1)))
                    clip_insert:bind_value(14, clip.enabled and 1 or 0)
                    clip_insert:bind_value(15, clip.offline and 1 or 0)
                    clip_insert:exec()
                    clip_insert:reset()
                    clip_insert:clear_bindings()
                end

                if clip_insert then
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
        end

        if #initial_clips > 0 then
            local Clip = require('models.clip')
            for _, clip in ipairs(initial_clips) do
                -- Recreate clip in database
                local restored_clip = Clip.create(clip.name or "", clip.media_id)
                restored_clip.id = clip.id  -- Preserve original ID
                restored_clip.track_id = clip.track_id
                restored_clip.start_time = clip.start_time
                restored_clip.duration = clip.duration
                restored_clip.source_in = clip.source_in
                restored_clip.source_out = clip.source_out
                restored_clip.enabled = clip.enabled
                restored_clip:save(db)
            end
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
                    SELECT id, command_type, command_args, sequence_number, parent_sequence_number, pre_hash, post_hash, timestamp, playhead_time, selected_clip_ids, selected_edge_infos, selected_clip_ids_pre, selected_edge_infos_pre
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
                        playhead_time = find_query:value(8),
                        selected_clip_ids = find_query:value(9),
                        selected_edge_infos = find_query:value(10),
                        selected_clip_ids_pre = find_query:value(11),
                        selected_edge_infos_pre = find_query:value(12)
                    })

                    -- Move to parent
                    local parent = find_query:value(4)
                    -- Check for NULL parent (only error if not the first command)
                    if not parent then
                        if current_seq == 1 then
                            -- First command with NULL parent is valid
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
                    print(string.format("WARNING: Could not find command with sequence %d", current_seq))
                    break
                end
            end

            print(string.format("Replaying %d commands on active branch to sequence %d", #command_chain, target_sequence_number))

            local Command = require("command")
            local commands_replayed = 0
            local final_playhead_time = 0
            local final_selected_clip_ids = "[]"
            local final_selected_edge_infos = "[]"

            for _, cmd_data in ipairs(command_chain) do
                -- Restore selection state prior to executing this command
                restore_selection_from_serialized(cmd_data.selected_clip_ids_pre, cmd_data.selected_edge_infos_pre)

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
                timeline_state.set_playhead_time(cmd_data.playhead_time or 0)

                -- Execute the command (but don't save it again - it's already in commands table)
                local execution_success = execute_command_implementation(command)

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
                final_playhead_time = cmd_data.playhead_time or 0
                final_selected_clip_ids = cmd_data.selected_clip_ids or "[]"
                final_selected_edge_infos = cmd_data.selected_edge_infos or "[]"
            end

            print(string.format("✅ Replayed %d commands successfully", commands_replayed))
            restore_selection_from_serialized(final_selected_clip_ids, final_selected_edge_infos)
        else
            -- No commands to replay - reset to initial state
            timeline_state.set_playhead_time(0)
            timeline_state.set_selection({})
            print("No commands to replay - reset playhead and selection to initial state")
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

    -- Calculate target sequence (parent of current command for branching support)
    -- In a branching history, undo follows the parent link, not sequence_number - 1
    local target_sequence = current_command.parent_sequence_number or 0

    print(string.format("  Will replay from 0 to %d", target_sequence))

    -- Replay events up to target (or clear all if target is 0)
    local replay_success = true
    if target_sequence > 0 then
        replay_success = M.replay_events(sequence_id, target_sequence)
    else
        replay_success = M.replay_events(sequence_id, 0)
    end

    if replay_success then
        -- Restore playhead to position BEFORE the undone command (i.e., AFTER the last valid command)
        -- This is stored in current_command.playhead_time
        local restored_playhead = current_command.playhead_time or 0
        timeline_state.set_playhead_time(restored_playhead)
        print(string.format("Restored playhead to %s", format_timecode_for_log(restored_playhead)))

        -- Move current_sequence_number back
        local new_position = target_sequence > 0 and target_sequence or nil
        set_current_sequence_number(new_position)

        -- Save undo position to database (persists across sessions)
        save_undo_position()

        -- Reload timeline state to pick up database changes
        -- This triggers listener notifications → automatic view redraws
        timeline_state.reload_clips()
        restore_selection_from_serialized(current_command.selected_clip_ids_pre, current_command.selected_edge_infos_pre)
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

    if not db then
        print("No database connection")
        return {success = false, error_message = "No database connection"}
    end

    -- Get the next command in the active branch
    -- In a branching history, redo follows the most recently created child
    -- (highest sequence_number with parent = current_sequence_number)
    local current_pos = current_sequence_number or 0

    -- Find all children of current position and pick the most recent one
    local query = db:prepare([[
        SELECT sequence_number, command_type
        FROM commands
        WHERE parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0)
        ORDER BY sequence_number DESC
        LIMIT 1
    ]])

    if not query then
        print("Failed to prepare redo query")
        return {success = false, error_message = "Failed to prepare redo query"}
    end

    query:bind_value(1, current_pos)
    query:bind_value(2, current_pos)

    if not query:exec() or not query:next() then
        print("Nothing to redo")
        return {success = false, error_message = "Nothing to redo"}
    end

    local target_sequence = query:value(0)
   local command_type = query:value(1)
   print(string.format("Redoing command: %s (seq %d)", command_type, target_sequence))

    -- Replay events up to target sequence
    local replay_success = M.replay_events(sequence_id, target_sequence)

    if replay_success then
        -- Move current_sequence_number forward
        set_current_sequence_number(target_sequence)

        -- Save undo position to database (persists across sessions)
        save_undo_position()

        local restored_command = M.get_last_command(active_project_id)

        -- Reload timeline state to pick up database changes
        -- This triggers listener notifications → automatic view redraws
        local timeline_state = require('ui.timeline.timeline_state')
        timeline_state.reload_clips()

        if restored_command then
            local selection_restored = false

            if db and current_sequence_number then
                local next_query = db:prepare([[
                    SELECT sequence_number, selected_clip_ids_pre, selected_edge_infos_pre
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
                            if next_clip_ids_pre ~= nil or next_edge_infos_pre ~= nil then
                                restore_selection_from_serialized(next_clip_ids_pre, next_edge_infos_pre)
                                selection_restored = true
                            end
                        end
                    end
                end
            end

            if not selection_restored then
                restore_selection_from_serialized(restored_command.selected_clip_ids, restored_command.selected_edge_infos)
            end
        end

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

    print(string.format("✅ Imported %d sequence(s), %d track(s), %d clip(s)",
        #create_result.sequence_ids,
        #create_result.track_ids,
        #create_result.clip_ids))

    return true
end

command_undoers["ImportFCP7XML"] = function(command)
    -- Delete all created entities
    local sequence_ids = command:get_parameter("created_sequence_ids") or {}
    local track_ids = command:get_parameter("created_track_ids") or {}
    local clip_ids = command:get_parameter("created_clip_ids") or {}

    -- Delete in reverse order (clips, tracks, sequences)
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
                            start_time = clip_data.start_time,
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
                            start_time = clip_data.start_time,
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
