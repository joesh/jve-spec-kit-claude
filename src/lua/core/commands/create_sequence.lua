local M = {}
local log = require("core.logger").for_area("commands")
local Sequence = require('models.sequence')
local Track = require('models.track')
local database = require("core.database")
local ui_constants = require("core.ui_constants")
local command_helper = require("core.command_helper")


local SPEC = {
    mutates_clips = false,  -- mutates sequences/tracks tables, no clip mutations
    args = {
        audio_sample_rate = { required = true },
        frame_rate        = { required = true },
        height            = {},
        name              = { required = true },
        project_id        = { required = true },
        sequence_id       = {},
        width             = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    local MIN_TRACK_HEIGHT = assert(ui_constants and ui_constants.TIMELINE and ui_constants.TIMELINE.MIN_TRACK_HEIGHT,
        "CreateSequence: ui_constants.TIMELINE.MIN_TRACK_HEIGHT not defined")
    local DEFAULT_TRACK_HEIGHT = assert(ui_constants and ui_constants.TIMELINE and ui_constants.TIMELINE.TRACK_HEIGHT,
        "CreateSequence: ui_constants.TIMELINE.TRACK_HEIGHT not defined")
    local TRACK_TEMPLATE_KEY = "track_height_template"

    -- Templates may legitimately omit a per-track entry (nil); only
    -- present-but-wrong values are a corruption to assert on.
    local function normalize_height(value)
        if value == nil then return DEFAULT_TRACK_HEIGHT end
        assert(type(value) == "number", string.format(
            "CreateSequence: track-height template entry must be number; got %s (%s)",
            type(value), tostring(value)))
        local clamped = math.floor(value)
        if clamped < MIN_TRACK_HEIGHT then
            clamped = MIN_TRACK_HEIGHT
        end
        return clamped
    end

    local function seed_default_tracks(sequence_id, project_id)
        assert(type(database.get_project_setting) == "function",
            "CreateSequence: database.get_project_setting missing — required API")
        local template = database.get_project_setting(project_id, TRACK_TEMPLATE_KEY)
        -- nil = no template yet (first sequence in a fresh project) → all defaults.
        -- A present template MUST carry both arrays (the writer always emits
        -- { video = {...}, audio = {...} }); a non-nil table missing them is
        -- corruption — assert rather than silently degrade to all-default heights.
        local template_video, template_audio
        if template == nil then
            template_video, template_audio = {}, {}
        else
            assert(type(template) == "table"
                and type(template.video) == "table"
                and type(template.audio) == "table",
                "CreateSequence: malformed track_height_template — expected { video = {...}, audio = {...} }")
            template_video, template_audio = template.video, template.audio
        end

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
                index = def.index
            })
            if not track or not track:save() then
                return false, string.format("CreateSequence: Failed to create track %s", def.label)
            end

            local template_source = def.kind == "video" and template_video or template_audio
            local desired_height = template_source and template_source[def.index] or nil
            height_map[track.id] = normalize_height(desired_height)
        end

        assert(type(database.set_sequence_track_heights) == "function",
            "CreateSequence: database.set_sequence_track_heights missing — required API")
        database.set_sequence_track_heights(sequence_id, height_map)

        return true
    end

    command_executors["CreateSequence"] = function(command)
        local args = command:get_all_parameters()
        log.event("Executing CreateSequence")

        local name = args.name
        local project_id = args.project_id



        
        if type(args.frame_rate) == "number" and args.frame_rate <= 0 then
            set_last_error("CreateSequence: Invalid frame rate")
            return false
        end


        -- User-created edit timelines are kind='sequence' (they hold clips
        -- referencing other sequences). Master sequences are created by
        -- import paths via Sequence.ensure_master.
        local sequence = Sequence.create(name, project_id, args.frame_rate, args.width, args.height, {
            id                = args.sequence_id,
            kind              = "sequence",
            audio_sample_rate = args.audio_sample_rate,
        })

        command:set_parameter("sequence_id", sequence.id)

        if not sequence:save() then
            log.error("Failed to save sequence: %s", name)
            return false
        end

        local seeded, seed_err = seed_default_tracks(sequence.id, project_id)
        if not seeded then
            log.error("%s", tostring(seed_err or "CreateSequence: Failed to seed default tracks"))
            return false
        end

        log.event("Created sequence: %s id=%s", name, sequence.id)
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
        -- Sequence-list mutation → browser tree must rebuild. Queued post-
        -- commit so the browser refreshes only after the row is durable in
        -- the DB (rollback discards the queued emit). project_browser
        -- subscribes; no other consumer should be added without thinking
        -- about whether `sequence_content_changed` is what they want instead.
        require("core.command_manager").queue_post_commit_emit(
            "sequence_list_changed", project_id)
        return true
    end

    command_undoers["CreateSequence"] = function(command)
        local args = command:get_all_parameters()
        log.event("Undoing CreateSequence")


        local stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
        if not stmt then
            set_last_error("UndoCreateSequence: Failed to prepare delete statement")
            return false
        end
        stmt:bind_value(1, args.sequence_id)
        local ok = stmt:exec()
        stmt:finalize()
        if not ok then
            log.error("UndoCreateSequence failed: %s", tostring(db:last_error() or "unknown"))
            return false
        end
        log.event("Undo CreateSequence: removed sequence %s", tostring(args.sequence_id))
        require("core.command_manager").queue_post_commit_emit(
            "sequence_list_changed", args.project_id)
        return true
    end
    command_executors["UndoCreateSequence"] = command_undoers["CreateSequence"]

    return {
        executor = command_executors["CreateSequence"],
        undoer = command_undoers["CreateSequence"],
        spec = SPEC,
    }
end

return M
