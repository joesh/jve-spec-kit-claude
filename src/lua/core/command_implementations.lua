-- Command Implementations for Command Manager
-- Extracted for Rule 2.27 (Short Functions and Logical File Splitting)
--
-- Contains all 29 command executors and their undoers.
-- This file defines the actual command logic, while command_manager.lua
-- handles execution flow, undo/redo, and replay infrastructure.

local M = {}

-- Register all command executors and undoers
-- Parameters:
--   command_executors: table to populate with executor functions
--   command_undoers: table to populate with undoer functions
--   db: database connection reference (captured by closures)
function M.register_commands(command_executors, command_undoers, db)

    local function restore_clip_state(state)
        if not state then
            return
        end
        local Clip = require('models.clip')
        local clip = Clip.load(state.id, db)
        if not clip then
            clip = Clip.create('Restored Clip', state.media_id)
            clip.id = state.id
        end
        clip.track_id = state.track_id
        clip.media_id = state.media_id
        clip.start_time = state.start_time
        clip.duration = state.duration
        clip.source_in = state.source_in
        clip.source_out = state.source_out
        clip.enabled = state.enabled ~= false
        clip:save(db, {resolve_occlusion = false})
    end

    local function revert_occlusion_actions(actions)
        if not actions or #actions == 0 then
            return
        end
        local Clip = require('models.clip')
        for i = #actions, 1, -1 do
            local action = actions[i]
            if action.type == 'trim' then
                restore_clip_state(action.before)
            elseif action.type == 'delete' then
                restore_clip_state(action.clip or action.before)
            elseif action.type == 'insert' then
                local state = action.clip
                if state then
                    local clip = Clip.load(state.id, db)
                    if clip then
                        clip:delete(db)
                    end
                end
            end
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

-- BatchCommand: Execute multiple commands as a single undo unit
-- Wraps N commands into one transaction for atomic undo/redo
command_executors["BatchCommand"] = function(command)
    print("Executing BatchCommand")

    local commands_json = command:get_parameter("commands_json")
    if not commands_json or commands_json == "" then
        print("ERROR: BatchCommand: No commands provided")
        return false
    end

    -- Parse JSON array of command specs
    local json = require("dkjson")
    local command_specs, parse_err = json.decode(commands_json)
    if not command_specs then
        print(string.format("ERROR: BatchCommand: Failed to parse commands JSON: %s", parse_err or "unknown"))
        return false
    end

    -- Execute each command in sequence
    -- Outer execute() provides transaction safety - no nested transactions needed
    local Command = require("command")
    local executed_commands = {}

    for i, spec in ipairs(command_specs) do
        local cmd = Command.create(spec.command_type, spec.project_id or "default_project")

        -- Set parameters from spec
        if spec.parameters then
            for key, value in pairs(spec.parameters) do
                cmd:set_parameter(key, value)
            end
        end

        -- Execute command (don't add to command log - batch is the log entry)
        local executor = command_executors[spec.command_type]
        if not executor then
            print(string.format("ERROR: BatchCommand: Unknown command type '%s'", spec.command_type))
            return false
        end

        local success = executor(cmd)
        if not success then
            print(string.format("ERROR: BatchCommand: Command %d (%s) failed", i, spec.command_type))
            return false
        end

        table.insert(executed_commands, cmd)
    end

    -- Store executed commands for undo
    command:set_parameter("executed_commands_json", json.encode(command_specs))

    print(string.format("BatchCommand: Executed %d commands successfully", #executed_commands))
    return true
end

command_undoers["BatchCommand"] = function(command)
    print("Undoing BatchCommand")

    local commands_json = command:get_parameter("executed_commands_json")
    if not commands_json then
        print("ERROR: BatchCommand undo: No executed commands found")
        return false
    end

    -- Parse and undo in reverse order
    local json = require("dkjson")
    local command_specs = json.decode(commands_json)

    local Command = require("command")
    for i = #command_specs, 1, -1 do
        local spec = command_specs[i]
        local cmd = Command.create(spec.command_type, spec.project_id or "default_project")

        -- Restore parameters
        if spec.parameters then
            for key, value in pairs(spec.parameters) do
                cmd:set_parameter(key, value)
            end
        end

        -- Execute undo
        local undoer = command_undoers[spec.command_type]
        if undoer then
            local success = undoer(cmd)
            if not success then
                print(string.format("WARNING: BatchCommand undo: Failed to undo command %d (%s)", i, spec.command_type))
            end
        end
    end

    print(string.format("BatchCommand: Undid %d commands", #command_specs))
    return true
end

command_executors["ImportMedia"] = function(command)
    print("Executing ImportMedia command")

    local file_path = command:get_parameter("file_path")
    local project_id = command:get_parameter("project_id")
    local existing_media_id = command:get_parameter("media_id")

    if not file_path or file_path == "" or not project_id or project_id == "" then
        print("WARNING: ImportMedia: Missing required parameters")
        return false
    end

    -- Use MediaReader to probe file and extract metadata
    local MediaReader = require("media.media_reader")
    local media_id, err = MediaReader.import_media(file_path, db, project_id, existing_media_id)

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

    -- Frame alignment now automatic in Clip:save() for video tracks
    -- Audio tracks preserve sample-accurate precision

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
            -- Ripple clips that start at or after insert_time to prevent overlap
            if start_time >= insert_time then
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

    if clip:save(db, {resolve_occlusion = true}) then
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

    -- Inspect overlaps to capture metadata and reuse IDs when overwriting whole clips
    local overlap_query = db:prepare([[
        SELECT id, start_time, duration
        FROM clips
        WHERE track_id = ?
        ORDER BY start_time ASC
    ]])

    if not overlap_query then
        print("WARNING: Overwrite: Failed to prepare overlap query")
        return false
    end

    overlap_query:bind_value(1, track_id)

    local overlapping = {}
    local reuse_clip_id = nil

    if overlap_query:exec() then
        while overlap_query:next() do
            local clip_id = overlap_query:value(0)
            local clip_start = overlap_query:value(1)
            local clip_duration = overlap_query:value(2)
            local clip_end = clip_start + clip_duration

            if clip_start < overwrite_end and clip_end > overwrite_time then
                table.insert(overlapping, {
                    id = clip_id,
                    start_time = clip_start,
                    duration = clip_duration,
                    end_time = clip_end
                })

                if clip_start >= overwrite_time and clip_end <= overwrite_end and not reuse_clip_id then
                    reuse_clip_id = clip_id
                end
            end
        end
    end

    if dry_run then
        return true, {affected_clips = overlapping}
    end

    local Clip = require('models.clip')
    local existing_clip_id = command:get_parameter("clip_id")
    local clip = Clip.create("Overwrite Clip", media_id)
    if existing_clip_id then
        clip.id = existing_clip_id  -- Reuse existing ID for replay
    elseif reuse_clip_id then
        clip.id = reuse_clip_id  -- Preserve identity for downstream commands
    end
    clip.track_id = track_id
    clip.start_time = overwrite_time
    clip.duration = duration
    clip.source_in = source_in
    clip.source_out = source_out

    command:set_parameter("clip_id", clip.id)

    if clip:save(db, {resolve_occlusion = true}) then
        -- Advance playhead to end of overwritten clip (if requested)
        local advance_playhead = command:get_parameter("advance_playhead")
        if advance_playhead then
            local timeline_state = require('ui.timeline.timeline_state')
            timeline_state.set_playhead_time(overwrite_time + duration)
        end

        print(string.format("✅ Overwrote at %dms", overwrite_time))
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
        local save_opts = {resolve_occlusion = {ignore_ids = clips_to_move}}

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
                if not clip:save(db, save_opts) then
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
    -- Gap clips have no media_id - they represent empty timeline space
    -- Skip media boundary checks for gaps (allow source_in/out to be anything)
    local has_source_media = (clip.media_id ~= nil)

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

            if media and media.duration and media.duration > 0 then
                local max_source_out = media.duration
                local available_tail = max_source_out - (clip.source_in + clip.duration)
                if available_tail < 0 then available_tail = 0 end
                if delta_ms > available_tail then
                    if available_tail == 0 then
                        print(string.format("  BLOCKED: already at media end (%dms)", max_source_out))
                        delta_ms = 0
                    else
                        print(string.format("  CLAMPED: requested delta=%dms, available tail=%dms", delta_ms, available_tail))
                        delta_ms = available_tail
                    end
                    new_duration = clip.duration + delta_ms
                    new_source_out = clip.source_in + new_duration
                end
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
    local occlusion_actions = {}

    -- MATERIALIZE GAP CLIPS: Convert gap edges to temporary gap clip objects
    local gap_reference_clip = nil
    local clip, edge_type, is_gap_clip
    if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
        -- Find the real clip that defines this gap
        local reference_clip = Clip.load(edge_info.clip_id, db)
        if not reference_clip then
            print("ERROR: RippleEdit: Reference clip not found")
            return {success = false, error_message = "Reference clip not found"}
        end
        gap_reference_clip = reference_clip

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
            source_out = gap_duration,
            is_gap = true
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

    -- CONSTRAINT CHECK: Clamp delta to valid range
    -- Frame alignment now automatic in Clip:save() for video tracks
    local constraints = require('core.timeline_constraints')

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

            --  print(string.format("DEBUG GAP CONSTRAINT: ripple_time=%dms, delta_ms=%dms", ripple_time, delta_ms))

            -- Find clips that will shift (everything after ripple point)
            -- and clips that are stationary (everything before ripple point)
            local stationary_clips = {}
            for _, c in ipairs(all_clips) do
                if c.start_time < ripple_time then
                    table.insert(stationary_clips, c)
                    -- print(string.format("  Stationary: %s at %d-%dms on %s", c.id:sub(1,8), c.start_time, c.start_time + c.duration, c.track_id))
                end
            end

            -- Calculate max shift: how far can we shift before any shifted clip hits a stationary clip?
            local max_shift = math.huge
            local min_shift = -math.huge

            for _, shifting_clip in ipairs(all_clips) do
                if shifting_clip.start_time >= ripple_time then
                    -- print(string.format("  Shifting: %s at %dms on %s", shifting_clip.id:sub(1,8), shifting_clip.start_time, shifting_clip.track_id))
                    -- This clip will shift - check against all stationary clips on all tracks
                    for _, stationary in ipairs(stationary_clips) do
                        if shifting_clip.track_id == stationary.track_id then
                            -- Same track - check collision in both directions
                            local gap_between = shifting_clip.start_time - (stationary.start_time + stationary.duration)
                            -- print(string.format("    vs stationary %s: gap=%dms", stationary.id:sub(1,8), gap_between))

                            if gap_between >= 0 then
                                -- No overlap: clips are separated or touching
                                -- Shifting RIGHT moves away from stationary clip (no constraint)
                                -- Shifting LEFT moves toward stationary clip (limited by gap)
                                if -gap_between > min_shift then
                                    min_shift = -gap_between
                                    -- print(string.format("      min_shift = %dms (can't shift left into stationary clip)", min_shift))
                                end
                                -- No max_shift constraint from this stationary clip (we're moving away)
                            else
                                -- Overlap exists (gap_between < 0)
                                -- Shifting right reduces overlap (allowed, no limit from this clip)
                                -- Shifting left increases overlap (blocked entirely)
                                -- print(string.format("      OVERLAP by %dms - blocking left shift", -gap_between))
                                -- Can't shift left at all when overlap exists
                                if 0 > min_shift then
                                    min_shift = 0
                                    -- print(string.format("      min_shift = 0 (blocking left due to overlap)"))
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
                -- print(string.format("  Gap duration constraint: min_shift = %dms (can't close gap beyond 1ms)", min_shift))
            end

            -- print(string.format("  Final constraints: min_shift=%s, max_shift=%s", tostring(min_shift), tostring(max_shift)))

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
            -- print(string.format("  Converted to delta constraints: min_delta=%s, max_delta=%s", tostring(min_delta), tostring(max_delta)))

            -- Clamp delta to constraint range
            clamped_delta = math.max(min_delta, math.min(max_delta, delta_ms))
        else
            -- Regular clip trim: use normal constraint logic (no frame snapping)
            clamped_delta = constraints.clamp_trim_delta(clip, edge_type, delta_ms, all_clips, nil, nil, true)
        end

        if clamped_delta ~= delta_ms and not dry_run then
            print(string.format("⚠️  Trim adjusted: %dms → %dms (collision)", delta_ms, clamped_delta))
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
        -- Include clips at or after ripple point (>= ripple_time - 1 handles rounding)
        -- This handles floating point rounding and clips that are within 1ms of the ripple point
        -- For gap edits: clip.id is "temp_gap_*" so we never exclude real clips (correct!)
        -- For regular edits: clip.id is the actual clip being edited, so we exclude it (correct!)
        if other_clip.id ~= clip.id and
           other_clip.start_time >= ripple_time - 1 then
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
        local ok, actions = clip:save(db, {resolve_occlusion = true})
        if not ok then
            print(string.format("ERROR: RippleEdit: Failed to save clip %s", edge_info.clip_id:sub(1,8)))
            return {success = false, error_message = "Failed to save clip"}
        end
        if actions then
            for _, action in ipairs(actions) do
                table.insert(occlusion_actions, action)
            end
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

        local ok, actions = shift_clip:save(db, {resolve_occlusion = true})
        if not ok then
            print(string.format("ERROR: RippleEdit: Failed to save downstream clip %s", downstream_clip.id:sub(1,8)))
            return {success = false, error_message = "Failed to save downstream clip"}
        end
        if actions then
            for _, action in ipairs(actions) do
                table.insert(occlusion_actions, action)
            end
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

    if #occlusion_actions > 0 then
        command:set_parameter("occlusion_actions", occlusion_actions)
    end

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
    local earliest_ripple_time = math.huge  -- Track leftmost ripple point (determines which clips shift)
    local downstream_shift_amount = nil  -- Timeline length change (NOT summed across tracks)
    local preview_affected_clips = {}
    local occlusion_actions = {}

    -- Load all clips once for gap materialization
    local all_clips = database.load_clips(sequence_id)

    -- Phase 0: Calculate constraints for ALL edges BEFORE any modifications
    -- Find the most restrictive constraint to ensure all edges can move together
    local max_allowed_delta = delta_ms
    local min_allowed_delta = delta_ms

    -- Determine reference bracket type from first effective edge
    local reference_bracket = nil
    for _, edge_info in ipairs(edge_infos) do
        -- Materialize clip (gap or real)
        local clip, actual_edge_type, is_gap_clip

        if edge_info.edge_type == "gap_after" or edge_info.edge_type == "gap_before" then
            local reference_clip = Clip.load(edge_info.clip_id, db)
            if not reference_clip then
                print(string.format("WARNING: Gap reference clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end

        -- Calculate gap boundaries
        local gap_start, gap_end
        if edge_info.edge_type == "gap_after" then
            gap_start = reference_clip.start_time + reference_clip.duration
            gap_end = math.huge
            for _, c in ipairs(all_clips) do
                if c.track_id == reference_clip.track_id and c.start_time > gap_start then
                    gap_end = math.min(gap_end, c.start_time)
                end
            end
        else  -- gap_before
            gap_end = reference_clip.start_time
            gap_start = 0
            for _, c in ipairs(all_clips) do
                if c.track_id == reference_clip.track_id and c.start_time + c.duration < gap_end then
                    gap_start = math.max(gap_start, c.start_time + c.duration)
                end
            end
        end

        clip = {
            id = "temp_gap_" .. edge_info.clip_id,
            track_id = reference_clip.track_id,
            start_time = gap_start,
            duration = gap_end - gap_start,
            source_in = 0,
            source_out = gap_end - gap_start,
            is_gap = true
        }
        actual_edge_type = edge_info.edge_type == "gap_after" and "in" or "out"
        is_gap_clip = true
        else
            clip = Clip.load(edge_info.clip_id, db)
            if not clip then
                print(string.format("WARNING: Clip %s not found", edge_info.clip_id:sub(1,8)))
                return false
            end
            actual_edge_type = edge_info.edge_type
            is_gap_clip = false
        end

        -- ASYMMETRIC FIX: Negate delta for opposite BRACKET types
        -- Bracket mapping: in/gap_after → [, out/gap_before → ]
        -- If dragging [ edge: all ] edges get negated delta
        -- If dragging ] edge: all [ edges get negated delta
        local edge_bracket = (actual_edge_type == "in") and "[" or "]"
        if not reference_bracket and edge_info == edge_infos[1] then
            reference_bracket = edge_bracket
        end
        local edge_delta = (edge_bracket == reference_bracket) and delta_ms or -delta_ms

        -- Calculate constraints using timeline_constraints module
        -- For ripple edits, skip adjacent clip checks since they move downstream
        local constraints_module = require('core.timeline_constraints')
        local constraint_result = constraints_module.calculate_trim_range(
            clip,
            actual_edge_type,
            all_clips,
            false,  -- check_all_tracks: not needed since we skip adjacent checks anyway
            true    -- skip_adjacent_check: ripple edits move downstream clips
        )
        local min_delta = constraint_result.min_delta
        local max_delta = constraint_result.max_delta

        if not dry_run then
            print(string.format("  Edge %s (%s) %s: edge_delta=%d, constraint=[%d, %d]",
                clip.id:sub(1,8),
                is_gap_clip and "gap" or "clip",
                actual_edge_type,
                edge_delta,
                min_delta,
                max_delta == math.huge and 999999999 or max_delta))
        end

        -- Accumulate constraints in delta_ms space (not edge_delta space)
        -- Constraints are on edge_delta, but we accumulate constraints on delta_ms
        -- Check if edge_delta and delta_ms have opposite signs (happens when bracket negation occurs)
        local opposite_signs = (edge_delta * delta_ms < 0)

        if opposite_signs then
            -- edge_delta = -delta_ms, so constraints need to be inverted
            -- edge_delta in [min_delta, max_delta] means -delta_ms in [min_delta, max_delta]
            -- So delta_ms in [-max_delta, -min_delta]
            local delta_min = -max_delta
            local delta_max = -min_delta

            if delta_ms > 0 then
                max_allowed_delta = math.min(max_allowed_delta, delta_max)
            else
                min_allowed_delta = math.max(min_allowed_delta, delta_min)
            end
        else
            -- edge_delta and delta_ms have same sign, no inversion needed
            if delta_ms > 0 then
                max_allowed_delta = math.min(max_allowed_delta, max_delta)
            else
                min_allowed_delta = math.max(min_allowed_delta, min_delta)
            end
        end
    end

    -- Clamp delta_ms to the most restrictive constraint
    local original_delta = delta_ms
    if delta_ms > 0 then
        delta_ms = math.min(delta_ms, max_allowed_delta)
    else
        delta_ms = math.max(delta_ms, min_allowed_delta)
    end

    if delta_ms ~= original_delta then
        if not dry_run then
            print(string.format("Clamped delta: %d → %d", original_delta, delta_ms))
        end
        -- Store clamped delta for deterministic replay
        command:set_parameter("clamped_delta_ms", delta_ms)
    end

    if delta_ms == 0 then
        if not dry_run then
            print("WARNING: All edges blocked - no movement possible")
        end
        return false
    end

    -- Phase 1: Trim all edges with the clamped delta
    -- All edges now guaranteed to succeed - preserves relative timing
    local edited_clip_ids = {}  -- Track clip IDs that were edited (real or temporary gap clips)
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
            source_out = gap_duration,
            is_gap = true
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

        -- Save original state (before trim)
        local original_duration = clip.duration
        original_states[edge_info.clip_id] = {
            start_time = clip.start_time,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }

        if not dry_run and is_gap_clip then
            print(string.format("  Gap materialized: duration=%s (infinite=%s)",
                tostring(clip.duration),
                tostring(clip.duration == math.huge)))
        end

        -- Track this clip as edited (use materialized clip.id, not edge_info.clip_id)
        -- For real clips: clip.id == edge_info.clip_id
        -- For gaps: clip.id == "temp_gap_..." (won't match any DB clip, so won't exclude reference clip)
        table.insert(edited_clip_ids, clip.id)

        -- Apply edge ripple using shared helper
        -- Phase 0 already ensured this will succeed by clamping delta_ms
        -- ASYMMETRIC FIX: Negate delta for opposite BRACKET types (not in/out types!)
        -- Bracket mapping: in/gap_after → [, out/gap_before → ]
        local edge_bracket = (actual_edge_type == "in") and "[" or "]"
        local edge_delta = (edge_bracket == reference_bracket) and delta_ms or -delta_ms
        local ripple_time, success = apply_edge_ripple(clip, actual_edge_type, edge_delta)
        if not success then
            -- This should never happen after Phase 0 constraint calculation
            print(string.format("ERROR: Ripple failed for clip %s despite constraint pre-calculation!", clip.id:sub(1,8)))
            print(string.format("       This indicates a bug in constraint calculation - please report"))
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
                local ok, actions = clip:save(db, {resolve_occlusion = true})
                if not ok then
                    print(string.format("ERROR: BatchRippleEdit: Failed to save clip %s", clip.id:sub(1,8)))
                    return false
                end
                if actions then
                    for _, action in ipairs(actions) do
                        table.insert(occlusion_actions, action)
                    end
                end
            end
        end

        -- Calculate downstream shift from timeline length change
        -- Tracks are PARALLEL, so use first edge's duration change (not summed)
        if ripple_time then
            local duration_change = clip.duration - original_duration

            -- Skip infinite gaps (extend to end of timeline) - they produce NaN
            -- math.huge - math.huge = nan, which corrupts downstream clip positions
            local is_infinite_gap = (original_duration == math.huge or clip.duration == math.huge)

            if not dry_run then
                print(string.format("  Duration change: %s - %s = %s (infinite=%s)",
                    tostring(clip.duration), tostring(original_duration),
                    tostring(duration_change), tostring(is_infinite_gap)))
            end

            if downstream_shift_amount == nil and not is_infinite_gap then
                downstream_shift_amount = duration_change
                if not dry_run then
                    print(string.format("  Set downstream_shift_amount = %s", tostring(downstream_shift_amount)))
                end
            elseif not dry_run and is_infinite_gap then
                print(string.format("  Skipped infinite gap - not setting downstream_shift_amount"))
            end

            -- Track leftmost ripple point (determines which clips shift)
            -- With asymmetric edits, use EARLIEST ripple time so all downstream clips shift
            if ripple_time < earliest_ripple_time then
                earliest_ripple_time = ripple_time
            end
        end
    end

    -- If all edges were infinite gaps, default to zero shift
    -- This prevents nil downstream_shift_amount from corrupting clip positions
    if downstream_shift_amount == nil then
        downstream_shift_amount = 0
    end

    -- Phase 2: Single timeline shift at earliest ripple point
    -- edited_clip_ids contains materialized clip IDs (real clips + temp gap clips)
    -- Temp gap IDs won't match any DB clips, so reference clips naturally aren't excluded
    local database = require('core.database')
    local all_clips = database.load_clips(sequence_id)
    local clips_to_shift = {}

    if not dry_run then
        print(string.format("DOWNSTREAM SHIFT: earliest_ripple_time=%dms, edited_clip_ids=%s",
            earliest_ripple_time, table.concat(edited_clip_ids, ",")))
    end

    for _, other_clip in ipairs(all_clips) do
        -- Don't shift clips we just edited
        local is_edited = false
        for _, edited_id in ipairs(edited_clip_ids) do
            if other_clip.id == edited_id then
                is_edited = true
                break
            end
        end

        if not is_edited and other_clip.start_time >= earliest_ripple_time - 1 then
            table.insert(clips_to_shift, other_clip)
            if not dry_run then
                print(string.format("  Will shift: %s at %dms on %s", other_clip.id:sub(1,8), other_clip.start_time, other_clip.track_id))
            end
        elseif not dry_run then
            print(string.format("  Skip: %s at %dms (edited=%s, >= ripple_time=%s)",
                other_clip.id:sub(1,8), other_clip.start_time, tostring(is_edited), tostring(other_clip.start_time >= earliest_ripple_time)))
        end
    end

    -- Clamp negative shifts so we never push a clip before t=0
    if downstream_shift_amount < 0 then
        local min_start = math.huge
        for _, clip in ipairs(clips_to_shift) do
            if clip.start_time < min_start then
                min_start = clip.start_time
            end
        end
        if min_start ~= math.huge then
            local max_negative_shift = -min_start
            if downstream_shift_amount < max_negative_shift then
                if not dry_run then
                    print(string.format("  Clamped negative downstream shift: %d → %d (prevent negative start)",
                        downstream_shift_amount, max_negative_shift))
                end
                downstream_shift_amount = max_negative_shift
            end
        end
    end

    -- DRY RUN: Return preview data without executing
    if dry_run then
        local preview_shifted_clips = {}
        for _, downstream_clip in ipairs(clips_to_shift) do
            table.insert(preview_shifted_clips, {
                clip_id = downstream_clip.id,
                new_start_time = downstream_clip.start_time + (downstream_shift_amount or 0)
            })
        end
        return true, {
            affected_clips = preview_affected_clips,
            shifted_clips = preview_shifted_clips
        }
    end

    -- EXECUTE: Shift all downstream clips once
    if not dry_run and #clips_to_shift > 0 then
        print(string.format("DEBUG: downstream_shift_amount=%s", tostring(downstream_shift_amount)))
    end

    for _, downstream_clip in ipairs(clips_to_shift) do
        local shift_clip = Clip.load(downstream_clip.id, db)
        if not shift_clip then
            print(string.format("WARNING: BatchRippleEdit: Failed to load downstream clip %s", downstream_clip.id:sub(1,8)))
            goto continue_batch_shift
        end

        if not dry_run then
            print(string.format("  Before: clip %s start_time=%s", shift_clip.id:sub(1,8), tostring(shift_clip.start_time)))
        end

        shift_clip.start_time = shift_clip.start_time + (downstream_shift_amount or 0)

        if not dry_run then
            print(string.format("  After:  clip %s start_time=%s", shift_clip.id:sub(1,8), tostring(shift_clip.start_time)))
        end

        local ok, actions = shift_clip:save(db, {resolve_occlusion = true})
        if not ok then
            print(string.format("ERROR: BatchRippleEdit: Failed to save downstream clip %s", downstream_clip.id:sub(1,8)))
            return false
        end
        if actions then
            for _, action in ipairs(actions) do
                table.insert(occlusion_actions, action)
            end
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
    command:set_parameter("shift_amount", downstream_shift_amount or 0)  -- Store shift for undo
    if #occlusion_actions > 0 then
        command:set_parameter("occlusion_actions", occlusion_actions)
    end

    print(string.format("✅ Batch ripple: trimmed %d edges, shifted %d downstream clips by %dms",
        #edge_infos, #clips_to_shift, downstream_shift_amount or 0))

    return true
end

-- Undo for BatchRippleEdit
command_executors["UndoBatchRippleEdit"] = function(command)
    print("Executing UndoBatchRippleEdit command")

    local original_states = command:get_parameter("original_states")
    local shift_amount = command:get_parameter("shift_amount")  -- BUG FIX: Use stored shift, not delta_ms
    local shifted_clip_ids = command:get_parameter("shifted_clip_ids")
    local occlusion_actions = command:get_parameter("occlusion_actions") or {}

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

        if not clip:save(db, {resolve_occlusion = false}) then
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

        if not shift_clip:save(db, {resolve_occlusion = false}) then
            print(string.format("ERROR: UndoBatchRippleEdit: Failed to save shifted clip %s", clip_id:sub(1,8)))
            return false
        end

        ::continue_unshift::
    end

    revert_occlusion_actions(occlusion_actions)

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
    local occlusion_actions = command:get_parameter("occlusion_actions") or {}

    -- Restore original clip
    local Clip = require('models.clip')
    local clip = Clip.load(edge_info.clip_id, db)
    if clip then
        clip.start_time = original_clip_state.start_time
        clip.duration = original_clip_state.duration
        clip.source_in = original_clip_state.source_in
        clip.source_out = original_clip_state.source_out
        clip:save(db, {resolve_occlusion = false})
    end

    -- Shift all affected clips back
    for _, clip_id in ipairs(shifted_clip_ids) do
        local shift_clip = Clip.load(clip_id, db)
        if shift_clip then
            shift_clip.start_time = shift_clip.start_time - delta_ms
            shift_clip:save(db, {resolve_occlusion = false})
        end
    end

    revert_occlusion_actions(occlusion_actions)

    print(string.format("✅ Undone ripple edit: restored clip and shifted %d clips back", #shifted_clip_ids))
    return true
end

end

return M
