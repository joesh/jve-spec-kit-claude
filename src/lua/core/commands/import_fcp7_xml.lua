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
local file_browser = require("core.file_browser")
local Rational = require("core.rational")

--- Calculate and apply zoom-to-fit viewport for a sequence.
-- Sets viewport to show all clips with 10% buffer padding.
-- @param sequence_id The sequence to update
-- @param db Database connection
-- @return viewport_data Table with {start_frames, duration_frames} or nil if no clips
local function apply_zoom_to_fit_viewport(sequence_id, db)
    local database = require("core.database")
    local Sequence = require("models.sequence")

    -- Load clips for this sequence
    local clips = database.load_clips(sequence_id)
    if not clips or #clips == 0 then
        return nil
    end

    -- Calculate content bounds
    local min_start = nil
    local max_end = nil

    for _, clip in ipairs(clips) do
        local start_val = clip.timeline_start
        local dur_val = clip.duration

        if start_val and dur_val then
            local end_val = start_val + dur_val

            if not min_start or start_val < min_start then
                min_start = start_val
            end
            if not max_end or end_val > max_end then
                max_end = end_val
            end
        end
    end

    if not min_start or not max_end then
        return nil
    end

    -- Calculate viewport with 10% buffer
    local content_duration = max_end - min_start
    local buffer = content_duration / 10
    local viewport_duration = content_duration + buffer

    -- Load and update the sequence
    local sequence = Sequence.load(sequence_id)
    if not sequence then
        logger.warn("import_fcp7_xml", "Failed to load sequence for viewport update: " .. tostring(sequence_id))
        return nil
    end

    -- Set viewport to zoom-to-fit
    sequence.viewport_start_time = min_start
    sequence.viewport_duration = viewport_duration

    if not sequence:save() then
        logger.warn("import_fcp7_xml", "Failed to save sequence viewport: " .. tostring(sequence_id))
        return nil
    end

    local viewport_data = {
        start_frames = min_start.frames,
        duration_frames = viewport_duration.frames,
    }

    logger.info("import_fcp7_xml", string.format(
        "Set zoom-to-fit viewport for sequence %s: start=%d, duration=%d frames",
        sequence_id, viewport_data.start_frames, viewport_data.duration_frames))

    return viewport_data
end

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
        sequence_view_states = {},
        sequence_viewports = {},
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
            file_path = file_browser.open_file(
                "import_fcp7_xml", main_window,
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

        -- Apply view state to each imported sequence
        -- On redo: restore the user's view state (zoom, playhead, selection) captured at undo time
        -- On first execution: calculate zoom-to-fit viewport
        local stored_view_states = args.sequence_view_states
        local sequence_viewports = {}

        for _, seq_id in ipairs(create_result.sequence_ids) do
            local stored = stored_view_states and stored_view_states[seq_id]
            if stored then
                -- Redo: restore full view state captured at undo time
                local Sequence = require("models.sequence")
                local sequence = Sequence.load(seq_id)
                if sequence then
                    local fps_num = sequence.frame_rate.fps_numerator
                    local fps_den = sequence.frame_rate.fps_denominator

                    -- Restore viewport
                    sequence.viewport_start_time = Rational.new(
                        stored.viewport_start_frames or 0, fps_num, fps_den)
                    sequence.viewport_duration = Rational.new(
                        stored.viewport_duration_frames or 240, fps_num, fps_den)

                    -- Restore playhead
                    sequence.playhead_position = Rational.new(
                        stored.playhead_frames or 0, fps_num, fps_den)

                    -- Restore selection
                    sequence.selected_clip_ids_json = stored.selected_clip_ids_json or "[]"
                    sequence.selected_edge_infos_json = stored.selected_edge_infos_json or "[]"

                    sequence:save()

                    sequence_viewports[seq_id] = {
                        start_frames = stored.viewport_start_frames,
                        duration_frames = stored.viewport_duration_frames,
                    }
                end
            else
                -- First execution: calculate zoom-to-fit viewport
                local viewport_data = apply_zoom_to_fit_viewport(seq_id, db)
                if viewport_data then
                    sequence_viewports[seq_id] = viewport_data
                end
            end
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
            ["sequence_viewports"] = sequence_viewports,
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

        -- Reload timeline_state if it's viewing one of the recreated sequences.
        -- After redo, timeline_state has stale cached values from before undo.
        -- We must call init() to load the fresh values from the database.
        local timeline_state_ok, timeline_state = pcall(require, 'ui.timeline.timeline_state')
        if timeline_state_ok and timeline_state then
            local active_seq = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
            if active_seq then
                for _, seq_id in ipairs(create_result.sequence_ids) do
                    if seq_id == active_seq then
                        logger.info("import_fcp7_xml", string.format(
                            "Reloading timeline_state for recreated sequence %s", seq_id))
                        timeline_state.init(seq_id, project_id)
                        break
                    end
                end
            end
        end

        return { success = true }
    end

    undoers["ImportFCP7XML"] = function(command)
        local args = command:get_all_parameters()
        local Sequence = require("models.sequence")

        -- Load timeline_state early so we can invalidate cache after deleting sequences
        local timeline_state = nil
        local ok, loaded_state = pcall(require, 'ui.timeline.timeline_state')
        if ok and type(loaded_state) == "table" then
            timeline_state = loaded_state
        end

        -- Delete all created entities
        local sequence_ids = args.created_sequence_ids or {}
        local track_ids = args.created_track_ids or {}
        local clip_ids = args.created_clip_ids or {}
        local media_ids = args.created_media_ids or {}

        -- Capture current view state from each sequence BEFORE deleting.
        -- This allows redo to restore the user's view state (zoom, playhead, selection).
        -- IMPORTANT: If timeline_state is viewing this sequence, capture from its cache
        -- (not the database) because the user's zoom might not be persisted yet.
        local sequence_view_states = {}
        local active_timeline_seq = timeline_state and timeline_state.get_sequence_id and timeline_state.get_sequence_id()

        for _, seq_id in ipairs(sequence_ids) do
            local view_state = nil

            -- If timeline_state is viewing this sequence, capture from its cache
            if active_timeline_seq == seq_id and timeline_state then
                local vp_start = timeline_state.get_viewport_start_time and timeline_state.get_viewport_start_time()
                local vp_dur = timeline_state.get_viewport_duration and timeline_state.get_viewport_duration()
                local playhead = timeline_state.get_playhead_position and timeline_state.get_playhead_position()

                -- Handle both Rational objects and raw numbers
                local function get_frames(val)
                    if type(val) == "table" and val.frames then return val.frames end
                    if type(val) == "number" then return val end
                    return 0
                end

                -- Capture selection from cache
                local selected_clip_ids = {}
                local selected_clips = timeline_state.get_selected_clips and timeline_state.get_selected_clips()
                if selected_clips then
                    for _, clip in ipairs(selected_clips) do
                        if clip and clip.id then
                            table.insert(selected_clip_ids, clip.id)
                        end
                    end
                end

                local edge_descriptors = {}
                local selected_edges = timeline_state.get_selected_edges and timeline_state.get_selected_edges()
                if selected_edges then
                    for _, edge in ipairs(selected_edges) do
                        if edge and edge.clip_id and edge.edge_type then
                            table.insert(edge_descriptors, {
                                clip_id = edge.clip_id,
                                edge_type = edge.edge_type,
                                trim_type = edge.trim_type
                            })
                        end
                    end
                end

                local json = require("dkjson")
                local clips_ok, clips_json = pcall(json.encode, selected_clip_ids)
                local edges_ok, edges_json = pcall(json.encode, edge_descriptors)

                view_state = {
                    viewport_start_frames = get_frames(vp_start),
                    viewport_duration_frames = get_frames(vp_dur) or 240,
                    playhead_frames = get_frames(playhead),
                    selected_clip_ids_json = clips_ok and clips_json or "[]",
                    selected_edge_infos_json = edges_ok and edges_json or "[]",
                }
                logger.debug("import_fcp7_xml", string.format(
                    "Captured view state from cache: seq=%s, vp_start=%d, vp_dur=%d, playhead=%d, clips=%d, edges=%d",
                    seq_id, view_state.viewport_start_frames, view_state.viewport_duration_frames, view_state.playhead_frames,
                    #selected_clip_ids, #edge_descriptors))
            else
                -- Fallback: load from database
                local sequence = Sequence.load(seq_id)
                if sequence then
                    view_state = {
                        viewport_start_frames = sequence.viewport_start_time and sequence.viewport_start_time.frames or 0,
                        viewport_duration_frames = sequence.viewport_duration and sequence.viewport_duration.frames or 240,
                        playhead_frames = sequence.playhead_position and sequence.playhead_position.frames or 0,
                        selected_clip_ids_json = sequence.selected_clip_ids_json or "[]",
                        selected_edge_infos_json = sequence.selected_edge_infos_json or "[]",
                    }
                    logger.debug("import_fcp7_xml", string.format(
                        "Captured view state from database: seq=%s, vp_start=%d, vp_dur=%d, playhead=%d",
                        seq_id, view_state.viewport_start_frames, view_state.viewport_duration_frames, view_state.playhead_frames))
                end
            end

            if view_state then
                sequence_view_states[seq_id] = view_state
            end
        end
        -- Store captured view states for redo and persist to database
        command:set_parameter("sequence_view_states", sequence_view_states)
        command:save(db)

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
