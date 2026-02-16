--- Import Media Command - Import media files with optional interactive dialog
--
-- Responsibilities:
-- - Show file picker dialog when interactive=true
-- - Import single or multiple media files
-- - Create masterclip sequences (sequence.kind="masterclip")
--
-- Non-goals:
-- - Media transcoding or proxy generation (future feature)
--
-- Invariants:
-- - Must receive file_paths array (or gathered from dialog)
-- - Each imported file creates a masterclip sequence with stream clips
--
-- Architectural note (IS-a model):
-- A masterclip IS a sequence (kind="masterclip"), not a clip wrapping a sequence.
-- Stream clips on the sequence's tracks represent video/audio streams.
-- Timeline clips reference the masterclip via master_clip_id.
--
-- Metadata snapshots:
-- Stream clips snapshot fps_numerator/fps_denominator at creation time.
-- TODO: Implement divergence detection and repair UI.
--
-- Size: ~300 LOC
-- Volatility: low
--
-- @file import_media.lua
local M = {}
local Sequence = require("models.sequence")
local MediaReader = require("media.media_reader")
local logger = require("core.logger")
local file_browser = require("core.file_browser")

-- Schema for ImportMedia command
local SPEC = {
    args = {
        project_id = { required = true },
        sequence_id = {},  -- Optional, may be passed from UI context
        interactive = { kind = "boolean" },  -- If true, show file picker dialog
        file_paths = {},  -- Array of file paths (or gathered from dialog)
        file_path = {},   -- Single file for backward compatibility
    },
    persisted = {
        -- Arrays of IDs for each imported file (parallel arrays)
        media_ids = {},
        masterclip_sequence_ids = {},   -- The masterclip sequences (IS the master clip)
        video_track_ids = {},
        video_clip_ids = {},            -- Stream clips for video
        audio_track_ids = {},           -- Array of arrays
        audio_clip_ids = {},            -- Array of arrays (stream clips for audio)
        media_metadata = {},            -- Array of metadata objects
    },
}

-- Helper: Find existing masterclip sequence and related entities by media_id
-- Returns nil if no masterclip sequence exists for this media
local function find_existing_masterclip(db, media_id)
    -- Find masterclip sequence via a stream clip that references this media
    -- Stream clips are on tracks belonging to masterclip sequences
    local stmt = db:prepare([[
        SELECT s.id, s.fps_numerator, s.fps_denominator
        FROM sequences s
        JOIN tracks t ON t.sequence_id = s.id
        JOIN clips c ON c.track_id = t.id AND c.media_id = ?
        WHERE s.kind = 'masterclip'
        LIMIT 1
    ]])
    if not stmt then return nil end
    stmt:bind_value(1, media_id)
    if not stmt:exec() or not stmt:next() then
        stmt:finalize()
        return nil
    end
    local masterclip_sequence_id = stmt:value(0)
    local old_fps_num = stmt:value(1)
    local old_fps_den = stmt:value(2)
    stmt:finalize()

    -- Find video track and clip
    local video_track_id, video_clip_id
    stmt = db:prepare([[
        SELECT t.id, c.id
        FROM tracks t
        LEFT JOIN clips c ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'VIDEO'
        LIMIT 1
    ]])
    if stmt then
        stmt:bind_value(1, masterclip_sequence_id)
        if stmt:exec() and stmt:next() then
            video_track_id = stmt:value(0)
            video_clip_id = stmt:value(1)
        end
        stmt:finalize()
    end

    -- Find audio tracks and clips
    local audio_track_ids = {}
    local audio_clip_ids = {}
    stmt = db:prepare([[
        SELECT t.id, c.id
        FROM tracks t
        LEFT JOIN clips c ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
        ORDER BY t.track_index
    ]])
    if stmt then
        stmt:bind_value(1, masterclip_sequence_id)
        if stmt:exec() then
            while stmt:next() do
                table.insert(audio_track_ids, stmt:value(0))
                table.insert(audio_clip_ids, stmt:value(1))
            end
        end
        stmt:finalize()
    end

    return {
        masterclip_sequence_id = masterclip_sequence_id,
        video_track_id = video_track_id,
        video_clip_id = video_clip_id,
        audio_track_ids = audio_track_ids,
        audio_clip_ids = audio_clip_ids,
        old_fps_num = old_fps_num,
        old_fps_den = old_fps_den,
    }
end

-- Helper: Update masterclip sequence fps values
local function update_masterclip_fps(db, sequence_id, fps_num, fps_den)
    local stmt = db:prepare([[
        UPDATE sequences SET fps_numerator = ?, fps_denominator = ?, modified_at = ?
        WHERE id = ?
    ]])
    if not stmt then return false end
    stmt:bind_value(1, fps_num)
    stmt:bind_value(2, fps_den)
    stmt:bind_value(3, os.time())
    stmt:bind_value(4, sequence_id)
    local ok = stmt:exec()
    stmt:finalize()
    return ok
end

-- Helper: Import a single file and return created entity IDs
-- @param file_path string: Path to media file
-- @param project_id string: Project ID
-- @param db userdata: Database connection
-- @param replay_ids table: Optional IDs to reuse on replay
-- @param set_last_error function: Error handler
-- @return table|nil: Created entity IDs or nil on failure
local function import_single_file(file_path, project_id, db, replay_ids, set_last_error)
    replay_ids = replay_ids or {}

    -- TODO: Conflict resolution dialog here (future)
    -- Currently auto-updates existing masterclip. Later: show dialog with Skip/Replace/Keep Both.
    local media_id, metadata, err = MediaReader.import_media(file_path, db, project_id, replay_ids.media_id)
    if not media_id then
        logger.error("import_media", string.format("Failed to import %s: %s", file_path, err or "unknown error"))
        return nil
    end

    assert(metadata and metadata.video and metadata.video.frame_rate,
        "ImportMedia: missing video.frame_rate in metadata for " .. tostring(file_path))
    local fps_num, fps_den
    local rate = metadata.video.frame_rate
    if type(rate) == "number" and rate > 0 then
        fps_num = math.floor(rate + 0.5)
        fps_den = 1
    elseif type(rate) == "table" and rate.fps_numerator then
        fps_num = rate.fps_numerator
        fps_den = rate.fps_denominator
    else
        error("ImportMedia: unrecognized frame_rate format for " .. tostring(file_path))
    end

    -- Check existing masterclip for fps update (re-import case)
    local existing = find_existing_masterclip(db, media_id)
    if existing then
        if existing.old_fps_num ~= fps_num or existing.old_fps_den ~= fps_den then
            logger.info("import_media", string.format(
                "Updating masterclip fps: %d/%d -> %d/%d for %s",
                existing.old_fps_num, existing.old_fps_den, fps_num, fps_den, file_path))
            update_masterclip_fps(db, existing.masterclip_sequence_id, fps_num, fps_den)
        else
            logger.debug("import_media", string.format("Masterclip already exists for %s, no fps change", file_path))
        end
        return {
            media_id = media_id,
            masterclip_sequence_id = existing.masterclip_sequence_id,
            video_track_id = existing.video_track_id,
            video_clip_id = existing.video_clip_id,
            audio_track_ids = existing.audio_track_ids,
            audio_clip_ids = existing.audio_clip_ids,
            metadata = metadata,
        }
    end

    -- No existing masterclip: create via Sequence.ensure_masterclip
    local sample_rate = (metadata.audio and metadata.audio.sample_rate) or 48000
    assert(sample_rate > 0, "ImportMedia: invalid sample_rate for " .. tostring(file_path))

    local masterclip_seq_id = Sequence.ensure_masterclip(media_id, project_id, {
        id = replay_ids.masterclip_sequence_id,
        video_track_id = replay_ids.video_track_id,
        video_clip_id = replay_ids.video_clip_id,
        audio_track_ids = replay_ids.audio_track_ids,
        audio_clip_ids = replay_ids.audio_clip_ids,
        sample_rate = sample_rate,
    })

    -- Query created entities for redo ID storage
    local created = find_existing_masterclip(db, media_id)
    assert(created, "ImportMedia: masterclip not found after ensure_masterclip for " .. tostring(file_path))

    return {
        media_id = media_id,
        masterclip_sequence_id = masterclip_seq_id,
        video_track_id = created.video_track_id,
        video_clip_id = created.video_clip_id,
        audio_track_ids = created.audio_track_ids,
        audio_clip_ids = created.audio_clip_ids,
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
            file_paths = file_browser.open_files(
                "import_media", main_window,
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

        -- Re-check file_paths (may have been set by dialog above)
        file_paths = args.file_paths
        if not file_paths or type(file_paths) ~= "table" or #file_paths == 0 then
            set_last_error("ImportMediaFiles: No file paths provided")
            return { success = false, error_message = "No file paths provided" }
        end

        -- Re-check project_id (already validated but need local reference)
        project_id = args.project_id
        if not project_id or project_id == "" then
            set_last_error("ImportMediaFiles: missing project_id")
            return { success = false, error_message = "Missing project_id" }
        end

        -- Arrays to track all created entities
        local media_ids = args.media_ids or {}
        local masterclip_sequence_ids = args.masterclip_sequence_ids or {}
        local video_track_ids = args.video_track_ids or {}
        local video_clip_ids = args.video_clip_ids or {}
        local audio_track_ids = args.audio_track_ids or {}
        local audio_clip_ids = args.audio_clip_ids or {}
        local media_metadata = args.media_metadata or {}

        local success_count = 0
        local error_messages = {}

        for i, file_path in ipairs(file_paths) do
            logger.debug("import_media", string.format("ImportMedia[%d]: %s", i, tostring(file_path)))

            -- Build replay IDs for deterministic replay
            local replay_ids = {
                media_id = media_ids[i],
                masterclip_sequence_id = masterclip_sequence_ids[i],
                video_track_id = video_track_ids[i],
                video_clip_id = video_clip_ids[i],
                audio_track_ids = audio_track_ids[i],
                audio_clip_ids = audio_clip_ids[i],
            }

            local result = import_single_file(file_path, project_id, db, replay_ids, set_last_error)

            if result then
                -- Store created IDs
                media_ids[i] = result.media_id
                masterclip_sequence_ids[i] = result.masterclip_sequence_id
                video_track_ids[i] = result.video_track_id
                video_clip_ids[i] = result.video_clip_id
                audio_track_ids[i] = result.audio_track_ids
                audio_clip_ids[i] = result.audio_clip_ids
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
            masterclip_sequence_ids = masterclip_sequence_ids,
            video_track_ids = video_track_ids,
            video_clip_ids = video_clip_ids,
            audio_track_ids = audio_track_ids,
            audio_clip_ids = audio_clip_ids,
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
        logger.info("import_media", "Undoing ImportMedia command")

        -- Delete in reverse order: clips, tracks, sequences, media
        local video_clip_ids = args.video_clip_ids or {}
        local audio_clip_ids = args.audio_clip_ids or {}
        local video_track_ids = args.video_track_ids or {}
        local audio_track_ids = args.audio_track_ids or {}
        local masterclip_sequence_ids = args.masterclip_sequence_ids or {}
        local media_ids = args.media_ids or {}

        -- Delete audio stream clips
        for _, clip_ids_for_file in ipairs(audio_clip_ids) do
            if type(clip_ids_for_file) == "table" then
                for _, clip_id in ipairs(clip_ids_for_file) do
                    if clip_id and clip_id ~= "" then
                        local stmt = assert(db:prepare("DELETE FROM clips WHERE id = ?"),
                            "UndoImportMedia: failed to prepare audio clip DELETE for " .. tostring(clip_id))
                        stmt:bind_value(1, clip_id)
                        assert(stmt:exec(), "UndoImportMedia: audio clip DELETE failed for " .. tostring(clip_id))
                        stmt:finalize()
                    end
                end
            end
        end

        -- Delete video stream clips
        for _, clip_id in ipairs(video_clip_ids) do
            if clip_id and clip_id ~= "" then
                local stmt = assert(db:prepare("DELETE FROM clips WHERE id = ?"),
                    "UndoImportMedia: failed to prepare video clip DELETE for " .. tostring(clip_id))
                stmt:bind_value(1, clip_id)
                assert(stmt:exec(), "UndoImportMedia: video clip DELETE failed for " .. tostring(clip_id))
                stmt:finalize()
            end
        end

        -- Delete audio tracks
        for _, track_ids_for_file in ipairs(audio_track_ids) do
            if type(track_ids_for_file) == "table" then
                for _, track_id in ipairs(track_ids_for_file) do
                    if track_id and track_id ~= "" then
                        local stmt = assert(db:prepare("DELETE FROM tracks WHERE id = ?"),
                            "UndoImportMedia: failed to prepare audio track DELETE for " .. tostring(track_id))
                        stmt:bind_value(1, track_id)
                        assert(stmt:exec(), "UndoImportMedia: audio track DELETE failed for " .. tostring(track_id))
                        stmt:finalize()
                    end
                end
            end
        end

        -- Delete video tracks
        for _, track_id in ipairs(video_track_ids) do
            if track_id and track_id ~= "" then
                local stmt = assert(db:prepare("DELETE FROM tracks WHERE id = ?"),
                    "UndoImportMedia: failed to prepare video track DELETE for " .. tostring(track_id))
                stmt:bind_value(1, track_id)
                assert(stmt:exec(), "UndoImportMedia: video track DELETE failed for " .. tostring(track_id))
                stmt:finalize()
            end
        end

        -- Delete masterclip sequences
        for _, seq_id in ipairs(masterclip_sequence_ids) do
            if seq_id and seq_id ~= "" then
                local stmt = assert(db:prepare("DELETE FROM sequences WHERE id = ?"),
                    "UndoImportMedia: failed to prepare sequence DELETE for " .. tostring(seq_id))
                stmt:bind_value(1, seq_id)
                assert(stmt:exec(), "UndoImportMedia: sequence DELETE failed for " .. tostring(seq_id))
                stmt:finalize()
            end
        end

        -- Delete media
        for _, media_id in ipairs(media_ids) do
            if media_id and media_id ~= "" then
                local stmt = assert(db:prepare("DELETE FROM media WHERE id = ?"),
                    "UndoImportMedia: failed to prepare media DELETE for " .. tostring(media_id))
                stmt:bind_value(1, media_id)
                assert(stmt:exec(), "UndoImportMedia: media DELETE failed for " .. tostring(media_id))
                stmt:finalize()
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
