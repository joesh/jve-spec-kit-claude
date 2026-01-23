--- Import FCP7 XML Command - Interactive dialog and non-interactive XML import
--
-- Responsibilities:
-- - ImportFCP7XML: Shows file picker when interactive=true, imports FCP7 XML
--
-- Non-goals:
-- - Converting FCP7 effects (limited support)
--
-- Invariants:
-- - Must receive xml_path (or gather from dialog)
-- - Undo deletes all created entities
--
-- Size: ~200 LOC
-- Volatility: low
--
-- @file import_fcp7_xml.lua
local M = {}
local logger = require("core.logger")
local command_helper = require("core.command_helper")

-- Schema for ImportFCP7XML command
local SPEC = {
    args = {
        project_id = { required = true },
        sequence_id = {},    -- Auto-passed by menu system
        interactive = { kind = "boolean" },  -- If true, show file picker dialog
        xml_path = {},       -- Path to XML file (or gathered from dialog)
        xml_contents = {},   -- Optional: XML string for tests
    },
    persisted = {
        clip_id_map = {},
        created_clip_ids = {},
        created_media_ids = {},
        created_sequence_id_map = {},
        created_sequence_ids = {},
        created_track_ids = {},
        media_id_map = {},
        sequence_id_map = {},
        track_id_map = {},
    },
}

function M.register(executors, undoers, db)

    -- =========================================================================
    -- ImportFCP7XML: Import FCP7 XML with optional interactive dialog
    -- =========================================================================
    executors["ImportFCP7XML"] = function(command)
        local args = command:get_all_parameters()

        local project_id = args.project_id
        if not project_id or project_id == "" then
            return { success = false, error_message = "Missing project_id" }
        end

        local file_path = args.xml_path

        -- If interactive mode or no file path provided, show dialog
        if args.interactive or not file_path or file_path == "" then
            logger.info("import_fcp7_xml", "ImportFCP7XML: Showing file picker dialog")

            -- Get UI references for dialog
            local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
            if not ui_state_ok then
                return { success = false, error_message = "UI state not initialized" }
            end

            local main_window = ui_state.get_main_window()
            if not main_window then
                return { success = false, error_message = "Main window not initialized" }
            end

            -- Show file picker dialog
            file_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Import Final Cut Pro 7 XML",
                "Final Cut Pro XML (*.xml);;All Files (*)"
            )

            if not file_path or file_path == "" then
                -- User cancelled - this is not an error
                logger.debug("import_fcp7_xml", "ImportFCP7XML: User cancelled file picker")
                return { success = true, cancelled = true }
            end

            -- Store the gathered file path for undo/redo
            command:set_parameter("xml_path", file_path)
        end

        logger.info("import_fcp7_xml", "Importing FCP7 XML: " .. tostring(file_path))

        if not args.xml_path then
            logger.error("import_fcp7_xml", "ImportFCP7XML missing xml_path")
            return { success = false, error_message = "Missing xml_path" }
        end

        local fcp7_importer = require('importers.fcp7_xml_importer')

        -- Parse XML
        if args.xml_path and args.xml_path ~= "" then
            logger.info("import_fcp7_xml", string.format("Parsing FCP7 XML: %s", args.xml_path))
        else
            logger.info("import_fcp7_xml", "Parsing FCP7 XML from stored content")
        end
        local parse_result = fcp7_importer.import_xml(args.xml_path, project_id, {
            xml_content = args.xml_contents
        })

        if not parse_result.success then
            for _, error_msg in ipairs(parse_result.errors) do
                logger.error("import_fcp7_xml", tostring(error_msg))
            end
            return { success = false, error_message = table.concat(parse_result.errors, "\n") }
        end

        logger.info("import_fcp7_xml", string.format("Found %d sequence(s)", #parse_result.sequences))

        -- Prepare replay context so importer can reuse deterministic IDs
        local replay_context = {
            sequence_id_map = args.sequence_id_map or args.created_sequence_id_map,
            track_id_map = args.track_id_map,
            clip_id_map = args.clip_id_map,
            media_id_map = args.media_id_map,
            sequence_ids = args.created_sequence_ids,
            track_ids = args.created_track_ids,
            clip_ids = args.created_clip_ids,
            media_ids = args.created_media_ids
        }

        -- Create entities in database
        local create_result = fcp7_importer.create_entities(parse_result, db, project_id, replay_context)

        if not create_result.success then
            logger.error("import_fcp7_xml", tostring(create_result.error or "Failed to create entities"))
            return { success = false, error_message = create_result.error or "Failed to create entities" }
        end

        -- Store created IDs for undo
        command:set_parameters({
            ["created_sequence_ids"] = create_result.sequence_ids,
            ["created_track_ids"] = create_result.track_ids,
            ["created_clip_ids"] = create_result.clip_ids,
            ["created_media_ids"] = create_result.media_ids,
            ["sequence_id_map"] = create_result.sequence_id_map,
            ["track_id_map"] = create_result.track_id_map,
            ["clip_id_map"] = create_result.clip_id_map,
            ["media_id_map"] = create_result.media_id_map,
        })
        if parse_result.xml_content and (not args.xml_contents or args.xml_contents == "") then
            command:set_parameter("xml_contents", parse_result.xml_content)
        end
        command:set_parameter("__skip_sequence_replay_on_undo", true)

        logger.info("import_fcp7_xml", string.format("Imported %d sequence(s), %d track(s), %d clip(s)",
            #create_result.sequence_ids,
            #create_result.track_ids,
            #create_result.clip_ids))

        command:set_parameters({
            ["__force_snapshot"] = true,
            ["__snapshot_sequence_ids"] = create_result.sequence_ids,
        })

        -- Refresh project browser to show newly imported sequences
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if ui_state_ok then
            local project_browser = ui_state.get_project_browser()
            if project_browser and project_browser.refresh then
                project_browser.refresh()
            end
        end

        return { success = true }
    end

    undoers["ImportFCP7XML"] = function(command)
        local args = command:get_all_parameters()
        -- Delete all created entities
        local sequence_ids = args.created_sequence_ids or {}
        local track_ids = args.created_track_ids or {}
        local clip_ids = args.created_clip_ids or {}
        local media_ids = args.created_media_ids or {}

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
        local active_sequence = command_helper.resolve_active_sequence_id(nil, timeline_state)

        if timeline_state and timeline_state.reload_clips then
            local reload_target = fallback_sequence or active_sequence
            if reload_target and reload_target ~= "" then
                timeline_state.reload_clips(reload_target)
            end
        end

        logger.info("import_fcp7_xml", "Import undone - deleted all imported entities")
        return true
    end

    return {
        ["ImportFCP7XML"] = {
            executor = executors["ImportFCP7XML"],
            undoer = undoers["ImportFCP7XML"],
            spec = SPEC,
        },
    }
end

return M
