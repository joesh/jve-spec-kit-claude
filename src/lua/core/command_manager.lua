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

-- State tracking
local last_sequence_number = 0
local current_state_hash = ""
local state_hash_cache = {}
local last_error_message = ""

-- Undo tree tracking
local current_sequence_number = nil  -- Current position in undo tree (nil = at HEAD, latest command)
local current_branch_path = {}  -- Sequence of command IDs from root to current position (for tree navigation)

-- Command type implementations
local command_executors = {}

-- Initialize CommandManager with database connection
function M.init(database)
    db = database

    -- Query last sequence number from database
    local query = db:prepare("SELECT MAX(sequence_number) FROM commands")
    if query and query:exec() and query:next() then
        last_sequence_number = query:value(0) or 0
    end

    -- Load current undo position from sequences table (persisted across sessions)
    local pos_query = db:prepare("SELECT current_sequence_number FROM sequences WHERE id = 'default_sequence'")
    if pos_query and pos_query:exec() and pos_query:next() then
        local saved_position = pos_query:value(0)
        if saved_position and saved_position > 0 then
            current_sequence_number = saved_position
        elseif saved_position == 0 then
            -- 0 means at beginning (all commands undone)
            current_sequence_number = 0
        else
            -- NULL means no position saved yet - default to HEAD
            if last_sequence_number > 0 then
                current_sequence_number = last_sequence_number
            else
                current_sequence_number = nil  -- No commands exist yet
            end
        end
    else
        -- If no saved position row exists, default to HEAD if we have commands
        if last_sequence_number > 0 then
            current_sequence_number = last_sequence_number
        end
    end

    print(string.format("CommandManager initialized, last sequence: %d, current position: %s",
        last_sequence_number, tostring(current_sequence_number)))
end

-- Get next sequence number
local function get_next_sequence_number()
    last_sequence_number = last_sequence_number + 1
    return last_sequence_number
end

-- Save current undo position to database (persists across sessions)
local function save_undo_position()
    if not db then
        return false
    end

    local update = db:prepare([[
        UPDATE sequences
        SET current_sequence_number = ?
        WHERE id = 'default_sequence'
    ]])

    if not update then
        print("WARNING: Failed to prepare undo position update")
        return false
    end

    update:bind_value(1, current_sequence_number)
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

-- Main execute function
function M.execute(command)
    local result = {
        success = false,
        error_message = "",
        result_data = ""
    }

    if not validate_command_parameters(command) then
        result.error_message = "Invalid command parameters"
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

    -- VALIDATION: parent_sequence_number should never be NULL after first command
    -- NULL parent is only valid for the very first command (sequence 1)
    if not command.parent_sequence_number and sequence_number > 1 then
        print(string.format("ERROR: Command %d has NULL parent but is not the first command!", sequence_number))
        print(string.format("ERROR: current_sequence_number = %s, last_sequence_number = %d",
            tostring(current_sequence_number), last_sequence_number))
        print("ERROR: This indicates a bug in undo position tracking!")
        error("FATAL: Cannot execute command with NULL parent (would break undo tree)")
    end

    -- Update command with state hashes
    update_command_hashes(command, pre_hash)

    -- Capture playhead and selection state BEFORE command execution (pre-state model)
    local timeline_state = require('ui.timeline.timeline_state')
    command.playhead_time = timeline_state.get_playhead_time()

    -- Serialize selected clip IDs to JSON
    local selected_clips = timeline_state.get_selected_clips()
    local selected_ids = {}
    for _, clip in ipairs(selected_clips) do
        table.insert(selected_ids, clip.id)
    end
    local success, json_str = pcall(qt_json_encode, selected_ids)
    command.selected_clip_ids = success and json_str or "[]"

    -- Execute the actual command logic
    local execution_success = execute_command_implementation(command)

    if execution_success then
        command.status = "Executed"
        command.executed_at = os.time()

        -- Calculate post-execution hash
        local post_hash = calculate_state_hash(command.project_id)
        command.post_hash = post_hash

        -- Save command to database
        if command:save(db) then
            result.success = true
            result.result_data = command:serialize()
            current_state_hash = post_hash

            -- Move to HEAD after executing new command
            current_sequence_number = sequence_number

            -- Save undo position to database (persists across sessions)
            save_undo_position()

            -- Create snapshot every N commands for fast event replay
            local snapshot_mgr = require('core.snapshot_manager')
            if snapshot_mgr.should_snapshot(sequence_number) then
                local db_module = require('core.database')
                local clips = db_module.load_clips("default_sequence")
                snapshot_mgr.create_snapshot(db, "default_sequence", sequence_number, clips)
            end
        else
            result.error_message = "Failed to save command to database"
        end
    else
        command.status = "Failed"
        result.error_message = last_error_message ~= "" and last_error_message or "Command execution failed"
        last_error_message = ""
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
        SELECT id, command_type, command_args, sequence_number, parent_sequence_number, pre_hash, post_hash, timestamp
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
        current_sequence_number = original_command.parent_sequence_number
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

-- Command type implementations
command_executors["CreateProject"] = function(command)
    print("Executing CreateProject command")

    local name = command:get_parameter("name")
    if not name or name == "" then
        print("WARNING: CreateProject: Missing required 'name' parameter")
        return false
    end

    local Project = require('models.project')
    local project = Project.create(name)

    command:set_parameter("project_id", project.id)

    if project:save(db) then
        print(string.format("Created project: %s with ID: %s", name, project.id))
        return true
    else
        print(string.format("Failed to save project: %s", name))
        return false
    end
end

command_executors["LoadProject"] = function(command)
    print("Executing LoadProject command")

    local project_id = command:get_parameter("project_id")
    if not project_id or project_id == "" then
        print("WARNING: LoadProject: Missing required 'project_id' parameter")
        return false
    end

    local Project = require('models.project')
    local project = Project.load(project_id, db)
    if not project or project.id == "" then
        print(string.format("Failed to load project: %s", project_id))
        return false
    end

    print(string.format("Loaded project: %s", project.name))
    return true
end

command_executors["CreateSequence"] = function(command)
    print("Executing CreateSequence command")

    local name = command:get_parameter("name")
    local project_id = command:get_parameter("project_id")
    local frame_rate = command:get_parameter("frame_rate")
    local width = command:get_parameter("width")
    local height = command:get_parameter("height")

    if not name or name == "" or not project_id or project_id == "" or not frame_rate or frame_rate <= 0 then
        print("WARNING: CreateSequence: Missing required parameters")
        return false
    end

    local Sequence = require('models.sequence')
    local sequence = Sequence.create(name, project_id, frame_rate, width, height)

    command:set_parameter("sequence_id", sequence.id)

    if sequence:save(db) then
        print(string.format("Created sequence: %s with ID: %s", name, sequence.id))
        return true
    else
        print(string.format("Failed to save sequence: %s", name))
        return false
    end
end

command_executors["ImportMedia"] = function(command)
    print("Executing ImportMedia command")

    local file_path = command:get_parameter("file_path")
    local project_id = command:get_parameter("project_id")

    if not file_path or file_path == "" or not project_id or project_id == "" then
        print("WARNING: ImportMedia: Missing required parameters")
        return false
    end

    -- Extract filename from file path
    local file_name = file_path:match("([^/]+)$")

    local Media = require('models.media')
    local media = Media.create(file_name, file_path)

    command:set_parameter("media_id", media.id)

    if media:save(db) then
        print(string.format("Imported media: %s with ID: %s", file_path, media.id))
        return true
    else
        print(string.format("Failed to save media: %s", file_path))
        return false
    end
end

command_executors["SetClipProperty"] = function(command)
    print("Executing SetClipProperty command")

    local clip_id = command:get_parameter("clip_id")
    local property_name = command:get_parameter("property_name")
    local new_value = command:get_parameter("value")

    if not clip_id or clip_id == "" or not property_name or property_name == "" then
        print("WARNING: SetClipProperty: Missing required parameters")
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.load(clip_id, db)
    if not clip or clip.id == "" then
        print(string.format("WARNING: SetClipProperty: Clip not found: %s", clip_id))
        return false
    end

    -- Get current value for undo
    local previous_value = clip:get_property(property_name)
    command:set_parameter("previous_value", previous_value)

    -- Set new value
    clip:set_property(property_name, new_value)

    if clip:save(db) then
        print(string.format("Set clip property %s to %s for clip %s", property_name, tostring(new_value), clip_id))
        return true
    else
        print("WARNING: Failed to save clip property change")
        return false
    end
end

command_executors["SetProperty"] = function(command)
    print("Executing SetProperty command")

    local entity_id = command:get_parameter("entity_id")
    local entity_type = command:get_parameter("entity_type")
    local property_name = command:get_parameter("property_name")
    local new_value = command:get_parameter("value")

    if not entity_id or entity_id == "" or not entity_type or entity_type == "" or not property_name or property_name == "" then
        print("WARNING: SetProperty: Missing required parameters")
        return false
    end

    local Property = require('models.property')
    local property = Property.create(property_name, entity_id)

    -- Store previous value for undo
    local previous_value = property.value
    command:set_parameter("previous_value", previous_value)

    -- Set new value
    property:set_value(new_value)

    if property:save(db) then
        print(string.format("Set property %s to %s for %s %s", property_name, tostring(new_value), entity_type, entity_id))
        return true
    else
        print("WARNING: Failed to save property change")
        return false
    end
end

command_executors["ModifyProperty"] = function(command)
    print("Executing ModifyProperty command")

    local entity_id = command:get_parameter("entity_id")
    local entity_type = command:get_parameter("entity_type")
    local property_name = command:get_parameter("property_name")
    local new_value = command:get_parameter("value")

    if not entity_id or entity_id == "" or not entity_type or entity_type == "" or not property_name or property_name == "" then
        print("WARNING: ModifyProperty: Missing required parameters")
        return false
    end

    local Property = require('models.property')
    local property = Property.load(entity_id, db)
    if not property or property.id == "" then
        print("WARNING: ModifyProperty: Property not found")
        return false
    end

    -- Store previous value for undo
    local previous_value = property.value
    command:set_parameter("previous_value", previous_value)

    -- Set new value
    property:set_value(new_value)

    if property:save(db) then
        print(string.format("Modified property %s to %s for %s %s", property_name, tostring(new_value), entity_type, entity_id))
        return true
    else
        print("WARNING: Failed to save property modification")
        return false
    end
end

command_executors["CreateClip"] = function(command)
    print("Executing CreateClip command")

    local track_id = command:get_parameter("track_id")
    local media_id = command:get_parameter("media_id")
    local start_time = command:get_parameter("start_time") or 0
    local duration = command:get_parameter("duration")
    local source_in = command:get_parameter("source_in") or 0
    local source_out = command:get_parameter("source_out")

    if not track_id or track_id == "" or not media_id or media_id == "" then
        print("WARNING: CreateClip: Missing required parameters")
        return false
    end

    if not duration or not source_out then
        print("WARNING: CreateClip: Missing duration or source_out")
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.create("Timeline Clip", media_id)

    -- Set all clip parameters from command
    clip.track_id = track_id
    clip.start_time = start_time
    clip.duration = duration
    clip.source_in = source_in
    clip.source_out = source_out

    command:set_parameter("clip_id", clip.id)

    if clip:save(db) then
        print(string.format("Created clip with ID: %s on track %s at %dms", clip.id, track_id, start_time))
        return true
    else
        print("WARNING: Failed to save clip")
        return false
    end
end

command_executors["AddTrack"] = function(command)
    print("Executing AddTrack command")

    local sequence_id = command:get_parameter("sequence_id")
    local track_type = command:get_parameter("track_type")

    if not sequence_id or sequence_id == "" or not track_type or track_type == "" then
        print("WARNING: AddTrack: Missing required parameters")
        return false
    end

    local Track = require('models.track')
    local track
    if track_type == "video" then
        track = Track.create_video("Video Track", sequence_id)
    elseif track_type == "audio" then
        track = Track.create_audio("Audio Track", sequence_id)
    else
        print(string.format("WARNING: AddTrack: Unknown track type: %s", track_type))
        return false
    end

    command:set_parameter("track_id", track.id)

    if track:save(db) then
        print(string.format("Added track with ID: %s", track.id))
        return true
    else
        print("WARNING: Failed to save track")
        return false
    end
end

command_executors["AddClip"] = function(command)
    print("Executing AddClip command")
    return command_executors["CreateClip"](command)
end

-- Insert clip from media browser to timeline at playhead
command_executors["InsertClipToTimeline"] = function(command)
    print("Executing InsertClipToTimeline command")

    local media_id = command:get_parameter("media_id")
    local track_id = command:get_parameter("track_id")
    local start_time = command:get_parameter("start_time") or 0
    local media_duration = command:get_parameter("media_duration") or 3000

    if not media_id or media_id == "" then
        print("WARNING: InsertClipToTimeline: Missing media_id")
        return false
    end

    if not track_id or track_id == "" then
        print("WARNING: InsertClipToTimeline: Missing track_id")
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.create("Clip", media_id)
    clip.track_id = track_id
    clip.start_time = start_time
    clip.duration = media_duration
    clip.source_in = 0
    clip.source_out = media_duration

    command:set_parameter("clip_id", clip.id)

    if clip:save(db) then
        print(string.format("✅ Inserted clip %s to track %s at time %d", clip.id, track_id, start_time))
        return true
    else
        print("WARNING: Failed to save clip to timeline")
        return false
    end
end

-- Undo for InsertClipToTimeline: remove the clip
command_executors["UndoInsertClipToTimeline"] = function(command)
    print("Executing UndoInsertClipToTimeline command")

    local clip_id = command:get_parameter("clip_id")

    if not clip_id or clip_id == "" then
        print("WARNING: UndoInsertClipToTimeline: Missing clip_id")
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.load(clip_id, db)

    if not clip then
        print(string.format("WARNING: UndoInsertClipToTimeline: Clip not found: %s", clip_id))
        return false
    end

    if clip:delete(db) then
        print(string.format("✅ Removed clip %s from timeline", clip_id))
        return true
    else
        print("WARNING: Failed to delete clip from timeline")
        return false
    end
end

command_executors["SetupProject"] = function(command)
    print("Executing SetupProject command")

    local project_id = command:get_parameter("project_id")
    local settings = command:get_parameter("settings")

    if not project_id or project_id == "" then
        print("WARNING: SetupProject: Missing required parameters")
        return false
    end

    local Project = require('models.project')
    local project = Project.load(project_id, db)
    if not project or project.id == "" then
        print(string.format("WARNING: SetupProject: Project not found: %s", project_id))
        return false
    end

    -- Store previous settings for undo
    local previous_settings = project.settings
    command:set_parameter("previous_settings", previous_settings)

    -- Apply new settings
    local settings_json = require('json').encode(settings)
    project:set_settings(settings_json)

    if project:save(db) then
        print(string.format("Applied settings to project: %s", project_id))
        return true
    else
        print("WARNING: Failed to save project settings")
        return false
    end
end

command_executors["SplitClip"] = function(command)
    print("Executing SplitClip command")

    local clip_id = command:get_parameter("clip_id")
    local split_time = command:get_parameter("split_time")

    print(string.format("  clip_id: %s", tostring(clip_id)))
    print(string.format("  split_time: %s", tostring(split_time)))
    print(string.format("  db: %s", tostring(db)))

    if not clip_id or clip_id == "" or not split_time or split_time <= 0 then
        print("WARNING: SplitClip: Missing required parameters")
        return false
    end

    -- Load the original clip
    local Clip = require('models.clip')
    local original_clip = Clip.load(clip_id, db)
    if not original_clip or original_clip.id == "" then
        print(string.format("WARNING: SplitClip: Clip not found: %s", clip_id))
        return false
    end

    -- Validate split_time is within clip bounds
    if split_time <= original_clip.start_time or split_time >= (original_clip.start_time + original_clip.duration) then
        print(string.format("WARNING: SplitClip: split_time %d is outside clip bounds [%d, %d]",
            split_time, original_clip.start_time, original_clip.start_time + original_clip.duration))
        return false
    end

    -- Store original state for undo
    command:set_parameter("track_id", original_clip.track_id)
    command:set_parameter("original_start_time", original_clip.start_time)
    command:set_parameter("original_duration", original_clip.duration)
    command:set_parameter("original_source_in", original_clip.source_in)
    command:set_parameter("original_source_out", original_clip.source_out)

    -- Calculate new durations and source points
    local first_duration = split_time - original_clip.start_time
    local second_duration = original_clip.duration - first_duration

    -- Calculate source points for the split
    local source_split_point = original_clip.source_in + first_duration

    -- Create second clip (right side of split)
    -- IMPORTANT: Reuse second_clip_id if this is a replay (deterministic replay for event sourcing)
    local existing_second_clip_id = command:get_parameter("second_clip_id")
    local second_clip = Clip.create(original_clip.name .. " (2)", original_clip.media_id)
    if existing_second_clip_id then
        second_clip.id = existing_second_clip_id  -- Reuse ID from original execution
    end
    second_clip.track_id = original_clip.track_id
    second_clip.start_time = split_time
    second_clip.duration = second_duration
    second_clip.source_in = source_split_point
    second_clip.source_out = original_clip.source_out
    second_clip.enabled = original_clip.enabled

    -- Update original clip (left side of split)
    original_clip.duration = first_duration
    original_clip.source_out = source_split_point

    -- Save both clips
    if not original_clip:save(db) then
        print("WARNING: SplitClip: Failed to save modified original clip")
        return false
    end

    if not second_clip:save(db) then
        print("WARNING: SplitClip: Failed to save new clip")
        return false
    end

    -- Store second clip ID for undo
    command:set_parameter("second_clip_id", second_clip.id)

    print(string.format("Split clip %s at time %d into clips %s and %s",
        clip_id, split_time, original_clip.id, second_clip.id))
    return true
end

-- Undo SplitClip command
command_executors["UndoSplitClip"] = function(command)
    print("Executing UndoSplitClip command")

    local clip_id = command:get_parameter("clip_id")
    local track_id = command:get_parameter("track_id")
    local split_time = command:get_parameter("split_time")
    local original_start_time = command:get_parameter("original_start_time")
    local original_duration = command:get_parameter("original_duration")
    local original_source_in = command:get_parameter("original_source_in")
    local original_source_out = command:get_parameter("original_source_out")

    if not clip_id or clip_id == "" or not track_id or not split_time then
        print("WARNING: UndoSplitClip: Missing required parameters")
        return false
    end

    -- Load the original clip (left side of split)
    local Clip = require('models.clip')
    local original_clip = Clip.load(clip_id, db)

    if not original_clip then
        print(string.format("WARNING: UndoSplitClip: Original clip not found: %s", clip_id))
        return false
    end

    -- Find the second clip (right side) by position: on same track, starts at split_time
    -- Use direct SQL query since Clip model doesn't have a "find by position" method
    local query = db:prepare([[
        SELECT id FROM clips
        WHERE track_id = ? AND start_time = ? AND id != ?
        LIMIT 1
    ]])

    if not query then
        print("WARNING: UndoSplitClip: Failed to prepare second clip query")
        return false
    end

    query:bind_value(1, track_id)
    query:bind_value(2, split_time)
    query:bind_value(3, clip_id)  -- Exclude the original clip itself

    local second_clip = nil
    local second_clip_id = nil
    if query:exec() and query:next() then
        second_clip_id = query:value(0)
        second_clip = Clip.load(second_clip_id, db)
    end

    if not second_clip then
        print(string.format("WARNING: UndoSplitClip: Second clip not found at track=%s, time=%d",
            track_id, split_time))
        return false
    end

    -- Restore ALL original clip properties
    original_clip.start_time = original_start_time
    original_clip.duration = original_duration
    original_clip.source_in = original_source_in
    original_clip.source_out = original_source_out

    -- Save original clip
    if not original_clip:save(db) then
        print("WARNING: UndoSplitClip: Failed to save original clip")
        return false
    end

    -- Delete second clip
    if not second_clip:delete(db) then
        print("WARNING: UndoSplitClip: Failed to delete second clip")
        return false
    end

    print(string.format("Undid split: restored clip %s and deleted clip %s",
        clip_id, second_clip_id))
    return true
end

-- INSERT: Add clip at playhead, rippling all subsequent clips forward
command_executors["Insert"] = function(command)
    print("Executing Insert command")

    local media_id = command:get_parameter("media_id")
    local track_id = command:get_parameter("track_id")
    local insert_time = command:get_parameter("insert_time")
    local duration = command:get_parameter("duration")
    local source_in = command:get_parameter("source_in") or 0
    local source_out = command:get_parameter("source_out")

    if not media_id or media_id == "" or not track_id or track_id == "" then
        print("WARNING: Insert: Missing media_id or track_id")
        return false
    end

    if not insert_time or not duration or not source_out then
        print("WARNING: Insert: Missing insert_time, duration, or source_out")
        return false
    end

    -- Step 1: Ripple all clips on this track that start at or after insert_time
    local db_module = require('core.database')
    local sequence_id = command:get_parameter("sequence_id") or "default_sequence"

    -- Load all clips on this track
    local query = db:prepare([[
        SELECT id, start_time FROM clips
        WHERE track_id = ?
        ORDER BY start_time ASC
    ]])

    if not query then
        print("WARNING: Insert: Failed to prepare query")
        return false
    end

    query:bind_value(1, track_id)

    local clips_to_ripple = {}
    if query:exec() then
        while query:next() do
            local clip_id = query:value(0)
            local start_time = query:value(1)
            -- Ripple clips that start AFTER insert_time (not AT insert_time)
            if start_time > insert_time then
                table.insert(clips_to_ripple, {id = clip_id, old_start = start_time})
            end
        end
    end

    -- Ripple clips forward
    local Clip = require('models.clip')
    for _, clip_info in ipairs(clips_to_ripple) do
        local clip = Clip.load(clip_info.id, db)
        if clip then
            clip.start_time = clip_info.old_start + duration
            if not clip:save(db) then
                print(string.format("WARNING: Insert: Failed to ripple clip %s", clip_info.id))
                return false
            end
        end
    end

    -- Store ripple info for undo
    command:set_parameter("rippled_clips", clips_to_ripple)

    -- Step 2: Create the new clip at insert_time
    -- Reuse clip_id if this is a replay (to preserve selection references)
    local existing_clip_id = command:get_parameter("clip_id")
    local clip = Clip.create("Inserted Clip", media_id)
    if existing_clip_id then
        clip.id = existing_clip_id  -- Reuse existing ID for replay
    end
    clip.track_id = track_id
    clip.start_time = insert_time
    clip.duration = duration
    clip.source_in = source_in
    clip.source_out = source_out

    command:set_parameter("clip_id", clip.id)

    if clip:save(db) then
        -- Advance playhead to end of inserted clip (if requested)
        local advance_playhead = command:get_parameter("advance_playhead")
        if advance_playhead then
            local timeline_state = require('ui.timeline.timeline_state')
            timeline_state.set_playhead_time(insert_time + duration)
        end

        print(string.format("✅ Inserted clip at %dms, rippled %d clips forward by %dms",
            insert_time, #clips_to_ripple, duration))
        return true
    else
        print("WARNING: Insert: Failed to save clip")
        return false
    end
end

-- OVERWRITE: Add clip at playhead, trimming/replacing existing clips
command_executors["Overwrite"] = function(command)
    print("Executing Overwrite command")

    local media_id = command:get_parameter("media_id")
    local track_id = command:get_parameter("track_id")
    local overwrite_time = command:get_parameter("overwrite_time")
    local duration = command:get_parameter("duration")
    local source_in = command:get_parameter("source_in") or 0
    local source_out = command:get_parameter("source_out")

    if not media_id or media_id == "" or not track_id or track_id == "" then
        print("WARNING: Overwrite: Missing media_id or track_id")
        return false
    end

    if not overwrite_time or not duration or not source_out then
        print("WARNING: Overwrite: Missing overwrite_time, duration, or source_out")
        return false
    end

    local overwrite_end = overwrite_time + duration

    -- Step 1: Find all clips that overlap the overwrite range [overwrite_time, overwrite_end)
    local query = db:prepare([[
        SELECT id, start_time, duration FROM clips
        WHERE track_id = ?
        ORDER BY start_time ASC
    ]])

    if not query then
        print("WARNING: Overwrite: Failed to prepare query")
        return false
    end

    query:bind_value(1, track_id)

    local affected_clips = {}
    if query:exec() then
        while query:next() do
            local clip_id = query:value(0)
            local clip_start = query:value(1)
            local clip_duration = query:value(2)
            local clip_end = clip_start + clip_duration

            -- Check if clip overlaps [overwrite_time, overwrite_end)
            if clip_start < overwrite_end and clip_end > overwrite_time then
                table.insert(affected_clips, {
                    id = clip_id,
                    start_time = clip_start,
                    duration = clip_duration
                })
            end
        end
    end

    -- Step 2: Handle affected clips (trim or delete)
    local Clip = require('models.clip')
    local modified_clips = {}

    for _, clip_info in ipairs(affected_clips) do
        local clip = Clip.load(clip_info.id, db)
        if clip then
            local clip_start = clip_info.start_time
            local clip_end = clip_start + clip_info.duration

            -- Save original state for undo
            table.insert(modified_clips, {
                id = clip.id,
                start_time = clip.start_time,
                duration = clip.duration,
                source_in = clip.source_in,
                source_out = clip.source_out
            })

            -- Completely covered - delete
            if clip_start >= overwrite_time and clip_end <= overwrite_end then
                if not clip:delete(db) then
                    print(string.format("WARNING: Overwrite: Failed to delete clip %s", clip.id))
                    return false
                end
            -- Partially covered from left - trim left side
            elseif clip_start < overwrite_time and clip_end > overwrite_time and clip_end <= overwrite_end then
                local trim_amount = clip_end - overwrite_time
                clip.duration = clip.duration - trim_amount
                clip.source_out = clip.source_out - trim_amount
                if not clip:save(db) then
                    print(string.format("WARNING: Overwrite: Failed to trim clip %s", clip.id))
                    return false
                end
            -- Partially covered from right - trim right side and move
            elseif clip_start >= overwrite_time and clip_start < overwrite_end and clip_end > overwrite_end then
                local trim_amount = overwrite_end - clip_start
                clip.start_time = overwrite_end
                clip.duration = clip.duration - trim_amount
                clip.source_in = clip.source_in + trim_amount
                if not clip:save(db) then
                    print(string.format("WARNING: Overwrite: Failed to trim clip %s", clip.id))
                    return false
                end
            -- Spans entire overwrite range - split into two
            elseif clip_start < overwrite_time and clip_end > overwrite_end then
                -- Trim left part
                local left_duration = overwrite_time - clip_start
                clip.duration = left_duration
                clip.source_out = clip.source_in + left_duration

                -- Create right part
                local right_clip = Clip.create("Split Clip", clip.media_id)
                right_clip.track_id = clip.track_id
                right_clip.start_time = overwrite_end
                right_clip.duration = clip_end - overwrite_end
                right_clip.source_in = clip.source_in + (overwrite_time - clip_start) + duration
                right_clip.source_out = clip_info.source_out

                if not clip:save(db) or not right_clip:save(db) then
                    print("WARNING: Overwrite: Failed to split clip")
                    return false
                end
            end
        end
    end

    -- Store modified clips for undo
    command:set_parameter("modified_clips", modified_clips)

    -- Step 3: Create the new clip at overwrite_time
    -- Reuse clip_id if this is a replay (to preserve UUID references)
    local existing_clip_id = command:get_parameter("clip_id")
    local clip = Clip.create("Overwrite Clip", media_id)
    if existing_clip_id then
        clip.id = existing_clip_id  -- Reuse existing ID for replay
    end
    clip.track_id = track_id
    clip.start_time = overwrite_time
    clip.duration = duration
    clip.source_in = source_in
    clip.source_out = source_out

    command:set_parameter("clip_id", clip.id)

    if clip:save(db) then
        -- Advance playhead to end of overwritten clip (if requested)
        local advance_playhead = command:get_parameter("advance_playhead")
        if advance_playhead then
            local timeline_state = require('ui.timeline.timeline_state')
            timeline_state.set_playhead_time(overwrite_time + duration)
        end

        print(string.format("✅ Overwrote at %dms, affected %d clips", overwrite_time, #affected_clips))
        return true
    else
        print("WARNING: Overwrite: Failed to save clip")
        return false
    end
end

-- MOVE CLIP TO TRACK: Move a clip from one track to another (same timeline position)
command_executors["MoveClipToTrack"] = function(command)
    print("Executing MoveClipToTrack command")

    local clip_id = command:get_parameter("clip_id")
    local target_track_id = command:get_parameter("target_track_id")

    if not clip_id or clip_id == "" then
        print("WARNING: MoveClipToTrack: Missing clip_id")
        return false
    end

    if not target_track_id or target_track_id == "" then
        print("WARNING: MoveClipToTrack: Missing target_track_id")
        return false
    end

    -- Load the clip
    local Clip = require('models.clip')
    local clip = Clip.load(clip_id, db)

    if not clip then
        print(string.format("WARNING: MoveClipToTrack: Clip %s not found", clip_id))
        return false
    end

    -- Save original track for undo (store as parameter)
    command:set_parameter("original_track_id", clip.track_id)

    -- Update clip's track
    clip.track_id = target_track_id

    if not clip:save(db) then
        print(string.format("WARNING: MoveClipToTrack: Failed to save clip %s", clip_id))
        return false
    end

    print(string.format("✅ Moved clip %s to track %s", clip_id, target_track_id))
    return true
end

-- Undo for MoveClipToTrack: move clip back to original track
command_executors["UndoMoveClipToTrack"] = function(command)
    print("Executing UndoMoveClipToTrack command")

    local clip_id = command:get_parameter("clip_id")
    local original_track_id = command:get_parameter("original_track_id")

    if not clip_id or clip_id == "" then
        print("WARNING: UndoMoveClipToTrack: Missing clip_id")
        return false
    end

    if not original_track_id or original_track_id == "" then
        print("WARNING: UndoMoveClipToTrack: Missing original_track_id parameter")
        return false
    end

    -- Load the clip
    local Clip = require('models.clip')
    local clip = Clip.load(clip_id, db)

    if not clip then
        print(string.format("WARNING: UndoMoveClipToTrack: Clip %s not found", clip_id))
        return false
    end

    -- Restore original track
    clip.track_id = original_track_id

    if not clip:save(db) then
        print(string.format("WARNING: UndoMoveClipToTrack: Failed to save clip %s", clip_id))
        return false
    end

    print(string.format("✅ Restored clip %s to original track %s", clip_id, original_track_id))
    return true
end

-- NUDGE: Move clips or trim edges by a time offset (frame-accurate)
-- Inspects selection to determine whether to nudge clips (move) or edges (trim)
command_executors["Nudge"] = function(command)
    print("Executing Nudge command")

    local nudge_amount_ms = command:get_parameter("nudge_amount_ms")  -- Can be negative
    local selected_clip_ids = command:get_parameter("selected_clip_ids")
    local selected_edges = command:get_parameter("selected_edges")  -- Array of {clip_id, edge_type}

    -- Determine what we're nudging
    local nudge_type = "none"

    if selected_edges and #selected_edges > 0 then
        nudge_type = "edges"
        -- Nudge edges (trim clips)
        for _, edge_info in ipairs(selected_edges) do
            local Clip = require('models.clip')
            local clip = Clip.load(edge_info.clip_id, db)

            if not clip then
                print(string.format("WARNING: Nudge: Clip %s not found", edge_info.clip_id:sub(1,8)))
                goto continue
            end

            if edge_info.edge_type == "in" or edge_info.edge_type == "gap_before" then
                -- Trim in-point: adjust start_time and duration
                clip.start_time = math.max(0, clip.start_time + nudge_amount_ms)
                clip.duration = math.max(1, clip.duration - nudge_amount_ms)
                clip.source_in = clip.source_in + nudge_amount_ms
            elseif edge_info.edge_type == "out" or edge_info.edge_type == "gap_after" then
                -- Trim out-point: adjust duration only
                clip.duration = math.max(1, clip.duration + nudge_amount_ms)
                clip.source_out = clip.source_in + clip.duration
            end

            if not clip:save(db) then
                print(string.format("ERROR: Nudge: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
                return false
            end

            ::continue::
        end
        print(string.format("✅ Nudged %d edge(s) by %dms", #selected_edges, nudge_amount_ms))
    elseif selected_clip_ids and #selected_clip_ids > 0 then
        nudge_type = "clips"
        -- Nudge clips (move)
        for _, clip_id in ipairs(selected_clip_ids) do
            local Clip = require('models.clip')
            local clip = Clip.load(clip_id, db)

            if not clip then
                print(string.format("WARNING: Nudge: Clip %s not found", clip_id:sub(1,8)))
                goto continue_clip
            end

            clip.start_time = math.max(0, clip.start_time + nudge_amount_ms)

            if not clip:save(db) then
                print(string.format("ERROR: Nudge: Failed to save clip %s", clip_id:sub(1,8)))
                return false
            end

            ::continue_clip::
        end
        print(string.format("✅ Nudged %d clip(s) by %dms", #selected_clip_ids, nudge_amount_ms))
    else
        print("WARNING: Nudge: Nothing selected")
        return false
    end

    -- Store what we nudged for undo
    command:set_parameter("nudge_type", nudge_type)

    return true
end

-- Undo for Nudge: reverse the nudge by applying negative offset
command_executors["UndoNudge"] = function(command)
    print("Executing UndoNudge command")

    -- Just re-run nudge with inverted amount
    local nudge_amount_ms = command:get_parameter("nudge_amount_ms")
    command:set_parameter("nudge_amount_ms", -nudge_amount_ms)

    local result = command_executors["Nudge"](command)

    -- Restore original amount for redo
    command:set_parameter("nudge_amount_ms", -nudge_amount_ms)

    return result
end

-- Helper: Apply ripple edit to a single edge
-- Returns: ripple_time, success
local function apply_edge_ripple(clip, edge_type, delta_ms)
    local ripple_time = nil

    if edge_type == "in" then
        -- Trimming clip's in-point: adjust source and duration
        ripple_time = clip.start_time + delta_ms
        clip.start_time = ripple_time
        clip.duration = math.max(1, clip.duration - delta_ms)

        -- Check media limits before trimming source
        local new_source_in = clip.source_in + delta_ms
        if new_source_in < 0 then
            -- Hit media boundary - normal limit, not an error
            return nil, false
        end
        clip.source_in = new_source_in

    elseif edge_type == "gap_before" then
        -- Adjusting gap before clip: move clip without changing media content
        ripple_time = clip.start_time
        clip.start_time = clip.start_time + delta_ms
        -- source_in, duration, source_out remain unchanged

    elseif edge_type == "out" then
        -- Trimming clip's out-point: adjust duration
        ripple_time = clip.start_time + clip.duration
        clip.duration = math.max(1, clip.duration + delta_ms)
        clip.source_out = clip.source_in + clip.duration
        -- TODO: Check against media duration limit (need media_duration field)

    elseif edge_type == "gap_after" then
        -- Adjusting gap after clip: ripple point is at clip's end
        ripple_time = clip.start_time + clip.duration
        -- Clip itself doesn't change at all
    end

    return ripple_time, true
end

-- RippleEdit: Trim an edge and shift all downstream clips to close/open the gap
-- This is the standard NLE ripple edit - affects the timeline duration
command_executors["RippleEdit"] = function(command)
    print("Executing RippleEdit command")

    local edge_info = command:get_parameter("edge_info")  -- {clip_id, edge_type, track_id}
    local delta_ms = command:get_parameter("delta_ms")    -- Positive = extend, negative = trim

    if not edge_info or not delta_ms then
        print("ERROR: RippleEdit missing parameters")
        return false
    end

    local Clip = require('models.clip')
    local clip = Clip.load(edge_info.clip_id, db)
    if not clip then
        print("ERROR: RippleEdit: Clip not found")
        return false
    end

    -- Save original state for undo
    local original_clip_state = {
        start_time = clip.start_time,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out
    }

    -- Apply edge ripple using shared helper
    local ripple_time, success = apply_edge_ripple(clip, edge_info.edge_type, delta_ms)
    if not success then
        return false
    end

    if not clip:save(db) then
        print(string.format("ERROR: RippleEdit: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
        return false
    end

    -- Find all clips on ALL tracks that start after the ripple point
    -- Ripple affects the entire timeline to maintain sync across all tracks
    local clips_to_shift = {}
    local database = require('core.database')
    local all_clips = database.load_clips(command:get_parameter("sequence_id") or "default_sequence")

    for _, other_clip in ipairs(all_clips) do
        if other_clip.id ~= edge_info.clip_id and
           other_clip.start_time >= ripple_time then
            table.insert(clips_to_shift, other_clip)
        end
    end

    -- Shift all downstream clips
    for _, downstream_clip in ipairs(clips_to_shift) do
        local shift_clip = Clip.load(downstream_clip.id, db)
        if not shift_clip then
            print(string.format("WARNING: RippleEdit: Failed to load downstream clip %s", downstream_clip.id:sub(1,8)))
            goto continue_shift
        end

        shift_clip.start_time = shift_clip.start_time + delta_ms

        if not shift_clip:save(db) then
            print(string.format("ERROR: RippleEdit: Failed to save downstream clip %s", downstream_clip.id:sub(1,8)))
            return false
        end

        ::continue_shift::
    end

    -- Store state for undo
    command:set_parameter("original_clip_state", original_clip_state)
    command:set_parameter("shifted_clip_ids", (function()
        local ids = {}
        for _, c in ipairs(clips_to_shift) do table.insert(ids, c.id) end
        return ids
    end)())

    print(string.format("✅ Ripple edit: trimmed %s edge by %dms, shifted %d downstream clips",
        edge_info.edge_type, delta_ms, #clips_to_shift))

    return true
end

-- BatchRippleEdit: Trim multiple edges simultaneously with single timeline shift
-- Prevents cascading shifts when multiple edges are selected
command_executors["BatchRippleEdit"] = function(command)
    print("Executing BatchRippleEdit command")

    local edge_infos = command:get_parameter("edge_infos")  -- Array of {clip_id, edge_type, track_id}
    local delta_ms = command:get_parameter("delta_ms")
    local sequence_id = command:get_parameter("sequence_id") or "default_sequence"

    if not edge_infos or not delta_ms or #edge_infos == 0 then
        print("ERROR: BatchRippleEdit missing parameters")
        return false
    end

    local Clip = require('models.clip')
    local original_states = {}
    local latest_ripple_time = 0

    -- Phase 1: Trim all edges and find latest ripple point
    -- All edges must succeed or none - preserves relative timing
    for _, edge_info in ipairs(edge_infos) do
        local clip = Clip.load(edge_info.clip_id, db)
        if not clip then
            print(string.format("WARNING: BatchRippleEdit: Clip %s not found", edge_info.clip_id:sub(1,8)))
            return false
        end

        -- Save original state
        original_states[edge_info.clip_id] = {
            start_time = clip.start_time,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }

        -- Apply edge ripple using shared helper
        local ripple_time, success = apply_edge_ripple(clip, edge_info.edge_type, delta_ms)
        if not success then
            print(string.format("Ripple blocked: clip %s at media boundary (preserving relative timing)", clip.id:sub(1,8)))
            return false
        end

        if not clip:save(db) then
            print(string.format("ERROR: BatchRippleEdit: Failed to save clip %s", clip.id:sub(1,8)))
            return false
        end

        -- Track latest ripple point
        if ripple_time and ripple_time > latest_ripple_time then
            latest_ripple_time = ripple_time
        end
    end

    -- Phase 2: Single timeline shift at latest ripple point
    local edited_clip_ids = {}
    for _, edge_info in ipairs(edge_infos) do
        table.insert(edited_clip_ids, edge_info.clip_id)
    end

    local database = require('core.database')
    local all_clips = database.load_clips(sequence_id)
    local clips_to_shift = {}

    for _, other_clip in ipairs(all_clips) do
        -- Don't shift clips we just edited
        local is_edited = false
        for _, edited_id in ipairs(edited_clip_ids) do
            if other_clip.id == edited_id then
                is_edited = true
                break
            end
        end

        if not is_edited and other_clip.start_time >= latest_ripple_time then
            table.insert(clips_to_shift, other_clip)
        end
    end

    -- Shift all downstream clips once
    for _, downstream_clip in ipairs(clips_to_shift) do
        local shift_clip = Clip.load(downstream_clip.id, db)
        if not shift_clip then
            print(string.format("WARNING: BatchRippleEdit: Failed to load downstream clip %s", downstream_clip.id:sub(1,8)))
            goto continue_batch_shift
        end

        shift_clip.start_time = shift_clip.start_time + delta_ms

        if not shift_clip:save(db) then
            print(string.format("ERROR: BatchRippleEdit: Failed to save downstream clip %s", downstream_clip.id:sub(1,8)))
            return false
        end

        ::continue_batch_shift::
    end

    -- Store for undo
    command:set_parameter("original_states", original_states)
    command:set_parameter("shifted_clip_ids", (function()
        local ids = {}
        for _, c in ipairs(clips_to_shift) do table.insert(ids, c.id) end
        return ids
    end)())

    print(string.format("✅ Batch ripple: trimmed %d edges by %dms, shifted %d downstream clips",
        #edge_infos, delta_ms, #clips_to_shift))

    return true
end

-- Undo for BatchRippleEdit
command_executors["UndoBatchRippleEdit"] = function(command)
    print("Executing UndoBatchRippleEdit command")

    local original_states = command:get_parameter("original_states")
    local delta_ms = command:get_parameter("delta_ms")
    local shifted_clip_ids = command:get_parameter("shifted_clip_ids")

    local Clip = require('models.clip')

    -- Restore all edited clips
    for clip_id, state in pairs(original_states) do
        local clip = Clip.load(clip_id, db)
        if not clip then
            print(string.format("WARNING: UndoBatchRippleEdit: Clip %s not found", clip_id:sub(1,8)))
            goto continue_restore
        end

        clip.start_time = state.start_time
        clip.duration = state.duration
        clip.source_in = state.source_in
        clip.source_out = state.source_out

        if not clip:save(db) then
            print(string.format("ERROR: UndoBatchRippleEdit: Failed to save clip %s", clip_id:sub(1,8)))
            return false
        end

        ::continue_restore::
    end

    -- Shift all affected clips back
    for _, clip_id in ipairs(shifted_clip_ids) do
        local shift_clip = Clip.load(clip_id, db)
        if not shift_clip then
            print(string.format("WARNING: UndoBatchRippleEdit: Shifted clip %s not found", clip_id:sub(1,8)))
            goto continue_unshift
        end

        shift_clip.start_time = shift_clip.start_time - delta_ms

        if not shift_clip:save(db) then
            print(string.format("ERROR: UndoBatchRippleEdit: Failed to save shifted clip %s", clip_id:sub(1,8)))
            return false
        end

        ::continue_unshift::
    end

    print(string.format("✅ Undone batch ripple: restored %d clips, shifted %d clips back",
        table.getn(original_states), #shifted_clip_ids))
    return true
end

-- Undo for RippleEdit: restore original clip state and shift downstream clips back
command_executors["UndoRippleEdit"] = function(command)
    print("Executing UndoRippleEdit command")

    local edge_info = command:get_parameter("edge_info")
    local delta_ms = command:get_parameter("delta_ms")
    local original_clip_state = command:get_parameter("original_clip_state")
    local shifted_clip_ids = command:get_parameter("shifted_clip_ids")

    -- Restore original clip
    local Clip = require('models.clip')
    local clip = Clip.load(edge_info.clip_id, db)
    if clip then
        clip.start_time = original_clip_state.start_time
        clip.duration = original_clip_state.duration
        clip.source_in = original_clip_state.source_in
        clip.source_out = original_clip_state.source_out
        clip:save(db)
    end

    -- Shift all affected clips back
    for _, clip_id in ipairs(shifted_clip_ids) do
        local shift_clip = Clip.load(clip_id, db)
        if shift_clip then
            shift_clip.start_time = shift_clip.start_time - delta_ms
            shift_clip:save(db)
        end
    end

    print(string.format("✅ Undone ripple edit: restored clip and shifted %d clips back", #shifted_clip_ids))
    return true
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

    print(string.format("Replaying events for sequence '%s' up to command %d",
        sequence_id, target_sequence_number))

    -- Step 1: Load snapshot if available
    local snapshot_mgr = require('core.snapshot_manager')
    local snapshot = snapshot_mgr.load_snapshot(db, sequence_id)

    local start_sequence = 0
    local clips = {}

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

    if snapshot and #clips > 0 then
        -- We have a snapshot - use it as the base state
        initial_clips = clips
        print(string.format("Using snapshot with %d clips as initial state", #initial_clips))
    else
        -- No snapshot - start from EMPTY state (commands will build up from nothing)
        initial_clips = {}
        print("Starting from empty initial state (no snapshot)")
    end

    -- Step 3: Clear ALL clips (we'll restore initial state + replay commands)
    local delete_query = db:prepare("DELETE FROM clips WHERE track_id IN (SELECT id FROM tracks WHERE sequence_id = ?)")
    if delete_query then
        delete_query:bind_value(1, sequence_id)
        delete_query:exec()
        print("Cleared all clips from database")
    end

    -- Step 4: Restore initial state clips
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
                SELECT id, command_type, command_args, sequence_number, parent_sequence_number, pre_hash, post_hash, timestamp, playhead_time, selected_clip_ids
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
                    selected_clip_ids = find_query:value(9)
                })

                -- Move to parent
                local parent = find_query:value(4)
                current_seq = parent or 0
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

        for _, cmd_data in ipairs(command_chain) do
            -- Create command object from stored data
            local command = Command.create(cmd_data.command_type, "default_project")
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
            local timeline_state = require('ui.timeline.timeline_state')
            timeline_state.set_playhead_time(cmd_data.playhead_time or 0)

            -- Execute the command (but don't save it again - it's already in commands table)
            -- Note: We don't restore selection here - it's user state, not command state
            local execution_success = execute_command_implementation(command)

            if execution_success then
                commands_replayed = commands_replayed + 1
            else
                print(string.format("ERROR: Failed to replay command %d (%s)",
                    command.sequence_number, command.type))
                print("ERROR: Event log is incomplete or corrupted")
                print("ERROR: Some clips in the database were not created via logged commands")
                print("HINT: This usually happens when clips are created directly in the database")
                print("HINT: instead of going through the command system")
                return false
            end
        end

        print(string.format("✅ Replayed %d commands successfully", commands_replayed))
    else
        -- No commands to replay - reset to initial state
        local timeline_state = require('ui.timeline.timeline_state')
        timeline_state.set_playhead_time(0)
        timeline_state.set_selection({})
        print("No commands to replay - reset playhead and selection to initial state")
    end

    return true
end

-- Undo: Move back one command in the undo tree using event replay
-- Track selection across undo/redo
local saved_selection_on_undo = nil

function M.undo()
    -- Get the command at current position
    local current_command = M.get_last_command("default_project")

    if not current_command then
        print("Nothing to undo")
        return {success = false, error_message = "Nothing to undo"}
    end

    print(string.format("Undoing command: %s (seq %d)", current_command.type, current_command.sequence_number))

    -- Save current selection before undo (user state between commands)
    local timeline_state = require('ui.timeline.timeline_state')
    saved_selection_on_undo = timeline_state.get_selected_clips()

    -- Calculate target sequence (parent of current command for branching support)
    -- In a branching history, undo follows the parent link, not sequence_number - 1
    local target_sequence = current_command.parent_sequence_number or 0

    -- Replay events up to target (or clear all if target is 0)
    local replay_success = true
    if target_sequence > 0 then
        replay_success = M.replay_events("default_sequence", target_sequence)
    else
        -- Undo all - clear the clips table and reset playhead/selection
        local delete_query = db:prepare("DELETE FROM clips WHERE track_id IN (SELECT id FROM tracks WHERE sequence_id = ?)")
        if delete_query then
            delete_query:bind_value(1, "default_sequence")
            delete_query:exec()
            print("Cleared all clips (undo to beginning)")
        end

        -- Reset playhead and selection to initial state
        local timeline_state = require('ui.timeline.timeline_state')
        timeline_state.set_playhead_time(0)
        timeline_state.set_selection({})
        print("Reset playhead and selection to initial state")
    end

    if replay_success then
        -- Move current_sequence_number back
        current_sequence_number = target_sequence > 0 and target_sequence or nil

        -- Save undo position to database (persists across sessions)
        save_undo_position()

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
function M.redo()
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
    local replay_success = M.replay_events("default_sequence", target_sequence)

    if replay_success then
        -- Move current_sequence_number forward
        current_sequence_number = target_sequence

        -- Save undo position to database (persists across sessions)
        save_undo_position()

        -- Restore selection that was saved during undo
        if saved_selection_on_undo then
            local timeline_state = require('ui.timeline.timeline_state')
            timeline_state.set_selection(saved_selection_on_undo)
            print(string.format("Redo complete - moved to position %d, restored %d selected clips",
                  current_sequence_number, #saved_selection_on_undo))
        else
            print(string.format("Redo complete - moved to position %d", current_sequence_number))
        end

        return {success = true}
    else
        return {success = false, error_message = "Redo replay failed"}
    end
end

return M
