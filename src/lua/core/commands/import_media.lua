local M = {}
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local MediaReader = require("media.media_reader")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["ImportMedia"] = function(command)
        print("Executing ImportMedia command")

        local file_path = command:get_parameter("file_path")
        local project_id = command:get_parameter("project_id")
        local existing_media_id = command:get_parameter("media_id")

        if not file_path or file_path == "" or not project_id or project_id == "" then
            print("WARNING: ImportMedia: Missing required parameters")
            return false
        end

        local media_id, metadata, err = MediaReader.import_media(file_path, db, project_id, existing_media_id)

        if not media_id then
            print(string.format("ERROR: ImportMedia: Failed to import %s: %s", file_path, err or "unknown error"))
            return false
        end

        command:set_parameter("media_id", media_id)
        if metadata then
            command:set_parameter("media_metadata", metadata)
        end

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

        local duration_ms = 1000
        if metadata and metadata.duration_ms and metadata.duration_ms > 0 then
            duration_ms = math.floor(metadata.duration_ms + 0.5)
        end
        if duration_ms <= 0 then
            duration_ms = 1000
        end

        local base_name = extract_filename(file_path)
        local master_sequence_id = command:get_parameter("master_sequence_id")
        local sequence = Sequence.create(base_name .. " (Source)", project_id,
            metadata and metadata.video and metadata.video.frame_rate or 30.0,
            metadata and metadata.video and metadata.video.width or 1920,
            metadata and metadata.video and metadata.video.height or 1080,
            {
                id = master_sequence_id,
                kind = "master",
                timecode_start_frame = 0
            })
        if not sequence then
            print("ERROR: ImportMedia: Failed to create master sequence object")
            return false
        end
        if not sequence:save(db) then
            print("ERROR: ImportMedia: Failed to save master sequence")
            return false
        end
        command:set_parameter("master_sequence_id", sequence.id)

        local master_video_track_id = command:get_parameter("master_video_track_id")
        local video_track = nil
        if metadata and metadata.has_video then
            video_track = Track.create_video("Video 1", sequence.id, {
                id = master_video_track_id,
                index = 1,
                db = db
            })
            if not video_track or not video_track:save(db) then
                print("ERROR: ImportMedia: Failed to create master video track")
                return false
            end
            command:set_parameter("master_video_track_id", video_track.id)
        else
            command:set_parameter("master_video_track_id", nil)
        end

        local stored_audio_track_ids = command:get_parameter("master_audio_track_ids")
        if type(stored_audio_track_ids) ~= "table" then
            stored_audio_track_ids = {}
        end
        local audio_track_ids = {}
        if metadata and metadata.has_audio then
            local channels = metadata.audio and metadata.audio.channels or 1
            if channels < 1 then
                channels = 1
            end
            for channel = 1, channels do
                local track = Track.create_audio(string.format("Audio %d", channel), sequence.id, {
                    id = stored_audio_track_ids[channel],
                    index = channel,
                    db = db
                })
                if not track or not track:save(db) then
                    print("ERROR: ImportMedia: Failed to create master audio track")
                    return false
                end
                audio_track_ids[channel] = track.id
            end
        end
        command:set_parameter("master_audio_track_ids", audio_track_ids)

        local master_clip_id = command:get_parameter("master_clip_id")
        local master_clip = Clip.create(base_name, media_id, {
            id = master_clip_id,
            project_id = project_id,
            clip_kind = "master",
            source_sequence_id = sequence.id,
            start_value = 0,
            duration = duration_ms,
            source_in = 0,
            source_out = duration_ms,
            enabled = true,
            offline = false
        })
        local ok_master, occlusion_actions = master_clip:save(db, {skip_occlusion = true})
        if not ok_master then
            print("ERROR: ImportMedia: Failed to persist master clip")
            return false
        end
        command:set_parameter("master_clip_id", master_clip.id)
        if occlusion_actions and #occlusion_actions > 0 then
            print("WARNING: ImportMedia: Unexpected occlusion actions when saving master clip")
        end

        if video_track then
            local video_clip_id = command:get_parameter("master_video_clip_id")
            local video_clip = Clip.create(master_clip.name .. " (Video)", media_id, {
                id = video_clip_id,
                project_id = project_id,
                track_id = video_track.id,
                parent_clip_id = master_clip.id,
                owner_sequence_id = sequence.id,
                start_value = 0,
                duration = duration_ms,
                source_in = 0,
                source_out = duration_ms,
                enabled = true,
                offline = false
            })
            if not video_clip:save(db, {skip_occlusion = true}) then
                print("ERROR: ImportMedia: Failed to create master video clip")
                return false
            end
            command:set_parameter("master_video_clip_id", video_clip.id)
        else
            command:set_parameter("master_video_clip_id", nil)
        end

        local stored_audio_clip_ids = command:get_parameter("master_audio_clip_ids")
        if type(stored_audio_clip_ids) ~= "table" then
            stored_audio_clip_ids = {}
        end
        local audio_clip_ids = {}
        for index, track_id in ipairs(audio_track_ids) do
            local audio_clip = Clip.create(string.format("%s (Audio %d)", master_clip.name, index), media_id, {
                id = stored_audio_clip_ids[index],
                project_id = project_id,
                track_id = track_id,
                parent_clip_id = master_clip.id,
                owner_sequence_id = sequence.id,
                start_value = 0,
                duration = duration_ms,
                source_in = 0,
                source_out = duration_ms,
                enabled = true,
                offline = false
            })
            if not audio_clip:save(db, {skip_occlusion = true}) then
                print("ERROR: ImportMedia: Failed to create master audio clip")
                return false
            end
            audio_clip_ids[index] = audio_clip.id
        end
        command:set_parameter("master_audio_clip_ids", audio_clip_ids)

        print(string.format("Imported media: %s with ID: %s", file_path, media_id))
        return true
    end

    command_undoers["ImportMedia"] = function(command)
        print("Undoing ImportMedia command")

        local media_id = command:get_parameter("media_id")

        if not media_id or media_id == "" then
            print("WARNING: ImportMedia undo: No media_id found in command parameters")
            return false
        end

        local master_clip_id = command:get_parameter("master_clip_id")
        if master_clip_id and master_clip_id ~= "" then
            local clip_stmt = db:prepare("DELETE FROM clips WHERE id = ?")
            if clip_stmt then
                clip_stmt:bind_value(1, master_clip_id)
                clip_stmt:exec()
                clip_stmt:finalize()
            end
        end

        local master_sequence_id = command:get_parameter("master_sequence_id")
        if master_sequence_id and master_sequence_id ~= "" then
            local seq_stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
            if seq_stmt then
                seq_stmt:bind_value(1, master_sequence_id)
                seq_stmt:exec()
                seq_stmt:finalize()
            end
        end

        local stmt = db:prepare("DELETE FROM media WHERE id = ?")
        if not stmt then
            print("ERROR: ImportMedia undo: Failed to prepare DELETE statement")
            return false
        end

        stmt:bind_value(1, media_id)
        local success = stmt:exec()

        if success then
            print(string.format("Deleted imported media: %s", media_id))
            return true
        else
            print(string.format("ERROR: ImportMedia undo: Failed to delete media: %s", media_id))
            return false
        end
    end

    return {
        executor = command_executors["ImportMedia"],
        undoer = command_undoers["ImportMedia"]
    }
end

return M
