--- Import Resolve Commands - Import Resolve projects and databases
--
-- Responsibilities:
-- - ImportResolveProject: Import .drp file with optional interactive dialog
-- - ImportResolveDatabase: Import Resolve database with optional interactive dialog
--
-- Non-goals:
-- - Direct Resolve API integration (file-based import only)
--
-- Invariants:
-- - Commands must receive file paths (or gather from dialog)
-- - Undo deletes all created entities
--
-- @file import_resolve_project.lua
local M = {}
local logger = require("core.logger")
local file_browser = require("core.file_browser")

-- Schema for .drp import command
local SPEC_DRP = {
    args = {
        project_id = { required = true },
        interactive = { kind = "boolean" },
        drp_path = {},
    },
    persisted = {
        created_clip_ids = {},
        created_media_ids = {},
        created_sequence_ids = {},
        created_track_ids = {},
        result_project_id = {},
    },
}

-- Schema for database import command
local SPEC_DB = {
    args = {
        project_id = { required = true },
        interactive = { kind = "boolean" },
        db_path = {},
    },
    persisted = {
        created_clip_ids = {},
        created_media_ids = {},
        created_sequence_ids = {},
        created_track_ids = {},
        result_project_id = {},
    },
}

--- Shared undoer: delete all entities created by an import command.
-- Works for both ImportResolveProject and ImportResolveDatabase.
local function import_undoer(command_name, command, db)
    local args = command:get_all_parameters()
    assert(args.result_project_id,
        command_name .. ": missing result_project_id")

    -- Delete in dependency order: clips → tracks → sequences → media → project
    for _, clip_id in ipairs(args.created_clip_ids or {}) do
        assert(db:exec(string.format("DELETE FROM clips WHERE id = '%s'", clip_id)),
            command_name .. ": clips DELETE failed for " .. tostring(clip_id))
    end

    for _, track_id in ipairs(args.created_track_ids or {}) do
        assert(db:exec(string.format("DELETE FROM tracks WHERE id = '%s'", track_id)),
            command_name .. ": tracks DELETE failed for " .. tostring(track_id))
    end

    for _, seq_id in ipairs(args.created_sequence_ids or {}) do
        assert(db:exec(string.format("DELETE FROM sequences WHERE id = '%s'", seq_id)),
            command_name .. ": sequences DELETE failed for " .. tostring(seq_id))
    end

    for _, media_id in ipairs(args.created_media_ids or {}) do
        assert(db:exec(string.format("DELETE FROM media WHERE id = '%s'", media_id)),
            command_name .. ": media DELETE failed for " .. tostring(media_id))
    end

    assert(db:exec(string.format("DELETE FROM projects WHERE id = '%s'", args.result_project_id)),
        command_name .. ": projects DELETE failed for " .. tostring(args.result_project_id))

    logger.info("import_resolve", "Undo: Deleted imported project and all associated data")
    return true
end

--- Gather file path from user dialog if needed.
-- @return string|nil: file path, or nil if cancelled
-- @return table|nil: cancel result to return from executor
local function gather_file_path(command, args, dialog_key, dialog_title, dialog_filter, param_name, default_dir)
    local path = args[param_name]
    if args.interactive or not path or path == "" then
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if not ui_state_ok then
            return nil, { success = false, error_message = "UI state not initialized" }
        end
        local main_window = ui_state.get_main_window()
        if not main_window then
            return nil, { success = false, error_message = "Main window not initialized" }
        end

        path = file_browser.open_file(dialog_key, main_window, dialog_title, dialog_filter, default_dir)
        if not path or path == "" then
            return nil, { success = true, cancelled = true }
        end
        command:set_parameter(param_name, path)
    end
    return path, nil
end

--- Persist import results and refresh UI.
local function persist_and_refresh(command, project_id, import_result)
    command:set_parameters({
        ["result_project_id"] = project_id,
        ["created_media_ids"] = import_result.media_ids,
        ["created_sequence_ids"] = import_result.sequence_ids,
        ["created_track_ids"] = import_result.track_ids,
        ["created_clip_ids"] = import_result.clip_ids,
    })

    local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
    if ui_state_ok then
        local project_browser = ui_state.get_project_browser()
        if project_browser and project_browser.refresh then
            project_browser.refresh()
        end
    end
end

function M.register(executors, undoers, db)
    local _sqlite3 = require("lsqlite3")  -- luacheck: ignore 211

    -- =========================================================================
    -- ImportResolveProject (.drp file)
    -- =========================================================================
    executors["ImportResolveProject"] = function(command)
        local args = command:get_all_parameters()
        assert(args.project_id and args.project_id ~= "", "ImportResolveProject: Missing project_id")

        local drp_path, cancel = gather_file_path(
            command, args,
            "import_resolve_drp", "Import Resolve Project (.drp)",
            "Resolve Project Files (*.drp);;All Files (*)",
            "drp_path")
        if not drp_path then return cancel end

        logger.info("import_resolve", "Importing Resolve project: " .. tostring(drp_path))

        local drp_importer = require("importers.drp_importer")
        local parse_result = drp_importer.parse_drp_file(drp_path)
        if not parse_result.success then
            return { success = false, error_message = parse_result.error }
        end

        local Project = require("models.project")
        local json = require("dkjson")

        local settings = {
            frame_rate = parse_result.project.settings.frame_rate,
            width = parse_result.project.settings.width,
            height = parse_result.project.settings.height,
        }

        local project = Project.create(parse_result.project.name, {
            settings = json.encode(settings),
        })

        if not project:save(db) then
            return { success = false, error_message = "Failed to create project" }
        end

        logger.info("import_resolve", string.format("Created project: %s (%dx%d @ %sfps)",
            project.name, settings.width, settings.height, tostring(settings.frame_rate)))

        local import_result = drp_importer.import_into_project(project.id, parse_result, {
            project_settings = settings,
        })

        persist_and_refresh(command, project.id, import_result)

        return { success = true, project_id = project.id }
    end

    undoers["ImportResolveProject"] = function(command)
        return import_undoer("UndoImportResolveProject", command, db)
    end

    -- =========================================================================
    -- ImportResolveDatabase (Resolve .db file)
    -- =========================================================================
    executors["ImportResolveDatabase"] = function(command)
        local args = command:get_all_parameters()
        assert(args.project_id and args.project_id ~= "", "ImportResolveDatabase: Missing project_id")

        local db_path, cancel = gather_file_path(
            command, args,
            "import_resolve_db", "Import Resolve Database",
            "Database Files (*.db *.sqlite *.resolve);;All Files (*)",
            "db_path",
            os.getenv("HOME") .. "/Movies/DaVinci Resolve")
        if not db_path then return cancel end

        logger.info("import_resolve", "Importing Resolve database: " .. tostring(db_path))

        local resolve_db_importer = require("importers.resolve_database_importer")
        local import_result_raw = resolve_db_importer.import_from_database(db_path)

        if not import_result_raw.success then
            return { success = false, error_message = import_result_raw.error }
        end

        local Project = require("models.project")
        local Media = require("models.media")
        local Clip_mod = require("models.clip")
        local Sequence_mod = require("models.sequence")
        local json = require("dkjson")

        local db_settings = {
            frame_rate = import_result_raw.project.frame_rate,
            width = import_result_raw.project.width,
            height = import_result_raw.project.height,
        }

        local project = Project.create(import_result_raw.project.name, {
            settings = json.encode(db_settings),
        })

        if not project:save(db) then
            return { success = false, error_message = "Failed to create project" }
        end

        logger.info("import_resolve", string.format("Created project from Resolve DB: %s (%dx%d @ %.2ffps)",
            project.name, db_settings.width, db_settings.height, db_settings.frame_rate))

        -- ImportResolveDatabase uses a different data format than DRP parse_result,
        -- so it cannot use import_into_project() directly. Create entities via models.
        local created_media_ids = {}
        local created_sequence_ids = {}
        local created_track_ids = {}
        local created_clip_ids = {}

        local media_id_map = {}
        for _, media_item in ipairs(import_result_raw.media_items) do
            local media = Media.create({
                project_id = project.id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration_frames = media_item.duration,
                frame_rate = media_item.frame_rate or import_result_raw.project.frame_rate,
                width = import_result_raw.project.width,
                height = import_result_raw.project.height,
            })

            if media:save() then
                table.insert(created_media_ids, media.id)
                if media_item.resolve_id then
                    media_id_map[media_item.resolve_id] = media.id
                end
            else
                logger.warn("import_resolve", string.format("Failed to import media: %s", media_item.name))
            end
        end

        local function fr_to_rational(fr)
            local fps = tonumber(fr)
            assert(fps, "ImportResolveDatabase: missing/invalid frame_rate")
            if math.abs(fps - 23.976) < 0.01 then return 24000, 1001
            elseif math.abs(fps - 29.97) < 0.01 then return 30000, 1001
            elseif math.abs(fps - 59.94) < 0.01 then return 60000, 1001
            end
            return math.floor(fps + 0.5), 1
        end

        for _, timeline_data in ipairs(import_result_raw.timelines) do
            local fps_num, fps_den = fr_to_rational(timeline_data.frame_rate or import_result_raw.project.frame_rate)

            local sequence = Sequence_mod.create(
                timeline_data.name,
                project.id,
                { fps_numerator = fps_num, fps_denominator = fps_den },
                db_settings.width, db_settings.height,
                { audio_rate = 48000 }
            )

            if not sequence:save() then
                logger.warn("import_resolve", string.format("Failed to create timeline: %s", timeline_data.name))
            else
                table.insert(created_sequence_ids, sequence.id)

                for _, track_data in ipairs(timeline_data.tracks) do
                    local Track = require("models.track")
                    local track_prefix = track_data.type == "VIDEO" and "V" or "A"
                    local track_name = string.format("%s%d", track_prefix, track_data.index)

                    local track
                    if track_data.type == "VIDEO" then
                        track = Track.create_video(track_name, sequence.id, { index = track_data.index })
                    else
                        track = Track.create_audio(track_name, sequence.id, { index = track_data.index })
                    end

                    if not track:save() then
                        logger.warn("import_resolve", string.format("Failed to create track: %s", track_name))
                    else
                        table.insert(created_track_ids, track.id)

                        for _, clip_data in ipairs(track_data.clips) do
                            local media_id = media_id_map[clip_data.resolve_media_id]

                            local source_out = clip_data.source_out
                            if not source_out and clip_data.source_in and clip_data.duration then
                                source_out = clip_data.source_in + clip_data.duration
                            end

                            local clip_fps_num = track_data.type == "AUDIO" and 48000 or fps_num
                            local clip_fps_den = track_data.type == "AUDIO" and 1 or fps_den

                            local clip = Clip_mod.create(clip_data.name or "Untitled Clip", media_id, {
                                project_id = project.id,
                                owner_sequence_id = sequence.id,
                                track_id = track.id,
                                timeline_start = clip_data.start_value,
                                duration = clip_data.duration,
                                source_in = clip_data.source_in,
                                source_out = source_out,
                                fps_numerator = clip_fps_num,
                                fps_denominator = clip_fps_den,
                            })

                            if clip:save() then
                                table.insert(created_clip_ids, clip.id)
                            else
                                logger.warn("import_resolve", string.format("Failed to import clip: %s", clip_data.name))
                            end
                        end
                    end
                end
            end
        end

        logger.info("import_resolve", string.format("Imported Resolve database: %d media, %d sequences, %d tracks, %d clips",
            #created_media_ids, #created_sequence_ids, #created_track_ids, #created_clip_ids))

        persist_and_refresh(command, project.id, {
            media_ids = created_media_ids,
            sequence_ids = created_sequence_ids,
            track_ids = created_track_ids,
            clip_ids = created_clip_ids,
        })

        return { success = true, project_id = project.id }
    end

    undoers["ImportResolveDatabase"] = function(command)
        return import_undoer("UndoImportResolveDatabase", command, db)
    end

    return {
        ["ImportResolveProject"] = {
            executor = executors["ImportResolveProject"],
            undoer = undoers["ImportResolveProject"],
            spec = SPEC_DRP,
        },
        ["ImportResolveDatabase"] = {
            executor = executors["ImportResolveDatabase"],
            undoer = undoers["ImportResolveDatabase"],
            spec = SPEC_DB,
        },
    }
end

return M
