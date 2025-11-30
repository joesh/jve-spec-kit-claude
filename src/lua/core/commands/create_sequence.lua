local M = {}
local Sequence = require('models.sequence')
local Track = require('models.track')
local database = require("core.database")
local ui_constants = require("core.ui_constants")
local command_helper = require("core.command_helper")

function M.register(command_executors, command_undoers, db, set_last_error)
    local MIN_TRACK_HEIGHT = 24
    local DEFAULT_TRACK_HEIGHT = (ui_constants and ui_constants.TIMELINE and ui_constants.TIMELINE.TRACK_HEIGHT) or 50
    local TRACK_TEMPLATE_KEY = "track_height_template"

    local function normalize_height(value)
        if type(value) ~= "number" then
            return DEFAULT_TRACK_HEIGHT
        end
        local clamped = math.floor(value)
        if clamped < MIN_TRACK_HEIGHT then
            clamped = MIN_TRACK_HEIGHT
        end
        return clamped
    end

    local function seed_default_tracks(sequence_id, project_id)
        local template = nil
        if database.get_project_setting then
            template = database.get_project_setting(project_id, TRACK_TEMPLATE_KEY)
        end
        local template_video = type(template) == "table" and template.video or {}
        local template_audio = type(template) == "table" and template.audio or {}

        local definitions = {
            {builder = Track.create_video, label = "V1", index = 1, kind = "video"},
            {builder = Track.create_video, label = "V2", index = 2, kind = "video"},
            {builder = Track.create_video, label = "V3", index = 3, kind = "video"},
            {builder = Track.create_audio, label = "A1", index = 1, kind = "audio"},
            {builder = Track.create_audio, label = "A2", index = 2, kind = "audio"},
            {builder = Track.create_audio, label = "A3", index = 3, kind = "audio"},
        }

        local height_map = {}

        for _, def in ipairs(definitions) do
            local track = def.builder(def.label, sequence_id, {
                index = def.index,
                db = db
            })
            if not track or not track:save(db) then
                return false, string.format("CreateSequence: Failed to create track %s", def.label)
            end

            local template_source = def.kind == "video" and template_video or template_audio
            local desired_height = template_source and template_source[def.index] or nil
            height_map[track.id] = normalize_height(desired_height)
        end

        if database.set_sequence_track_heights then
            database.set_sequence_track_heights(sequence_id, height_map)
        end

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

        local sequence = Sequence.create(name, project_id, frame_rate, width, height)

        command:set_parameter("sequence_id", sequence.id)

        if not sequence:save(db) then
            print(string.format("Failed to save sequence: %s", name))
            return false
        end

        local seeded, seed_err = seed_default_tracks(sequence.id, project_id)
        if not seeded then
            print(string.format("ERROR: %s", seed_err or "CreateSequence: Failed to seed default tracks"))
            return false
        end

        print(string.format("Created sequence: %s with ID: %s", name, sequence.id))
        local metadata_bucket = command_helper.ensure_timeline_mutation_bucket(command, sequence.id)
        if metadata_bucket then
            metadata_bucket.sequence_meta = metadata_bucket.sequence_meta or {}
            table.insert(metadata_bucket.sequence_meta, {
                action = "created",
                sequence_id = sequence.id,
                project_id = project_id,
                name = name
            })
        end
        command:set_parameter("__allow_empty_mutations", true)
        return true
    end

    return {
        executor = command_executors["CreateSequence"]
    }
end

return M
