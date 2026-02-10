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
-- Size: ~450 LOC
-- Volatility: low
--
-- @file import_resolve_project.lua
local M = {}
local logger = require("core.logger")
local file_browser = require("core.file_browser")

local sql_escape
local frame_rate_to_rational

-- Schema for .drp import command
local SPEC_DRP = {
    args = {
        project_id = { required = true },
        interactive = { kind = "boolean" },  -- If true, show file picker dialog
        drp_path = {},  -- Path to .drp file (or gathered from dialog)
    },
    persisted = {
        created_clip_ids = {},
        created_media_ids = {},
        created_timeline_ids = {},
        created_track_ids = {},
        result_project_id = {},
    },
}

-- Schema for database import command
local SPEC_DB = {
    args = {
        project_id = { required = true },
        interactive = { kind = "boolean" },  -- If true, show file picker dialog
        db_path = {},  -- Path to database file (or gathered from dialog)
    },
    persisted = {
        created_clip_ids = {},
        created_media_ids = {},
        created_timeline_ids = {},
        created_track_ids = {},
        result_project_id = {},
    },
}

function M.register(executors, undoers, db)
    local sqlite3 = require("lsqlite3")

    -- =========================================================================
    -- ImportResolveProject: Import .drp file with optional interactive dialog
    -- =========================================================================
    executors["ImportResolveProject"] = function(command)
        local args = command:get_all_parameters()

        local project_id = args.project_id
        if not project_id or project_id == "" then
            return { success = false, error_message = "Missing project_id" }
        end

        local file_path = args.drp_path

        -- If interactive mode or no file path provided, show dialog
        if args.interactive or not file_path or file_path == "" then
            logger.info("import_resolve", "ImportResolveProject: Showing file picker dialog")

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
                "import_resolve_drp", main_window,
                "Import Resolve Project (.drp)",
                "Resolve Project Files (*.drp);;All Files (*)"
            )

            if not file_path or file_path == "" then
                logger.debug("import_resolve", "ImportResolveProject: User cancelled file picker")
                return { success = true, cancelled = true }
            end

            -- Store the gathered file path for undo/redo
            command:set_parameter("drp_path", file_path)
        end

        logger.info("import_resolve", "Importing Resolve project: " .. tostring(file_path))

        if not args.drp_path or args.drp_path == "" then
            return {success = false, error_message = "No .drp file path provided"}
        end

        -- Parse .drp file
        local drp_importer = require("importers.drp_importer")
        local parse_result = drp_importer.parse_drp_file(args.drp_path)

        if not parse_result.success then
            return {success = false, error_message = parse_result.error}
        end

        local Project = require("models.project")
        local Media = require("models.media")
        local Clip = require("models.clip")
        local json = require("dkjson")

        -- Create project record with settings JSON
        local settings = {
            frame_rate = parse_result.project.settings.frame_rate,
            width = parse_result.project.settings.width,
            height = parse_result.project.settings.height
        }

        local project = Project.create(parse_result.project.name, {
            settings = json.encode(settings)
        })

        if not project:save(db) then
            return {success = false, error_message = "Failed to create project"}
        end

        logger.info("import_resolve", string.format("Created project: %s (%dx%d @ %.2ffps)",
            project.name, settings.width, settings.height, settings.frame_rate))

        -- Track created entities for undo
        local created_media_ids = {}
        local created_timeline_ids = {}
        local created_track_ids = {}
        local created_clip_ids = {}

        -- Import media items
        local media_id_map = {}
        for _, media_item in ipairs(parse_result.media_items) do
            local media = Media.create({
                project_id = project.id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration_frames = media_item.duration,  -- drp_importer returns frames, not ms
                frame_rate = media_item.frame_rate or parse_result.project.settings.frame_rate,
                width = parse_result.project.settings.width,
                height = parse_result.project.settings.height
            })

            if media:save() then
                table.insert(created_media_ids, media.id)
                if media_item.resolve_id then
                    media_id_map[media_item.resolve_id] = media.id
                end
                logger.debug("import_resolve", string.format("  Imported media: %s", media.name))
            else
                logger.warn("import_resolve", string.format("Failed to import media: %s", media_item.name))
            end
        end

        -- Import timelines
        for _, timeline_data in ipairs(parse_result.timelines) do
            local fps_num, fps_den = frame_rate_to_rational(parse_result.project.settings.frame_rate)
            local timeline_id = require("models.clip").generate_id()
            local now = os.time()

            local sql = string.format([[
                INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
                VALUES ('%s', '%s', %s, 'timeline', %d, %d, 48000, %d, %d, %d, %d)
            ]], timeline_id, project.id, sql_escape(timeline_data.name), fps_num, fps_den, settings.width, settings.height, now, now)

            local ok, err = db:exec(sql)
            if not ok then
                return {success = false, error_message = string.format("Failed to insert sequence: %s", tostring(err))}
            end

            if ok then
                table.insert(created_timeline_ids, timeline_id)
                logger.debug("import_resolve", string.format("  Imported timeline: %s", timeline_data.name))

                -- Import tracks
                for _, track_data in ipairs(timeline_data.tracks) do
                    local track_id = require("models.clip").generate_id()
                    local track_prefix = track_data.type == "VIDEO" and "V" or "A"
                    local track_name = string.format("%s%d", track_prefix, track_data.index)

                    local track_sql = string.format([[
                        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
                        VALUES ('%s', '%s', '%s', '%s', %d)
                    ]], track_id, timeline_id, track_name, track_data.type, track_data.index)

                    local track_ok, track_err = db:exec(track_sql)
                    if not track_ok then
                        logger.warn("import_resolve", string.format("Failed to create track: %s%d - %s", track_data.type, track_data.index, tostring(track_err)))
                    end

                    if track_ok then
                        table.insert(created_track_ids, track_id)

                        -- Import clips
                        for _, clip_data in ipairs(track_data.clips) do
                            local media_id = nil
                            if clip_data.file_path then
                                for _, media in ipairs(created_media_ids) do
                                    local m = Media.load(media)
                                    if m and m.file_path == clip_data.file_path then
                                        media_id = m.id
                                        break
                                    end
                                end
                            end

                            local source_out = clip_data.source_out
                            if not source_out and clip_data.source_in and clip_data.duration then
                                source_out = clip_data.source_in + clip_data.duration
                            end

                            -- Audio clips use 48000/1 rate (source coords in samples)
                            -- Video clips use timeline fps (source coords in frames)
                            local clip_fps_num = track_data.type == "AUDIO" and 48000 or fps_num
                            local clip_fps_den = track_data.type == "AUDIO" and 1 or fps_den

                            local clip = Clip.create(clip_data.name or "Untitled Clip", media_id, {
                                track_id = track_id,
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

        logger.info("import_resolve", string.format("Imported Resolve project: %d media, %d timelines, %d tracks, %d clips",
            #created_media_ids, #created_timeline_ids, #created_track_ids, #created_clip_ids))

        command:set_parameters({
            ["result_project_id"] = project.id,
            ["created_media_ids"] = created_media_ids,
            ["created_timeline_ids"] = created_timeline_ids,
            ["created_track_ids"] = created_track_ids,
            ["created_clip_ids"] = created_clip_ids,
        })

        -- Refresh project browser
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if ui_state_ok then
            local project_browser = ui_state.get_project_browser()
            if project_browser and project_browser.refresh then
                project_browser.refresh()
            end
        end

        return {
            success = true,
            project_id = project.id
        }
    end

    -- Undoer for ImportResolveProject
    local function resolve_project_undoer(command)
        local args = command:get_all_parameters()

        assert(args.result_project_id, "UndoImportResolveProject: missing result_project_id")

        -- Delete clips
        for _, clip_id in ipairs(args.created_clip_ids or {}) do
            assert(db:exec(string.format("DELETE FROM clips WHERE id = '%s'", clip_id)),
                "UndoImportResolveProject: clips DELETE failed for " .. tostring(clip_id))
        end

        -- Delete tracks
        for _, track_id in ipairs(args.created_track_ids or {}) do
            assert(db:exec(string.format("DELETE FROM tracks WHERE id = '%s'", track_id)),
                "UndoImportResolveProject: tracks DELETE failed for " .. tostring(track_id))
        end

        -- Delete timelines
        for _, timeline_id in ipairs(args.created_timeline_ids or {}) do
            assert(db:exec(string.format("DELETE FROM sequences WHERE id = '%s'", timeline_id)),
                "UndoImportResolveProject: sequences DELETE failed for " .. tostring(timeline_id))
        end

        -- Delete media
        for _, media_id in ipairs(args.created_media_ids or {}) do
            assert(db:exec(string.format("DELETE FROM media WHERE id = '%s'", media_id)),
                "UndoImportResolveProject: media DELETE failed for " .. tostring(media_id))
        end

        -- Delete project
        assert(db:exec(string.format("DELETE FROM projects WHERE id = '%s'", args.result_project_id)),
            "UndoImportResolveProject: projects DELETE failed for " .. tostring(args.result_project_id))

        logger.info("import_resolve", "Undo: Deleted imported Resolve project and all associated data")
        return true
    end

    undoers["ImportResolveProject"] = resolve_project_undoer

    -- =========================================================================
    -- ImportResolveDatabase: Import Resolve database with optional interactive dialog
    -- =========================================================================
    executors["ImportResolveDatabase"] = function(command)
        local args = command:get_all_parameters()

        local project_id = args.project_id
        if not project_id or project_id == "" then
            return { success = false, error_message = "Missing project_id" }
        end

        local file_path = args.db_path

        -- If interactive mode or no file path provided, show dialog
        if args.interactive or not file_path or file_path == "" then
            logger.info("import_resolve", "ImportResolveDatabase: Showing file picker dialog")

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
                "import_resolve_db", main_window,
                "Import Resolve Database",
                "Database Files (*.db *.sqlite *.resolve);;All Files (*)",
                os.getenv("HOME") .. "/Movies/DaVinci Resolve"
            )

            if not file_path or file_path == "" then
                logger.debug("import_resolve", "ImportResolveDatabase: User cancelled file picker")
                return { success = true, cancelled = true }
            end

            -- Store the gathered file path for undo/redo
            command:set_parameter("db_path", file_path)
        end

        logger.info("import_resolve", "Importing Resolve database: " .. tostring(file_path))

        if not args.db_path or args.db_path == "" then
            return {success = false, error_message = "No database path provided"}
        end

        -- Import from Resolve database
        local resolve_db_importer = require("importers.resolve_database_importer")
        local import_result = resolve_db_importer.import_from_database(args.db_path)

        if not import_result.success then
            return {success = false, error_message = import_result.error}
        end

        local Project = require("models.project")
        local Media = require("models.media")
        local Clip = require("models.clip")
        local json = require("dkjson")

        -- Create project record with settings JSON
        local db_settings = {
            frame_rate = import_result.project.frame_rate,
            width = import_result.project.width,
            height = import_result.project.height
        }

        local project = Project.create(import_result.project.name, {
            settings = json.encode(db_settings)
        })

        if not project:save(db) then
            return {success = false, error_message = "Failed to create project"}
        end

        logger.info("import_resolve", string.format("Created project from Resolve DB: %s (%dx%d @ %.2ffps)",
            project.name, db_settings.width, db_settings.height, db_settings.frame_rate))

        -- Track created entities for undo
        local created_media_ids = {}
        local created_timeline_ids = {}
        local created_track_ids = {}
        local created_clip_ids = {}

        -- Import media items
        local media_id_map = {}
        for _, media_item in ipairs(import_result.media_items) do
            local media = Media.create({
                project_id = project.id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration_frames = media_item.duration,  -- resolve_database_importer returns frames, not ms
                frame_rate = media_item.frame_rate or import_result.project.frame_rate,
                width = import_result.project.width,
                height = import_result.project.height
            })

            if media:save() then
                table.insert(created_media_ids, media.id)
                if media_item.resolve_id then
                    media_id_map[media_item.resolve_id] = media.id
                end
                logger.debug("import_resolve", string.format("  Imported media: %s", media.name))
            else
                logger.warn("import_resolve", string.format("Failed to import media: %s", media_item.name))
            end
        end

        -- Import timelines
        for _, timeline_data in ipairs(import_result.timelines) do
            local fps_num, fps_den = frame_rate_to_rational(timeline_data.frame_rate or import_result.project.frame_rate)
            local timeline_id = require("models.clip").generate_id()
            local now = os.time()

            local sql = string.format([[
                INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
                VALUES ('%s', '%s', %s, 'timeline', %d, %d, 48000, %d, %d, %d, %d)
            ]], timeline_id, project.id, sql_escape(timeline_data.name), fps_num, fps_den, db_settings.width, db_settings.height, now, now)

            local ok, err = db:exec(sql)
            if not ok then
                return {success = false, error_message = string.format("Failed to insert sequence: %s", tostring(err))}
            end

            if ok then
                table.insert(created_timeline_ids, timeline_id)
                logger.debug("import_resolve", string.format("  Imported timeline: %s", timeline_data.name))

                -- Import tracks
                for _, track_data in ipairs(timeline_data.tracks) do
                    local track_id = require("models.clip").generate_id()
                    local track_prefix = track_data.type == "VIDEO" and "V" or "A"
                    local track_name = string.format("%s%d", track_prefix, track_data.index)

                    local track_sql = string.format([[
                        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
                        VALUES ('%s', '%s', '%s', '%s', %d)
                    ]], track_id, timeline_id, track_name, track_data.type, track_data.index)

                    local track_ok, track_err = db:exec(track_sql)
                    if not track_ok then
                        logger.warn("import_resolve", string.format("Failed to create track: %s%d - %s", track_data.type, track_data.index, tostring(track_err)))
                    end

                    if track_ok then
                        table.insert(created_track_ids, track_id)

                        -- Import clips
                        for _, clip_data in ipairs(track_data.clips) do
                            local media_id = media_id_map[clip_data.resolve_media_id]

                            local source_out = clip_data.source_out
                            if not source_out and clip_data.source_in and clip_data.duration then
                                source_out = clip_data.source_in + clip_data.duration
                            end

                            -- Audio clips use 48000/1 rate (source coords in samples)
                            -- Video clips use timeline fps (source coords in frames)
                            local clip_fps_num = track_data.type == "AUDIO" and 48000 or fps_num
                            local clip_fps_den = track_data.type == "AUDIO" and 1 or fps_den

                            local clip = Clip.create(clip_data.name or "Untitled Clip", media_id, {
                                track_id = track_id,
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

        logger.info("import_resolve", string.format("Imported Resolve database: %d media, %d timelines, %d tracks, %d clips",
            #created_media_ids, #created_timeline_ids, #created_track_ids, #created_clip_ids))

        command:set_parameters({
            ["result_project_id"] = project.id,
            ["created_media_ids"] = created_media_ids,
            ["created_timeline_ids"] = created_timeline_ids,
            ["created_track_ids"] = created_track_ids,
            ["created_clip_ids"] = created_clip_ids,
        })

        -- Refresh project browser
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if ui_state_ok then
            local project_browser = ui_state.get_project_browser()
            if project_browser and project_browser.refresh then
                project_browser.refresh()
            end
        end

        return {
            success = true,
            project_id = project.id,
        }
    end

    -- Undoer for ImportResolveDatabase (shared undoer logic)
    local function resolve_database_undoer(command)
        local args = command:get_all_parameters()

        assert(args.result_project_id, "UndoImportResolveDatabase: missing result_project_id")

        -- Delete clips
        for _, clip_id in ipairs(args.created_clip_ids or {}) do
            assert(db:exec(string.format("DELETE FROM clips WHERE id = '%s'", clip_id)),
                "UndoImportResolveDatabase: clips DELETE failed for " .. tostring(clip_id))
        end

        -- Delete tracks
        for _, track_id in ipairs(args.created_track_ids or {}) do
            assert(db:exec(string.format("DELETE FROM tracks WHERE id = '%s'", track_id)),
                "UndoImportResolveDatabase: tracks DELETE failed for " .. tostring(track_id))
        end

        -- Delete timelines
        for _, timeline_id in ipairs(args.created_timeline_ids or {}) do
            assert(db:exec(string.format("DELETE FROM sequences WHERE id = '%s'", timeline_id)),
                "UndoImportResolveDatabase: sequences DELETE failed for " .. tostring(timeline_id))
        end

        -- Delete media
        for _, media_id in ipairs(args.created_media_ids or {}) do
            assert(db:exec(string.format("DELETE FROM media WHERE id = '%s'", media_id)),
                "UndoImportResolveDatabase: media DELETE failed for " .. tostring(media_id))
        end

        -- Delete project
        assert(db:exec(string.format("DELETE FROM projects WHERE id = '%s'", args.result_project_id)),
            "UndoImportResolveDatabase: projects DELETE failed for " .. tostring(args.result_project_id))

        logger.info("import_resolve", "Undo: Deleted imported Resolve database and all associated data")
        return true
    end

    undoers["ImportResolveDatabase"] = resolve_database_undoer

    -- Return command registration
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

-- Helper: Escape SQL string literals (double single quotes)
sql_escape = function(str)
    if not str then return "NULL" end
    return "'" .. tostring(str):gsub("'", "''") .. "'"
end

-- Helper: Convert decimal frame rate to rational form (fps_numerator, fps_denominator)
frame_rate_to_rational = function(frame_rate)
    local fps = tonumber(frame_rate)
    if not fps then
        error("ImportResolveProject: missing/invalid frame_rate", 2)
    end

    -- Handle common NTSC fractional frame rates
    if math.abs(fps - 23.976) < 0.01 then
        return 24000, 1001
    elseif math.abs(fps - 29.97) < 0.01 then
        return 30000, 1001
    elseif math.abs(fps - 59.94) < 0.01 then
        return 60000, 1001
    end

    -- Integer frame rates
    return math.floor(fps + 0.5), 1
end

return M
