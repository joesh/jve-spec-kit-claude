--- Import Media Command - Import media files with optional interactive dialog
--
-- Responsibilities:
-- - Show file picker dialog when interactive=true
-- - Import single or multiple media files
-- - Create master clips with source sequences
--
-- Non-goals:
-- - Media transcoding or proxy generation (future feature)
--
-- Invariants:
-- - Must receive file_paths array (or gathered from dialog)
-- - Each imported file creates a master clip with source sequence
--
-- Size: ~300 LOC
-- Volatility: low
--
-- @file import_media.lua
local M = {}
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local MediaReader = require("media.media_reader")
local Rational = require("core.rational")
local logger = require("core.logger")

-- Schema for ImportMedia command
local SPEC = {
    args = {
        project_id = { required = true },
        interactive = { kind = "boolean" },  -- If true, show file picker dialog
        file_paths = {},  -- Array of file paths (or gathered from dialog)
        file_path = {},   -- Single file for backward compatibility
    },
    persisted = {
        -- Arrays of IDs for each imported file (parallel arrays)
        media_ids = {},
        master_clip_ids = {},
        master_sequence_ids = {},
        master_video_track_ids = {},
        master_video_clip_ids = {},
        master_audio_track_ids = {},    -- Array of arrays
        master_audio_clip_ids = {},     -- Array of arrays
        media_metadata = {},            -- Array of metadata objects
    },
}

-- Helper: Extract filename from path
local function extract_filename(path)
    if not path then
        return "Imported Media"
    end
    local name = path:match("([^/\\]+)$")
    if not name or name == "" then
        return path
    end
    return name
end

-- Helper: Import a single file and return created entity IDs
-- @param file_path string: Path to media file
-- @param project_id string: Project ID
-- @param db userdata: Database connection
-- @param replay_ids table: Optional IDs to reuse on replay { media_id, master_clip_id, ... }
-- @param set_last_error function: Error handler
-- @return table|nil: Created entity IDs or nil on failure
local function import_single_file(file_path, project_id, db, replay_ids, set_last_error)
    replay_ids = replay_ids or {}

    local media_id, metadata, err = MediaReader.import_media(file_path, db, project_id, replay_ids.media_id)
    if not media_id then
        logger.error("import_media", string.format("Failed to import %s: %s", file_path, err or "unknown error"))
        return nil
    end

    local fps_num = 30
    local fps_den = 1
    if metadata and metadata.video and metadata.video.frame_rate then
        local rate = metadata.video.frame_rate
        if type(rate) == "number" and rate > 0 then
            fps_num = math.floor(rate + 0.5)
        elseif type(rate) == "table" and rate.fps_numerator then
            fps_num = rate.fps_numerator
            fps_den = rate.fps_denominator
        end
    end

    local duration_rat
    if metadata and metadata.duration_ms and metadata.duration_ms > 0 then
        duration_rat = Rational.from_seconds(metadata.duration_ms / 1000.0, fps_num, fps_den)
    else
        duration_rat = Rational.new(fps_num, fps_num, fps_den)  -- 1 second default
    end
    local zero_rat = Rational.new(0, fps_num, fps_den)

    local base_name = extract_filename(file_path)

    -- Create master sequence
    local sequence = Sequence.create(base_name .. " (Source)", project_id,
        {fps_numerator = fps_num, fps_denominator = fps_den},
        metadata and metadata.video and metadata.video.width or 1920,
        metadata and metadata.video and metadata.video.height or 1080,
        {
            id = replay_ids.master_sequence_id,
            kind = "master"
        })
    if not sequence then
        set_last_error("ImportMediaFiles: Failed to create master sequence object")
        return nil
    end
    if not sequence:save() then
        set_last_error("ImportMediaFiles: Failed to save master sequence")
        return nil
    end

    -- Create video track if media has video
    local video_track = nil
    local video_track_id = nil
    if metadata and metadata.has_video then
        video_track = Track.create_video("Video 1", sequence.id, {
            id = replay_ids.master_video_track_id,
            index = 1
        })
        if not video_track or not video_track:save() then
            set_last_error("ImportMediaFiles: Failed to create master video track")
            return nil
        end
        video_track_id = video_track.id
    end

    -- Create audio tracks
    local stored_audio_track_ids = replay_ids.master_audio_track_ids or {}
    local audio_track_ids = {}
    if metadata and metadata.has_audio then
        local channels = metadata.audio and metadata.audio.channels or 1
        if channels < 1 then
            channels = 1
        end
        for channel = 1, channels do
            local track = Track.create_audio(string.format("Audio %d", channel), sequence.id, {
                id = stored_audio_track_ids[channel],
                index = channel
            })
            if not track or not track:save() then
                set_last_error("ImportMediaFiles: Failed to create master audio track")
                return nil
            end
            audio_track_ids[channel] = track.id
        end
    end

    -- Create master clip
    local master_clip = Clip.create(base_name, media_id, {
        id = replay_ids.master_clip_id,
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = sequence.id,
        timeline_start = zero_rat,
        duration = duration_rat,
        source_in = zero_rat,
        source_out = duration_rat,
        enabled = true,
        offline = false,
        fps_numerator = fps_num,
        fps_denominator = fps_den
    })
    local ok_master, occlusion_actions = master_clip:save({skip_occlusion = true})
    if not ok_master then
        set_last_error("ImportMediaFiles: Failed to persist master clip")
        return nil
    end

    -- Create video clip in master sequence
    local video_clip_id = nil
    if video_track then
        local video_clip = Clip.create(master_clip.name .. " (Video)", media_id, {
            id = replay_ids.master_video_clip_id,
            project_id = project_id,
            track_id = video_track.id,
            parent_clip_id = master_clip.id,
            owner_sequence_id = sequence.id,
            timeline_start = zero_rat,
            duration = duration_rat,
            source_in = zero_rat,
            source_out = duration_rat,
            enabled = true,
            offline = false,
            fps_numerator = fps_num,
            fps_denominator = fps_den
        })
        if not video_clip:save({skip_occlusion = true}) then
            set_last_error("ImportMediaFiles: Failed to create master video clip")
            return nil
        end
        video_clip_id = video_clip.id
    end

    -- Create audio clips
    local stored_audio_clip_ids = replay_ids.master_audio_clip_ids or {}
    local audio_clip_ids = {}
    for index, track_id in ipairs(audio_track_ids) do
        local audio_clip = Clip.create(string.format("%s (Audio %d)", master_clip.name, index), media_id, {
            id = stored_audio_clip_ids[index],
            project_id = project_id,
            track_id = track_id,
            parent_clip_id = master_clip.id,
            owner_sequence_id = sequence.id,
            timeline_start = zero_rat,
            duration = duration_rat,
            source_in = zero_rat,
            source_out = duration_rat,
            enabled = true,
            offline = false,
            fps_numerator = fps_num,
            fps_denominator = fps_den
        })
        if not audio_clip:save({skip_occlusion = true}) then
            set_last_error("ImportMediaFiles: Failed to create master audio clip")
            return nil
        end
        audio_clip_ids[index] = audio_clip.id
    end

    return {
        media_id = media_id,
        master_clip_id = master_clip.id,
        master_sequence_id = sequence.id,
        master_video_track_id = video_track_id,
        master_video_clip_id = video_clip_id,
        master_audio_track_ids = audio_track_ids,
        master_audio_clip_ids = audio_clip_ids,
        metadata = metadata,
    }
end

function M.register(command_executors, command_undoers, db, set_last_error)

    -- =========================================================================
    -- ImportMedia: Import media files with optional interactive dialog
    -- =========================================================================
    command_executors["ImportMedia"] = function(command)
        local args = command:get_all_parameters()

        local project_id = args.project_id
        if not project_id or project_id == "" then
            set_last_error("ImportMedia: missing project_id")
            return { success = false, error_message = "Missing project_id" }
        end

        -- Check if file paths provided
        local file_paths = args.file_paths
        if not file_paths and args.file_path then
            -- Single file_path for backward compatibility - convert to array
            file_paths = { args.file_path }
            command:set_parameter("file_paths", file_paths)
        end

        -- If interactive mode or no file paths provided, show dialog
        if args.interactive or not file_paths or type(file_paths) ~= "table" or #file_paths == 0 then
            logger.info("import_media", "ImportMedia: Showing file picker dialog")

            -- Get UI references for dialog
            local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
            if not ui_state_ok then
                set_last_error("ImportMedia: ui_state module not available")
                return { success = false, error_message = "UI state not initialized" }
            end

            local main_window = ui_state.get_main_window()
            if not main_window then
                set_last_error("ImportMedia: main_window not available")
                return { success = false, error_message = "Main window not initialized" }
            end

            -- Show file picker dialog
            file_paths = qt_constants.FILE_DIALOG.OPEN_FILES(
                main_window,
                "Import Media Files",
                "Media Files (*.mp4 *.mov *.m4v *.avi *.mkv *.mxf *.wav *.aiff *.mp3);;All Files (*)"
            )

            if not file_paths or type(file_paths) ~= "table" or #file_paths == 0 then
                -- User cancelled - this is not an error
                logger.debug("import_media", "ImportMedia: User cancelled file picker")
                return { success = true, cancelled = true }
            end

            -- Store the gathered file paths for undo/redo
            command:set_parameter("file_paths", file_paths)
        end

        logger.info("import_media", "Executing ImportMedia command")

        local file_paths = args.file_paths
        if not file_paths or type(file_paths) ~= "table" or #file_paths == 0 then
            set_last_error("ImportMediaFiles: No file paths provided")
            return { success = false, error_message = "No file paths provided" }
        end

        local project_id = args.project_id
        if not project_id or project_id == "" then
            set_last_error("ImportMediaFiles: missing project_id")
            return { success = false, error_message = "Missing project_id" }
        end

        -- Arrays to track all created entities
        local media_ids = args.media_ids or {}
        local master_clip_ids = args.master_clip_ids or {}
        local master_sequence_ids = args.master_sequence_ids or {}
        local master_video_track_ids = args.master_video_track_ids or {}
        local master_video_clip_ids = args.master_video_clip_ids or {}
        local master_audio_track_ids = args.master_audio_track_ids or {}
        local master_audio_clip_ids = args.master_audio_clip_ids or {}
        local media_metadata = args.media_metadata or {}

        local success_count = 0
        local error_messages = {}

        for i, file_path in ipairs(file_paths) do
            logger.debug("import_media", string.format("ImportMediaFiles[%d]: %s", i, tostring(file_path)))

            -- Build replay IDs for deterministic replay
            local replay_ids = {
                media_id = media_ids[i],
                master_clip_id = master_clip_ids[i],
                master_sequence_id = master_sequence_ids[i],
                master_video_track_id = master_video_track_ids[i],
                master_video_clip_id = master_video_clip_ids[i],
                master_audio_track_ids = master_audio_track_ids[i],
                master_audio_clip_ids = master_audio_clip_ids[i],
            }

            local result = import_single_file(file_path, project_id, db, replay_ids, set_last_error)

            if result then
                -- Store created IDs
                media_ids[i] = result.media_id
                master_clip_ids[i] = result.master_clip_id
                master_sequence_ids[i] = result.master_sequence_id
                master_video_track_ids[i] = result.master_video_track_id
                master_video_clip_ids[i] = result.master_video_clip_id
                master_audio_track_ids[i] = result.master_audio_track_ids
                master_audio_clip_ids[i] = result.master_audio_clip_ids
                media_metadata[i] = result.metadata

                success_count = success_count + 1
                logger.info("import_media", string.format("Imported: %s", file_path))
            else
                table.insert(error_messages, string.format("Failed to import: %s", file_path))
            end
        end

        -- Persist all created IDs for undo/redo
        command:set_parameters({
            media_ids = media_ids,
            master_clip_ids = master_clip_ids,
            master_sequence_ids = master_sequence_ids,
            master_video_track_ids = master_video_track_ids,
            master_video_clip_ids = master_video_clip_ids,
            master_audio_track_ids = master_audio_track_ids,
            master_audio_clip_ids = master_audio_clip_ids,
            media_metadata = media_metadata,
        })

        if success_count == 0 then
            return { success = false, error_message = table.concat(error_messages, "\n") }
        end

        -- Refresh project browser to show newly imported media
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if ui_state_ok then
            local project_browser = ui_state.get_project_browser()
            if project_browser and project_browser.refresh then
                project_browser.refresh()
            end
        end

        logger.info("import_media", string.format("Imported %d of %d files", success_count, #file_paths))
        return { success = true, imported_count = success_count, total_count = #file_paths }
    end

    command_undoers["ImportMedia"] = function(command)
        local args = command:get_all_parameters()
        logger.info("import_media", "Undoing ImportMediaFiles command")

        -- Delete in reverse order: clips, tracks, sequences, media
        local master_clip_ids = args.master_clip_ids or {}
        local master_video_clip_ids = args.master_video_clip_ids or {}
        local master_audio_clip_ids = args.master_audio_clip_ids or {}
        local master_video_track_ids = args.master_video_track_ids or {}
        local master_audio_track_ids = args.master_audio_track_ids or {}
        local master_sequence_ids = args.master_sequence_ids or {}
        local media_ids = args.media_ids or {}

        -- Delete audio clips
        for i, audio_clip_ids in ipairs(master_audio_clip_ids) do
            if type(audio_clip_ids) == "table" then
                for _, clip_id in ipairs(audio_clip_ids) do
                    if clip_id and clip_id ~= "" then
                        local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
                        if stmt then
                            stmt:bind_value(1, clip_id)
                            stmt:exec()
                            stmt:finalize()
                        end
                    end
                end
            end
        end

        -- Delete video clips
        for _, clip_id in ipairs(master_video_clip_ids) do
            if clip_id and clip_id ~= "" then
                local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
                if stmt then
                    stmt:bind_value(1, clip_id)
                    stmt:exec()
                    stmt:finalize()
                end
            end
        end

        -- Delete master clips
        for _, clip_id in ipairs(master_clip_ids) do
            if clip_id and clip_id ~= "" then
                local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
                if stmt then
                    stmt:bind_value(1, clip_id)
                    stmt:exec()
                    stmt:finalize()
                end
            end
        end

        -- Delete audio tracks
        for i, audio_track_ids in ipairs(master_audio_track_ids) do
            if type(audio_track_ids) == "table" then
                for _, track_id in ipairs(audio_track_ids) do
                    if track_id and track_id ~= "" then
                        local stmt = db:prepare("DELETE FROM tracks WHERE id = ?")
                        if stmt then
                            stmt:bind_value(1, track_id)
                            stmt:exec()
                            stmt:finalize()
                        end
                    end
                end
            end
        end

        -- Delete video tracks
        for _, track_id in ipairs(master_video_track_ids) do
            if track_id and track_id ~= "" then
                local stmt = db:prepare("DELETE FROM tracks WHERE id = ?")
                if stmt then
                    stmt:bind_value(1, track_id)
                    stmt:exec()
                    stmt:finalize()
                end
            end
        end

        -- Delete sequences
        for _, seq_id in ipairs(master_sequence_ids) do
            if seq_id and seq_id ~= "" then
                local stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
                if stmt then
                    stmt:bind_value(1, seq_id)
                    stmt:exec()
                    stmt:finalize()
                end
            end
        end

        -- Delete media
        for _, media_id in ipairs(media_ids) do
            if media_id and media_id ~= "" then
                local stmt = db:prepare("DELETE FROM media WHERE id = ?")
                if stmt then
                    stmt:bind_value(1, media_id)
                    stmt:exec()
                    stmt:finalize()
                end
            end
        end

        logger.info("import_media", string.format("Undone: deleted %d imported media files", #media_ids))
        return true
    end

    -- Return single-command registration
    return {
        ["ImportMedia"] = {
            executor = command_executors["ImportMedia"],
            undoer = command_undoers["ImportMedia"],
            spec = SPEC,
        },
    }
end

return M
