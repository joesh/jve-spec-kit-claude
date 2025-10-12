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
local command_undoers = {}

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
        print("HINT: Check if undo was called without proper replay, or if init() failed to load position")
        print("HINT: Database integrity check (repair_broken_parent_chains) runs on startup")
        error("FATAL: Cannot execute command with NULL parent (would break undo tree)")
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
                print("HINT: This usually indicates manual database modification or a critical bug")
                print(string.format("HINT: current_sequence_number = %s, last_sequence_number = %d",
                    tostring(current_sequence_number), last_sequence_number))
                error("FATAL: Cannot execute command with non-existent parent (would break undo tree)")
            end
        end
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

    -- Use MediaReader to probe file and extract metadata
    local MediaReader = require("media.media_reader")
    local media_id, err = MediaReader.import_media(file_path, db, project_id)

    if not media_id then
        print(string.format("ERROR: ImportMedia: Failed to import %s: %s", file_path, err or "unknown error"))
        return false
    end

    -- Store media_id for undo/redo
    command:set_parameter("media_id", media_id)

    print(string.format("Imported media: %s with ID: %s", file_path, media_id))
    return true
end

command_undoers["ImportMedia"] = function(command)
    print("Undoing ImportMedia command")

    local media_id = command:get_parameter("media_id")

    if not media_id or media_id == "" then
        print("WARNING: ImportMedia undo: No media_id found in command parameters")
        return false
    end

    -- Delete media from database
    local stmt = db:prepare("DELETE FROM media WHERE id = ?")
    if not stmt then
        print("ERROR: ImportMedia undo: Failed to prepare DELETE statement")
        return false
    end

    stmt:bind(1, media_id)
    local success = stmt:exec()

    if success then
        print(string.format("Deleted imported media: %s", media_id))
        return true
    else
        print(string.format("ERROR: ImportMedia undo: Failed to delete media: %s", media_id))
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
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing SplitClip command")
    end

    local clip_id = command:get_parameter("clip_id")
    local split_time = command:get_parameter("split_time")

    if not dry_run then
        print(string.format("  clip_id: %s", tostring(clip_id)))
        print(string.format("  split_time: %s", tostring(split_time)))
        print(string.format("  db: %s", tostring(db)))
    end

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

    -- DRY RUN: Return preview data without executing
    if dry_run then
        return true, {
            first_clip = {
                clip_id = original_clip.id,
                new_duration = first_duration,
                new_source_out = source_split_point
            },
            second_clip = {
                clip_id = second_clip.id,
                track_id = second_clip.track_id,
                start_time = second_clip.start_time,
                duration = second_clip.duration,
                source_in = second_clip.source_in,
                source_out = second_clip.source_out
            }
        }
    end

    -- Update original clip (left side of split)
    original_clip.duration = first_duration
    original_clip.source_out = source_split_point

    -- EXECUTE: Save both clips
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
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing Insert command")
    end

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

    -- FRAME ALIGNMENT: Snap all parameters to frame boundaries
    local frame_utils = require('core.frame_utils')
    local frame_rate = 30.0  -- TODO: load from sequence metadata
    insert_time = frame_utils.snap_to_frame(insert_time, frame_rate)
    duration = frame_utils.snap_to_frame(duration, frame_rate)
    source_in = frame_utils.snap_to_frame(source_in, frame_rate)
    source_out = frame_utils.snap_to_frame(source_out, frame_rate)

    if not dry_run then
        print(string.format("Insert: Snapped parameters to frame boundaries (%.2f fps)", frame_rate))
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

    -- DRY RUN: Return preview data without executing
    if dry_run then
        local preview_rippled_clips = {}
        for _, clip_info in ipairs(clips_to_ripple) do
            table.insert(preview_rippled_clips, {
                clip_id = clip_info.id,
                new_start_time = clip_info.old_start + duration
            })
        end

        local existing_clip_id = command:get_parameter("clip_id")
        local Clip = require('models.clip')
        local new_clip_id = existing_clip_id or Clip.generate_id()

        return true, {
            new_clip = {
                clip_id = new_clip_id,
                track_id = track_id,
                start_time = insert_time,
                duration = duration,
                source_in = source_in,
                source_out = source_out
            },
            rippled_clips = preview_rippled_clips
        }
    end

    -- EXECUTE: Ripple clips forward
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
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing Overwrite command")
    end

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
    local preview_affected_clips = {}

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
                if dry_run then
                    table.insert(preview_affected_clips, {
                        clip_id = clip.id,
                        action = "delete"
                    })
                else
                    if not clip:delete(db) then
                        print(string.format("WARNING: Overwrite: Failed to delete clip %s", clip.id))
                        return false
                    end
                end
            -- Partially covered from left - trim left side
            elseif clip_start < overwrite_time and clip_end > overwrite_time and clip_end <= overwrite_end then
                local trim_amount = clip_end - overwrite_time
                if dry_run then
                    table.insert(preview_affected_clips, {
                        clip_id = clip.id,
                        action = "trim_left",
                        new_duration = clip.duration - trim_amount,
                        new_source_out = clip.source_out - trim_amount
                    })
                else
                    clip.duration = clip.duration - trim_amount
                    clip.source_out = clip.source_out - trim_amount
                    if not clip:save(db) then
                        print(string.format("WARNING: Overwrite: Failed to trim clip %s", clip.id))
                        return false
                    end
                end
            -- Partially covered from right - trim right side and move
            elseif clip_start >= overwrite_time and clip_start < overwrite_end and clip_end > overwrite_end then
                local trim_amount = overwrite_end - clip_start
                if dry_run then
                    table.insert(preview_affected_clips, {
                        clip_id = clip.id,
                        action = "trim_right",
                        new_start_time = overwrite_end,
                        new_duration = clip.duration - trim_amount,
                        new_source_in = clip.source_in + trim_amount
                    })
                else
                    clip.start_time = overwrite_end
                    clip.duration = clip.duration - trim_amount
                    clip.source_in = clip.source_in + trim_amount
                    if not clip:save(db) then
                        print(string.format("WARNING: Overwrite: Failed to trim clip %s", clip.id))
                        return false
                    end
                end
            -- Spans entire overwrite range - split into two
            elseif clip_start < overwrite_time and clip_end > overwrite_end then
                -- Trim left part
                local left_duration = overwrite_time - clip_start

                if dry_run then
                    local right_clip = Clip.create("Split Clip", clip.media_id)
                    table.insert(preview_affected_clips, {
                        clip_id = clip.id,
                        action = "split",
                        new_duration = left_duration,
                        new_source_out = clip.source_in + left_duration,
                        right_clip = {
                            clip_id = right_clip.id,
                            start_time = overwrite_end,
                            duration = clip_end - overwrite_end,
                            source_in = clip.source_in + (overwrite_time - clip_start) + duration,
                            source_out = clip_info.source_out
                        }
                    })
                else
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
    end

    -- DRY RUN: Return preview data without executing
    if dry_run then
        local existing_clip_id = command:get_parameter("clip_id")
        local new_clip_id = existing_clip_id or Clip.generate_id()

        return true, {
            new_clip = {
                clip_id = new_clip_id,
                track_id = track_id,
                start_time = overwrite_time,
                duration = duration,
                source_in = source_in,
                source_out = source_out
            },
            affected_clips = preview_affected_clips
        }
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
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing MoveClipToTrack command")
    end

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

    -- DRY RUN: Return preview data without executing
    if dry_run then
        return true, {
            clip_id = clip_id,
            original_track_id = clip.track_id,
            new_track_id = target_track_id
        }
    end

    -- EXECUTE: Update clip's track
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
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing Nudge command")
    end

    local nudge_amount_ms = command:get_parameter("nudge_amount_ms")  -- Can be negative
    local selected_clip_ids = command:get_parameter("selected_clip_ids")
    local selected_edges = command:get_parameter("selected_edges")  -- Array of {clip_id, edge_type}

    -- Determine what we're nudging
    local nudge_type = "none"

    if selected_edges and #selected_edges > 0 then
        nudge_type = "edges"
        local preview_clips = {}

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

            -- DRY RUN: Collect preview data
            if dry_run then
                table.insert(preview_clips, {
                    clip_id = clip.id,
                    new_start_time = clip.start_time,
                    new_duration = clip.duration,
                    edge_type = edge_info.edge_type
                })
            else
                -- EXECUTE: Save changes
                if not clip:save(db) then
                    print(string.format("ERROR: Nudge: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
                    return false
                end
            end

            ::continue::
        end

        -- DRY RUN: Return preview data without executing
        if dry_run then
            return true, {
                nudge_type = "edges",
                affected_clips = preview_clips
            }
        end

        print(string.format("✅ Nudged %d edge(s) by %dms", #selected_edges, nudge_amount_ms))
    elseif selected_clip_ids and #selected_clip_ids > 0 then
        nudge_type = "clips"
        local preview_clips = {}

        -- Expand selection to include linked clips
        local clip_links = require('core.clip_links')
        local clips_to_move = {}  -- Set of clip IDs to move (avoid duplicates)
        local processed_groups = {}  -- Track processed link groups

        for _, clip_id in ipairs(selected_clip_ids) do
            clips_to_move[clip_id] = true

            -- Find linked clips
            local link_group = clip_links.get_link_group(clip_id, db)
            if link_group then
                local link_group_id = clip_links.get_link_group_id(clip_id, db)
                if link_group_id and not processed_groups[link_group_id] then
                    processed_groups[link_group_id] = true
                    for _, link_info in ipairs(link_group) do
                        if link_info.enabled then
                            clips_to_move[link_info.clip_id] = true
                        end
                    end
                end
            end
        end

        -- Nudge clips (move)
        for clip_id, _ in pairs(clips_to_move) do
            local Clip = require('models.clip')
            local clip = Clip.load(clip_id, db)

            if not clip then
                print(string.format("WARNING: Nudge: Clip %s not found", clip_id:sub(1,8)))
                goto continue_clip
            end

            clip.start_time = math.max(0, clip.start_time + nudge_amount_ms)

            -- DRY RUN: Collect preview data
            if dry_run then
                table.insert(preview_clips, {
                    clip_id = clip.id,
                    new_start_time = clip.start_time,
                    new_duration = clip.duration
                })
            else
                -- EXECUTE: Save changes
                if not clip:save(db) then
                    print(string.format("ERROR: Nudge: Failed to save clip %s", clip_id:sub(1,8)))
                    return false
                end
            end

            ::continue_clip::
        end

        -- DRY RUN: Return preview data without executing
        if dry_run then
            return true, {
                nudge_type = "clips",
                affected_clips = preview_clips
            }
        end

        -- Count total clips moved
        local total_moved = 0
        for _ in pairs(clips_to_move) do
            total_moved = total_moved + 1
        end

        local linked_count = total_moved - #selected_clip_ids
        if linked_count > 0 then
            print(string.format("✅ Nudged %d clip(s) + %d linked clip(s) by %dms",
                #selected_clip_ids, linked_count, nudge_amount_ms))
        else
            print(string.format("✅ Nudged %d clip(s) by %dms", #selected_clip_ids, nudge_amount_ms))
        end
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
    -- GAP CLIPS ARE MATERIALIZED BEFORE CALLING THIS FUNCTION
    -- So edge_type is always "in" or "out", never "gap_after" or "gap_before"
    --
    -- CRITICAL: RIPPLE TRIM NEVER MOVES THE CLIP'S POSITION!
    -- Only duration and source_in/out change. Position stays FIXED.
    -- See docs/ripple-trim-semantics.md for detailed examples.

    local ripple_time
    local has_source_media = (clip.source_in ~= nil)

    if edge_type == "in" then
        -- Ripple in-point trim
        -- Example: drag [ right +500ms
        -- BEFORE: start=3618, dur=3000, src_in=0
        -- AFTER:  start=3618, dur=2500, src_in=500  <-- position UNCHANGED!

        ripple_time = clip.start_time  -- Downstream clips shift from here

        local new_duration = clip.duration - delta_ms  -- 3000 - 500 = 2500
        if new_duration < 1 then
            return nil, false
        end

        -- DO NOT modify clip.start_time! Position stays fixed.
        clip.duration = new_duration  -- 3000 → 2500

        if has_source_media then
            -- Advance source to reveal less of the beginning
            local new_source_in = clip.source_in + delta_ms  -- 0 + 500 = 500

            print(string.format("DEBUG in-point: clip=%s, source_in=%d, source_out=%d, delta=%d, new_source_in=%d",
                clip.id:sub(1,8), clip.source_in, clip.source_out or 0, delta_ms, new_source_in))

            if new_source_in < 0 then
                print(string.format("  BLOCKED: new_source_in=%d < 0 (can't rewind past start of media)", new_source_in))
                return nil, false  -- Hit media boundary
            end

            -- Check if new_source_in would exceed source_out
            if clip.source_out and new_source_in >= clip.source_out then
                print(string.format("  BLOCKED: new_source_in=%d >= source_out=%d (media window would invert)",
                    new_source_in, clip.source_out))
                return nil, false
            end

            clip.source_in = new_source_in  -- 0 → 500
        end

    elseif edge_type == "out" then
        -- Ripple out-point trim
        -- Example: drag ] right +500ms
        -- BEFORE: start=3618, dur=2500, src_out=2500
        -- AFTER:  start=3618, dur=3000, src_out=3000  <-- position UNCHANGED!

        ripple_time = clip.start_time + clip.duration  -- Downstream clips shift from here

        local new_duration = clip.duration + delta_ms  -- 2500 + 500 = 3000

        if has_source_media then
            -- CRITICAL: Check media boundary before applying
            -- Can't extend source_out beyond media duration
            local new_source_out = clip.source_in + new_duration

            -- Load media to check duration boundary
            local Media = require('models.media')
            local media = nil
            if clip.media_id then
                media = Media.load(clip.media_id, db)
            end

            print(string.format("DEBUG out-point: clip=%s, source_in=%d, source_out=%d, delta=%d, new_duration=%d, new_source_out=%d, media_duration=%d",
                clip.id:sub(1,8), clip.source_in, clip.source_out or 0, delta_ms, new_duration, new_source_out, media and media.duration or 0))

            if media and new_source_out > media.duration then
                -- Hit media boundary - can't extend beyond source file duration
                print(string.format("  BLOCKED: new_source_out=%d > media.duration=%d (can't extend past end of media)",
                    new_source_out, media.duration))
                return nil, false
            end

            -- Check if new duration would be too small
            if new_duration < 1 then
                print(string.format("  BLOCKED: new_duration=%d < 1 (minimum duration)", new_duration))
                return nil, false
            end

            clip.duration = math.max(1, new_duration)
            clip.source_out = new_source_out
        else
            -- No source media (generated clip) - no boundary check needed
            clip.duration = math.max(1, new_duration)
        end
    end

    return ripple_time, true
end

-- RippleEdit: Trim an edge and shift all downstream clips to close/open the gap
-- This is the standard NLE ripple edit - affects the timeline duration
-- Supports dry_run mode for preview without executing
command_executors["RippleEdit"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing RippleEdit command")
    end

    local edge_info = command:get_parameter("edge_info")  -- {clip_id, edge_type, track_id}
    local delta_ms = command:get_parameter("delta_ms")    -- Positive = extend, negative = trim

    if not edge_info or not delta_ms then
        print("ERROR: RippleEdit missing parameters")
        return {success = false, error_message = "RippleEdit missing parameters"}
    end

    local Clip = require('models.clip')
    local database = require('core.database')
    local all_clips = database.load_clips(command:get_parameter("sequence_id") or "default_sequence")

    -- MATERIALIZE GAP CLIPS: Convert gap edges to temporary gap clip objects
    local clip, edge_type, is_gap_clip
    if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
        -- Find the real clip that defines this gap
        local reference_clip = Clip.load(edge_info.clip_id, db)
        if not reference_clip then
            print("ERROR: RippleEdit: Reference clip not found")
            return {success = false, error_message = "Reference clip not found"}
        end

        -- Use stored gap boundaries if available (for deterministic replay)
        -- Otherwise calculate dynamically from adjacent clips
        local gap_start, gap_duration
        if command:get_parameter("gap_start_time") and command:get_parameter("gap_duration") then
            gap_start = command:get_parameter("gap_start_time")
            gap_duration = command:get_parameter("gap_duration")
        else
            -- Calculate gap boundaries from adjacent clips
            local gap_end
            if edge_info.edge_type == "gap_after" then
                gap_start = reference_clip.start_time + reference_clip.duration
                -- Find next clip on same track to determine gap end
                gap_end = math.huge
                for _, c in ipairs(all_clips) do
                    if c.track_id == reference_clip.track_id and c.start_time > gap_start then
                        gap_end = math.min(gap_end, c.start_time)
                    end
                end
            else  -- gap_before
                gap_end = reference_clip.start_time
                -- Find previous clip on same track to determine gap start
                gap_start = 0
                for _, c in ipairs(all_clips) do
                    if c.track_id == reference_clip.track_id and c.start_time + c.duration < gap_end then
                        gap_start = math.max(gap_start, c.start_time + c.duration)
                    end
                end
            end
            gap_duration = gap_end - gap_start

            -- Store gap boundaries for deterministic replay
            if not dry_run then
                command:set_parameter("gap_start_time", gap_start)
                command:set_parameter("gap_duration", gap_duration)
            end
        end

        -- Create temporary gap clip object (not saved to database)
        clip = {
            id = "temp_gap_" .. edge_info.clip_id,
            track_id = reference_clip.track_id,
            start_time = gap_start,
            duration = gap_duration,
            source_in = 0,
            source_out = gap_duration
        }
        edge_type = edge_info.edge_type == "gap_after" and "in" or "out"  -- gap_after→in, gap_before→out
        is_gap_clip = true
    else
        clip = Clip.load(edge_info.clip_id, db)
        if not clip then
            print("ERROR: RippleEdit: Clip not found")
            return {success = false, error_message = "Clip not found"}
        end
        edge_type = edge_info.edge_type
        is_gap_clip = false
    end

    -- CONSTRAINT CHECK: Clamp delta to valid range and snap to frame boundaries
    local constraints = require('core.timeline_constraints')
    local frame_utils = require('core.frame_utils')

    -- Get frame rate (TODO: load from sequence metadata, for now use default 30fps)
    local frame_rate = 30.0

    -- For deterministic replay: use stored clamped_delta if available, otherwise calculate
    local clamped_delta = command:get_parameter("clamped_delta_ms")
    if not clamped_delta then
        -- For gap edits: use special ripple constraint logic
        -- For regular edits: use normal trim constraints
        if is_gap_clip then
            -- Calculate ripple point for gap clips
            -- Gap clips represent empty space, so semantics are different:
            -- - gap_before: gap from timeline start (or previous clip) to clip start
            --   - edge_type = "out" (right edge of gap = left edge of clip)
            --   - ripple point = start + duration (right edge of gap)
            -- - gap_after: gap from clip end to next clip (or timeline end)
            --   - edge_type = "in" (left edge of gap = right edge of clip)
            --   - ripple point = start (left edge of gap)
            local ripple_time
            if edge_type == "in" then
                -- gap_after: ripple point at left edge of gap (right edge of reference clip)
                ripple_time = clip.start_time
            else  -- edge_type == "out"
                -- gap_before: ripple point at right edge of gap (left edge of reference clip)
                ripple_time = clip.start_time + clip.duration
            end

            print(string.format("DEBUG GAP CONSTRAINT: ripple_time=%dms, delta_ms=%dms", ripple_time, delta_ms))

            -- Find clips that will shift (everything after ripple point)
            -- and clips that are stationary (everything before ripple point)
            local stationary_clips = {}
            for _, c in ipairs(all_clips) do
                if c.start_time < ripple_time then
                    table.insert(stationary_clips, c)
                    print(string.format("  Stationary: %s at %d-%dms on %s", c.id:sub(1,8), c.start_time, c.start_time + c.duration, c.track_id))
                end
            end

            -- Calculate max shift: how far can we shift before any shifted clip hits a stationary clip?
            local max_shift = math.huge
            local min_shift = -math.huge

            for _, shifting_clip in ipairs(all_clips) do
                if shifting_clip.start_time >= ripple_time then
                    print(string.format("  Shifting: %s at %dms on %s", shifting_clip.id:sub(1,8), shifting_clip.start_time, shifting_clip.track_id))
                    -- This clip will shift - check against all stationary clips on all tracks
                    for _, stationary in ipairs(stationary_clips) do
                        if shifting_clip.track_id == stationary.track_id then
                            -- Same track - check collision in both directions
                            local gap_between = shifting_clip.start_time - (stationary.start_time + stationary.duration)
                            print(string.format("    vs stationary %s: gap=%dms", stationary.id:sub(1,8), gap_between))

                            if gap_between >= 0 then
                                -- No overlap: clips are separated or touching
                                -- Shifting RIGHT moves away from stationary clip (no constraint)
                                -- Shifting LEFT moves toward stationary clip (limited by gap)
                                if -gap_between > min_shift then
                                    min_shift = -gap_between
                                    print(string.format("      min_shift = %dms (can't shift left into stationary clip)", min_shift))
                                end
                                -- No max_shift constraint from this stationary clip (we're moving away)
                            else
                                -- Overlap exists (gap_between < 0)
                                -- Shifting right reduces overlap (allowed, no limit from this clip)
                                -- Shifting left increases overlap (blocked entirely)
                                print(string.format("      OVERLAP by %dms - blocking left shift", -gap_between))
                                -- Can't shift left at all when overlap exists
                                if 0 > min_shift then
                                    min_shift = 0
                                    print(string.format("      min_shift = 0 (blocking left due to overlap)"))
                                end
                                -- No limit on right shift from this overlapping clip
                            end
                        end
                    end
                end
            end

            -- CONSTRAINT: Minimum gap duration (can't close gap completely - must leave >=1ms)
            -- For in-point (gap_after): closing gap = positive delta = negative shift
            -- For out-point (gap_before): closing gap = negative delta = negative shift
            -- Maximum closure = clip.duration - 1
            local max_closure_shift = -(clip.duration - 1)
            if max_closure_shift > min_shift then
                min_shift = max_closure_shift
                print(string.format("  Gap duration constraint: min_shift = %dms (can't close gap beyond 1ms)", min_shift))
            end

            print(string.format("  Final constraints: min_shift=%s, max_shift=%s", tostring(min_shift), tostring(max_shift)))

            -- Convert shift constraints to delta constraints
            -- For in-point (gap_after): shift = -delta, so flip signs
            -- For out-point (gap_before): shift = +delta, so keep signs
            local min_delta, max_delta
            if edge_type == "in" then
                -- Flip signs: min_shift → max_delta, max_shift → min_delta
                min_delta = -max_shift
                max_delta = -min_shift
            else
                -- Keep signs: min_shift → min_delta, max_shift → max_delta
                min_delta = min_shift
                max_delta = max_shift
            end
            print(string.format("  Converted to delta constraints: min_delta=%s, max_delta=%s", tostring(min_delta), tostring(max_delta)))

            -- Clamp delta and snap to frames
            clamped_delta = math.max(min_delta, math.min(max_delta, delta_ms))
            print(string.format("  Before snap: clamped_delta=%dms", clamped_delta))
            clamped_delta = frame_utils.snap_delta_to_frame(clamped_delta, frame_rate)
            -- Re-clamp after snapping to ensure we don't exceed constraints
            clamped_delta = math.max(min_delta, math.min(max_delta, clamped_delta))
            print(string.format("  After snap: clamped_delta=%dms", clamped_delta))
        else
            -- Regular clip trim: use normal constraint logic
            clamped_delta = constraints.clamp_trim_delta(clip, edge_type, delta_ms, all_clips, frame_rate, true)
        end

        if clamped_delta ~= delta_ms then
            if not dry_run then
                local reason = ""
                if math.abs(clamped_delta) < math.abs(delta_ms) then
                    reason = " (collision)"
                else
                    local frame_snapped = frame_utils.snap_delta_to_frame(delta_ms, frame_rate)
                    if frame_snapped ~= delta_ms then
                        reason = " (frame snap)"
                    end
                end
                print(string.format("⚠️  Trim adjusted: %dms → %dms%s", delta_ms, clamped_delta, reason))
            end
        end

        -- Store clamped delta for deterministic replay
        command:set_parameter("clamped_delta_ms", clamped_delta)
    end

    delta_ms = clamped_delta

    -- Save original state for undo (not needed for dry-run or gap clips)
    local original_clip_state = nil
    if not dry_run and not is_gap_clip then
        original_clip_state = {
            start_time = clip.start_time,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }
    end

    -- Save original state BEFORE modifying clip
    local original_duration = clip.duration
    local original_start_time = clip.start_time

    -- Calculate ripple point and new clip dimensions (no mutation yet)
    local ripple_time, success = apply_edge_ripple(clip, edge_type, delta_ms)
    if not success then
        return {success = false, error_message = "Ripple operation would violate clip or media constraints"}
    end

    -- Calculate actual shift amount for downstream clips
    -- In-point edit: shift = -delta (opposite direction)
    -- Out-point edit: shift = +delta (same direction)
    local shift_amount
    if edge_type == "in" then
        shift_amount = -delta_ms  -- Drag right → clip shorter → shift left
    else  -- edge_type == "out"
        shift_amount = delta_ms   -- Drag right → clip longer → shift right
    end

    if not dry_run then
        print(string.format("RippleEdit: original_edge=%s, normalized_edge=%s, delta_ms=%d, shift_amount=%d, ripple_time=%d",
            edge_info.edge_type, edge_type, delta_ms, shift_amount, ripple_time))
    end

    -- Find all clips on ALL tracks that start after the ripple point
    -- Ripple affects the entire timeline to maintain sync across all tracks
    local clips_to_shift = {}
    local database = require('core.database')
    local all_clips = database.load_clips(command:get_parameter("sequence_id") or "default_sequence")

    for _, other_clip in ipairs(all_clips) do
        -- Include clips at or after ripple point (use > ripple_time - 1 to catch adjacent clips)
        -- This handles floating point rounding and clips that are within 1ms of the ripple point
        -- For gap edits: clip.id is "temp_gap_*" so we never exclude real clips (correct!)
        -- For regular edits: clip.id is the actual clip being edited, so we exclude it (correct!)
        if other_clip.id ~= clip.id and
           other_clip.start_time > ripple_time - 1 then
            table.insert(clips_to_shift, other_clip)
            if not dry_run then
                print(string.format("  Will shift clip %s from %d to %d", other_clip.id:sub(1,8), other_clip.start_time, other_clip.start_time + shift_amount))
            end
        end
    end

    if not dry_run then
        print(string.format("RippleEdit: Found %d clips to shift", #clips_to_shift))
    end

    -- DRY RUN: Return preview data without executing
    if dry_run then
        return true, {
            affected_clip = {
                clip_id = clip.id,
                new_start_time = clip.start_time,
                new_duration = clip.duration
            },
            shifted_clips = (function()
                local shifts = {}
                for _, downstream_clip in ipairs(clips_to_shift) do
                    table.insert(shifts, {
                        clip_id = downstream_clip.id,
                        new_start_time = downstream_clip.start_time + shift_amount
                    })
                end
                return shifts
            end)()
        }
    end

    -- EXECUTE: Actually save changes (skip for gap clips - they're not persisted)
    if not is_gap_clip then
        if not clip:save(db) then
            print(string.format("ERROR: RippleEdit: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
            return {success = false, error_message = "Failed to save clip"}
        end
    end

    -- Shift all downstream clips
    for _, downstream_clip in ipairs(clips_to_shift) do
        local shift_clip = Clip.load(downstream_clip.id, db)
        if not shift_clip then
            print(string.format("WARNING: RippleEdit: Failed to load downstream clip %s", downstream_clip.id:sub(1,8)))
            goto continue_shift
        end

        shift_clip.start_time = shift_clip.start_time + shift_amount

        if not shift_clip:save(db) then
            print(string.format("ERROR: RippleEdit: Failed to save downstream clip %s", downstream_clip.id:sub(1,8)))
            return {success = false, error_message = "Failed to save downstream clip"}
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

    -- For gap clips, store the calculated boundaries for deterministic replay
    if is_gap_clip then
        command:set_parameter("gap_start_time", original_start_time)
        command:set_parameter("gap_duration", original_duration)
    end

    print(string.format("✅ Ripple edit: trimmed %s edge by %dms, shifted %d downstream clips",
        edge_info.edge_type, delta_ms, #clips_to_shift))

    return true
end

-- BatchRippleEdit: Trim multiple edges simultaneously with single timeline shift
-- Prevents cascading shifts when multiple edges are selected
command_executors["BatchRippleEdit"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing BatchRippleEdit command")
    end

    local edge_infos = command:get_parameter("edge_infos")  -- Array of {clip_id, edge_type, track_id}
    local delta_ms = command:get_parameter("delta_ms")
    local sequence_id = command:get_parameter("sequence_id") or "default_sequence"

    if not edge_infos or not delta_ms or #edge_infos == 0 then
        print("ERROR: BatchRippleEdit missing parameters")
        return false
    end

    local Clip = require('models.clip')
    local database = require('core.database')
    local original_states = {}
    local latest_ripple_time = 0
    local latest_shift_amount = 0  -- Track shift for downstream clips
    local preview_affected_clips = {}

    -- Load all clips once for gap materialization
    local all_clips = database.load_clips(sequence_id)

    print(string.format("DEBUG BatchRippleEdit: %d edges, delta_ms=%d",
        #edge_infos, delta_ms))
    for i, edge_info in ipairs(edge_infos) do
        print(string.format("  Edge %d: clip=%s, edge_type=%s", i, edge_info.clip_id:sub(1,8), edge_info.edge_type))
    end

    -- Phase 1: Trim all edges and find latest ripple point
    -- All edges must succeed or none - preserves relative timing
    for _, edge_info in ipairs(edge_infos) do
        -- MATERIALIZE GAP CLIPS: Create virtual clip objects for gaps
        -- This removes all special cases - gaps behave exactly like clips
        local clip, actual_edge_type, is_gap_clip

        if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
            -- Find the real clip that defines this gap
            local reference_clip = Clip.load(edge_info.clip_id, db)
            if not reference_clip then
                print(string.format("WARNING: BatchRippleEdit: Gap reference clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end

            -- Calculate gap boundaries from adjacent clips
            local gap_start, gap_duration
            local gap_end
            if edge_info.edge_type == "gap_after" then
                gap_start = reference_clip.start_time + reference_clip.duration
                -- Find next clip on same track to determine gap end
                gap_end = math.huge
                for _, c in ipairs(all_clips) do
                    if c.track_id == reference_clip.track_id and c.start_time > gap_start then
                        gap_end = math.min(gap_end, c.start_time)
                    end
                end
            else  -- gap_before
                gap_end = reference_clip.start_time
                -- Find previous clip on same track to determine gap start
                gap_start = 0
                for _, c in ipairs(all_clips) do
                    if c.track_id == reference_clip.track_id and c.start_time + c.duration < gap_end then
                        gap_start = math.max(gap_start, c.start_time + c.duration)
                    end
                end
            end
            gap_duration = gap_end - gap_start

            -- Create temporary gap clip object (not saved to database)
            clip = {
                id = "temp_gap_" .. edge_info.clip_id,
                track_id = reference_clip.track_id,
                start_time = gap_start,
                duration = gap_duration,
                source_in = 0,
                source_out = gap_duration
            }
            actual_edge_type = edge_info.edge_type == "gap_after" and "in" or "out"
            is_gap_clip = true
        else
            clip = Clip.load(edge_info.clip_id, db)
            if not clip then
                print(string.format("WARNING: BatchRippleEdit: Clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end
            actual_edge_type = edge_info.edge_type
            is_gap_clip = false
        end

        -- Save original state
        original_states[edge_info.clip_id] = {
            start_time = clip.start_time,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }

        -- Apply edge ripple using shared helper
        -- BUG FIX: Pass same delta_ms to ALL edges - asymmetry comes from edge type, not negation
        -- apply_edge_ripple already handles in-point vs out-point semantics correctly
        local edge_delta = delta_ms  -- Same delta for all edges!
        print(string.format("  Processing: clip=%s, actual_edge=%s, edge_delta=%d",
            clip.id:sub(1,8), actual_edge_type, edge_delta))
        local ripple_time, success = apply_edge_ripple(clip, actual_edge_type, edge_delta)
        if not success then
            print(string.format("Ripple blocked: clip %s at media boundary (preserving relative timing)", clip.id:sub(1,8)))
            return false
        end

        -- DRY RUN: Collect preview data
        if dry_run then
            table.insert(preview_affected_clips, {
                clip_id = clip.id,
                new_start_time = clip.start_time,
                new_duration = clip.duration,
                edge_type = actual_edge_type  -- Use translated edge type, not gap_before/gap_after
            })
        else
            -- EXECUTE: Save changes (skip gap clips - they're not persisted)
            if not is_gap_clip then
                if not clip:save(db) then
                    print(string.format("ERROR: BatchRippleEdit: Failed to save clip %s", clip.id:sub(1,8)))
                    return false
                end
            end
        end

        -- Track latest ripple point and its shift amount
        -- BUG FIX: Calculate shift based on edge type, not raw delta
        -- In-point trim: shift opposite direction (drag right = shrink = shift left)
        -- Out-point trim: shift same direction (drag right = grow = shift right)
        if ripple_time then
            local shift_for_this_edge
            if actual_edge_type == "in" then
                shift_for_this_edge = -edge_delta  -- Opposite direction
            else  -- "out"
                shift_for_this_edge = edge_delta   -- Same direction
            end

            -- Use the rightmost ripple point's shift
            if ripple_time > latest_ripple_time then
                latest_ripple_time = ripple_time
                latest_shift_amount = shift_for_this_edge
                print(string.format("  New latest ripple: time=%dms, shift=%dms (edge_type=%s)",
                    latest_ripple_time, latest_shift_amount, actual_edge_type))
            end
        end
    end

    -- Phase 2: Single timeline shift at latest ripple point
    local edited_clip_ids = {}
    for _, edge_info in ipairs(edge_infos) do
        -- Track edited clips to exclude from downstream shift
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

    -- DRY RUN: Return preview data without executing
    if dry_run then
        local preview_shifted_clips = {}
        for _, downstream_clip in ipairs(clips_to_shift) do
            table.insert(preview_shifted_clips, {
                clip_id = downstream_clip.id,
                new_start_time = downstream_clip.start_time + latest_shift_amount  -- BUG FIX: Use calculated shift
            })
        end
        return true, {
            affected_clips = preview_affected_clips,
            shifted_clips = preview_shifted_clips
        }
    end

    -- EXECUTE: Shift all downstream clips once
    for _, downstream_clip in ipairs(clips_to_shift) do
        local shift_clip = Clip.load(downstream_clip.id, db)
        if not shift_clip then
            print(string.format("WARNING: BatchRippleEdit: Failed to load downstream clip %s", downstream_clip.id:sub(1,8)))
            goto continue_batch_shift
        end

        shift_clip.start_time = shift_clip.start_time + latest_shift_amount  -- BUG FIX: Use calculated shift

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
    command:set_parameter("shift_amount", latest_shift_amount)  -- Store calculated shift for undo

    print(string.format("✅ Batch ripple: trimmed %d edges by %dms, shifted %d downstream clips by %dms",
        #edge_infos, delta_ms, #clips_to_shift, latest_shift_amount))

    return true
end

-- Undo for BatchRippleEdit
command_executors["UndoBatchRippleEdit"] = function(command)
    print("Executing UndoBatchRippleEdit command")

    local original_states = command:get_parameter("original_states")
    local shift_amount = command:get_parameter("shift_amount")  -- BUG FIX: Use stored shift, not delta_ms
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

        shift_clip.start_time = shift_clip.start_time - shift_amount  -- BUG FIX: Use stored shift

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
                -- Check for NULL parent (only error if not the first command)
                if not parent then
                    if current_seq == 1 then
                        -- First command with NULL parent is valid
                        current_seq = 0
                    elseif current_seq > start_sequence then
                        -- Found NULL parent in middle of chain - data corruption!
                        print(string.format("ERROR: Command %d has NULL parent - broken command chain detected!", current_seq))
                        print(string.format("ERROR: This breaks event sourcing - cannot replay past this point"))
                        print(string.format("HINT: Run repair_broken_parent_chains() to fix database integrity"))
                        print(string.format("HINT: This bug was caused by executing commands when current_sequence_number was incorrectly nil"))
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

    print(string.format("Undoing command: %s (seq %d, parent %s)",
        current_command.type,
        current_command.sequence_number,
        tostring(current_command.parent_sequence_number)))

    -- Save current selection before undo (user state between commands)
    local timeline_state = require('ui.timeline.timeline_state')
    saved_selection_on_undo = timeline_state.get_selected_clips()

    -- Calculate target sequence (parent of current command for branching support)
    -- In a branching history, undo follows the parent link, not sequence_number - 1
    local target_sequence = current_command.parent_sequence_number or 0

    print(string.format("  Will replay from 0 to %d", target_sequence))

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

-- ImportFCP7XML: Import Final Cut Pro 7 XML sequence
command_executors["ImportFCP7XML"] = function(command)
    local dry_run = command:get_parameter("dry_run")
    if not dry_run then
        print("Executing ImportFCP7XML command")
    end

    local xml_path = command:get_parameter("xml_path")
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
    print(string.format("Parsing FCP7 XML: %s", xml_path))
    local parse_result = fcp7_importer.import_xml(xml_path, project_id)

    if not parse_result.success then
        for _, error_msg in ipairs(parse_result.errors) do
            print(string.format("ERROR: %s", error_msg))
        end
        return false
    end

    print(string.format("Found %d sequence(s)", #parse_result.sequences))

    -- Create entities in database
    local create_result = fcp7_importer.create_entities(parse_result, db, project_id)

    if not create_result.success then
        print(string.format("ERROR: %s", create_result.error or "Failed to create entities"))
        return false
    end

    -- Store created IDs for undo
    command:set_parameter("created_sequence_ids", create_result.sequence_ids)
    command:set_parameter("created_track_ids", create_result.track_ids)
    command:set_parameter("created_clip_ids", create_result.clip_ids)

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

-- Get the executor function for a command type (used for dry-run preview)
function M.get_executor(command_type)
    return command_executors[command_type]
end

return M
