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
-- Size: ~134 LOC
-- Volatility: unknown
--
-- @file import_fcp7_xml.lua
-- Original intent (unreviewed):
-- ImportFCP7XML command
local M = {}
local logger = require("core.logger")

function M.register(executors, undoers, db)
    
    executors["ImportFCP7XML"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            logger.info("import_fcp7_xml", "Executing ImportFCP7XML command")
        end

        local xml_path = command:get_parameter("xml_path")
        local xml_contents = command:get_parameter("xml_contents")
        local project_id = command:get_parameter("project_id") or command.project_id
        if not project_id or project_id == "" then
            logger.error("import_fcp7_xml", "ImportFCP7XML missing project_id")
            return false
        end

        if not xml_path then
            logger.error("import_fcp7_xml", "ImportFCP7XML missing xml_path")
            return false
        end

        if dry_run then
            return true  -- Validation would happen here
        end

        local fcp7_importer = require('importers.fcp7_xml_importer')

        -- Parse XML
        if xml_path and xml_path ~= "" then
            logger.info("import_fcp7_xml", string.format("Parsing FCP7 XML: %s", xml_path))
        else
            logger.info("import_fcp7_xml", "Parsing FCP7 XML from stored content")
        end
        local parse_result = fcp7_importer.import_xml(xml_path, project_id, {
            xml_content = xml_contents
        })

        if not parse_result.success then
            for _, error_msg in ipairs(parse_result.errors) do
                logger.error("import_fcp7_xml", tostring(error_msg))
            end
            return false
        end

        logger.info("import_fcp7_xml", string.format("Found %d sequence(s)", #parse_result.sequences))

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
            logger.error("import_fcp7_xml", tostring(create_result.error or "Failed to create entities"))
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

        logger.info("import_fcp7_xml", string.format("Imported %d sequence(s), %d track(s), %d clip(s)",
            #create_result.sequence_ids,
            #create_result.track_ids,
            #create_result.clip_ids))

        command:set_parameter("__force_snapshot", true)
        command:set_parameter("__snapshot_sequence_ids", create_result.sequence_ids)

        return true
    end

    undoers["ImportFCP7XML"] = function(command)
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
            -- invalidate_sequence_stack(sequence_id) -- command_manager responsibility?
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
            -- Not using select_fallback_sequence as it is local to command_manager
            -- Assuming timeline reload will handle empty/deleted sequence gracefully or we need to set a new one.
        end

        if timeline_state and timeline_state.reload_clips then
            local reload_target = fallback_sequence or active_sequence
            if reload_target and reload_target ~= "" then
                timeline_state.reload_clips(reload_target)
            end
        end

        logger.info("import_fcp7_xml", "Import undone - deleted all imported entities")
        return true
    end

    return {executor = executors["ImportFCP7XML"], undoer = undoers["ImportFCP7XML"]}
end

return M
