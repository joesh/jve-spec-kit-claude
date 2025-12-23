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
-- Size: ~310 LOC
-- Volatility: unknown
--
-- @file import_resolve_project.lua
-- Original intent (unreviewed):
-- ImportResolveProject and ImportResolveDatabase commands
local M = {}

-- Helper: Escape SQL string literals (double single quotes)
local function sql_escape(str)
    if not str then return "NULL" end
    return "'" .. tostring(str):gsub("'", "''") .. "'"
end

-- Helper: Convert decimal frame rate to rational form (fps_numerator, fps_denominator)
local function frame_rate_to_rational(frame_rate)
    local fps = tonumber(frame_rate)
    if not fps then
        return 30, 1  -- Default fallback
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

function M.register(executors, undoers, db)
    local sqlite3 = require("lsqlite3") -- Assuming available, or via core.sqlite3

    executors["ImportResolveProject"] = function(command)
        local drp_path = command:get_parameter("drp_path")

        if not drp_path or drp_path == "" then
            return {success = false, error_message = "No .drp file path provided"}
        end

        -- Parse .drp file
        local drp_importer = require("importers.drp_importer")
        local parse_result = drp_importer.parse_drp_file(drp_path)

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

        print(string.format("Created project: %s (%dx%d @ %.2ffps)",
            project.name, settings.width, settings.height, settings.frame_rate))

        -- Track created entities for undo
        local created_media_ids = {}
        local created_timeline_ids = {}
        local created_track_ids = {}
        local created_clip_ids = {}

        -- Import media items
        local media_id_map = {}  -- resolve_id -> jve_media_id
        for _, media_item in ipairs(parse_result.media_items) do
            local media = Media.create({
                project_id = project.id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration = media_item.duration,
                width = parse_result.project.settings.width,
                height = parse_result.project.settings.height
            })

            if media:save(db) then
                table.insert(created_media_ids, media.id)
                if media_item.resolve_id then
                    media_id_map[media_item.resolve_id] = media.id
                end
                print(string.format("  Imported media: %s", media.name))
            else
                print(string.format("WARNING: Failed to import media: %s", media_item.name))
            end
        end

        -- Import timelines
        for _, timeline_data in ipairs(parse_result.timelines) do
            -- Create sequence (timeline) record
            local fps_num, fps_den = frame_rate_to_rational(parse_result.project.settings.frame_rate)
            local timeline_id = require("models.clip").generate_id()
            local now = os.time()

            -- Use db:exec() with string formatting (all values are controlled/trusted)
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
                print(string.format("  Imported timeline: %s", timeline_data.name))

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
                        print(string.format("WARNING: Failed to create track: %s%d - %s", track_data.type, track_data.index, tostring(track_err)))
                    end

                    if track_ok then
                        table.insert(created_track_ids, track_id)
                        print(string.format("    Created track: %s%d", track_data.type, track_data.index))

                        -- Import clips
                        for _, clip_data in ipairs(track_data.clips) do
                            -- Find matching media_id (if file_path available)
                            local media_id = nil
                            if clip_data.file_path then
                                for _, media in ipairs(created_media_ids) do
                                    local m = Media.load(media, db)
                                    if m and m.file_path == clip_data.file_path then
                                        media_id = m.id
                                        break
                                    end
                                end
                            end

                            -- Calculate source_out if not provided
                            local source_out = clip_data.source_out
                            if not source_out and clip_data.source_in and clip_data.duration then
                                source_out = clip_data.source_in + clip_data.duration
                            end

                            local clip = Clip.create(clip_data.name or "Untitled Clip", media_id, {
                                track_id = track_id,
                                timeline_start = clip_data.start_value,  -- Renamed from start_value
                                duration = clip_data.duration,
                                source_in = clip_data.source_in,
                                source_out = source_out
                            })

                            if clip:save(db) then
                                table.insert(created_clip_ids, clip.id)
                            else
                                print(string.format("WARNING: Failed to import clip: %s", clip_data.name))
                            end
                        end
                    else
                        print(string.format("WARNING: Failed to create track: %s%d", track_data.type, track_data.index))
                    end

                    -- No finalize needed with db:exec()
                end
            else
                print(string.format("WARNING: Failed to create timeline: %s", timeline_data.name))
            end

            -- No finalize needed with db:exec()
        end

        print(string.format("Imported Resolve project: %d media, %d timelines, %d tracks, %d clips",
            #created_media_ids, #created_timeline_ids, #created_track_ids, #created_clip_ids))

        command:set_parameter("result_project_id", project.id)
        command:set_parameter("created_media_ids", created_media_ids)
        command:set_parameter("created_timeline_ids", created_timeline_ids)
        command:set_parameter("created_track_ids", created_track_ids)
        command:set_parameter("created_clip_ids", created_clip_ids)

        -- Set result for test access
        command.result = {
            success = true,
            project_id = project.id
        }

        return {
            success = true,
            project_id = project.id
        }
    end

    undoers["ImportResolveProject"] = function(command)
        local project_id = command:get_parameter("result_project_id")
        local created_clip_ids = command:get_parameter("created_clip_ids")
        local created_track_ids = command:get_parameter("created_track_ids")
        local created_timeline_ids = command:get_parameter("created_timeline_ids")
        local created_media_ids = command:get_parameter("created_media_ids")

        if not project_id then
            print("ERROR: Cannot undo ImportResolveProject - command state missing")
            return false
        end

        -- Delete clips
        for _, clip_id in ipairs(created_clip_ids or {}) do
            db:exec(string.format("DELETE FROM clips WHERE id = '%s'", clip_id))
        end

        -- Delete tracks
        for _, track_id in ipairs(created_track_ids or {}) do
            db:exec(string.format("DELETE FROM tracks WHERE id = '%s'", track_id))
        end

        -- Delete timelines
        for _, timeline_id in ipairs(created_timeline_ids or {}) do
            db:exec(string.format("DELETE FROM sequences WHERE id = '%s'", timeline_id))
        end

        -- Delete media
        for _, media_id in ipairs(created_media_ids or {}) do
            db:exec(string.format("DELETE FROM media WHERE id = '%s'", media_id))
        end

        -- Delete project
        if project_id then
            db:exec(string.format("DELETE FROM projects WHERE id = '%s'", project_id))
        end

        print("Undo: Deleted imported Resolve project and all associated data")
        return true
    end

    executors["ImportResolveDatabase"] = function(command)
        local db_path = command:get_parameter("db_path")

        if not db_path or db_path == "" then
            return {success = false, error_message = "No database path provided"}
        end

        -- Import from Resolve database
        local resolve_db_importer = require("importers.resolve_database_importer")
        local import_result = resolve_db_importer.import_from_database(db_path)

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

        print(string.format("Created project from Resolve DB: %s (%dx%d @ %.2ffps)",
            project.name, db_settings.width, db_settings.height, db_settings.frame_rate))

        -- Track created entities for undo
        local created_media_ids = {}
        local created_timeline_ids = {}
        local created_track_ids = {}
        local created_clip_ids = {}

        -- Import media items
        local media_id_map = {}  -- resolve_id -> jve_media_id
        for _, media_item in ipairs(import_result.media_items) do
            local media = Media.create({
                project_id = project.id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration = media_item.duration,
                width = import_result.project.width,
                height = import_result.project.height
            })

            if media:save(db) then
                table.insert(created_media_ids, media.id)
                if media_item.resolve_id then
                    media_id_map[media_item.resolve_id] = media.id
                end
                print(string.format("  Imported media: %s", media.name))
            else
                print(string.format("WARNING: Failed to import media: %s", media_item.name))
            end
        end

        -- Import timelines
        for _, timeline_data in ipairs(import_result.timelines) do
            -- Create sequence (timeline) record
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
                print(string.format("  Imported timeline: %s", timeline_data.name))

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
                        print(string.format("WARNING: Failed to create track: %s%d - %s", track_data.type, track_data.index, tostring(track_err)))
                    end

                    if track_ok then
                        table.insert(created_track_ids, track_id)
                        print(string.format("    Created track: %s%d", track_data.type, track_data.index))

                        -- Import clips
                        for _, clip_data in ipairs(track_data.clips) do
                            -- Find matching media_id using resolve_media_id
                            local media_id = media_id_map[clip_data.resolve_media_id]

                            -- Calculate source_out if not provided
                            local source_out = clip_data.source_out
                            if not source_out and clip_data.source_in and clip_data.duration then
                                source_out = clip_data.source_in + clip_data.duration
                            end

                            local clip = Clip.create(clip_data.name or "Untitled Clip", media_id, {
                                track_id = track_id,
                                timeline_start = clip_data.start_value,  -- Renamed from start_value
                                duration = clip_data.duration,
                                source_in = clip_data.source_in,
                                source_out = source_out
                            })

                            if clip:save(db) then
                                table.insert(created_clip_ids, clip.id)
                            else
                                print(string.format("WARNING: Failed to import clip: %s", clip_data.name))
                            end
                        end
                    else
                        print(string.format("WARNING: Failed to create track: %s%d", track_data.type, track_data.index))
                    end

                    -- No finalize needed with db:exec()
                end
            else
                print(string.format("WARNING: Failed to create timeline: %s", timeline_data.name))
            end

            -- No finalize needed with db:exec()
        end

        print(string.format("Imported Resolve database: %d media, %d timelines, %d tracks, %d clips",
            #created_media_ids, #created_timeline_ids, #created_track_ids, #created_clip_ids))

        command:set_parameter("result_project_id", project.id)
        command:set_parameter("created_media_ids", created_media_ids)
        command:set_parameter("created_timeline_ids", created_timeline_ids)
        command:set_parameter("created_track_ids", created_track_ids)
        command:set_parameter("created_clip_ids", created_clip_ids)

        -- Set result for test access
        command.result = {
            success = true,
            project_id = project.id
        }

        return {
            success = true,
            project_id = project.id
        }
    end

    undoers["ImportResolveDatabase"] = undoers["ImportResolveProject"] -- Share logic as structures match

    return {executor = executors["ImportResolveProject"], undoer = undoers["ImportResolveProject"]}
end

return M
