--- ShowRelinkDialog command: relink master clips to new media locations
--
-- Responsibilities:
-- - If clips selected: relink their master clips (deduplicated)
-- - If no selection: relink all master clips in the project
-- - Show reconnect dialog with clip list, matching rules, search directory
-- - Auto-resolve duplicate media using folder priority
-- - On user confirm, dispatch RelinkClips with clip_relink_map + media changes
--
-- @file show_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

local SPEC = {
    args = {},
    undoable = false,
}

--- Given folder priority order and a media path, return its priority (lower = better).
-- @param path string Media file path
-- @param folder_priority table Ordered array of folder roots (index 1 = highest)
-- @return number Priority (1 = highest, #folder_priority+1 = no match)
local function get_folder_priority(path, folder_priority)
    for i, root in ipairs(folder_priority) do
        if path:sub(1, #root) == root then
            return i
        end
    end
    return #folder_priority + 1  -- unmatched = lowest
end

function M.register(executors, _undoers, db)

    executors["ShowRelinkDialog"] = function(_command)
        local media_relinker = require("core.media_relinker")
        local timeline_state = require("ui.timeline.timeline_state")

        local project_id = timeline_state.get_project_id()
        assert(project_id, "ShowRelinkDialog: no project open")

        -- Selected clips → their master clips; no selection → all project media
        local selected_clips = timeline_state.get_selected_clips()
        local selected_ids = {}
        for _, clip in ipairs(selected_clips or {}) do
            if clip.clip_kind ~= "gap" then
                selected_ids[#selected_ids + 1] = clip.id
            end
        end

        local media_list
        if #selected_ids > 0 then
            media_list = media_relinker.find_media_for_clips(db, selected_ids)
            log.event("ShowRelinkDialog: %d master clip(s) from %d selected clip(s)",
                #media_list, #selected_ids)
        else
            media_list = media_relinker.find_project_media(db, project_id)
            log.event("ShowRelinkDialog: %d master clip(s) in project", #media_list)
        end

        if #media_list == 0 then
            log.event("ShowRelinkDialog: no media to relink")
            return { success = true, message = "No media to relink" }
        end

        local ui_state = require("ui.ui_state")
        local parent_window = ui_state.get_main_window and ui_state.get_main_window() or nil

        local media_relink_dialog = require("ui.media_relink_dialog")
        local apply_result = nil

        local function do_apply(results)
            local Media = require("models.media")
        assert(results.folder_priority, "ShowRelinkDialog: results missing folder_priority")
        local folder_priority = results.folder_priority
        local clip_relink_map = {}
        local media_path_changes = {}
        local new_media_records = {}  -- split-created clone media
        local clone_path_to_id = {}  -- track clone paths created this session
        local path_to_media = {}     -- new_path → {media_id, priority}
        local media_orig_paths = {}  -- media_id → original file_path

        -- Helper: check if a path is already owned by an existing media record in the DB
        local db_path_cache = {}  -- path → media_id or false
        local function find_existing_media_by_path(path)
            if db_path_cache[path] ~= nil then
                return db_path_cache[path] ~= false and db_path_cache[path] or nil
            end
            local stmt = db:prepare("SELECT id FROM media WHERE file_path = ? LIMIT 1")
            if not stmt then db_path_cache[path] = false; return nil end
            stmt:bind_value(1, path)
            local found_id = nil
            if stmt:exec() and stmt:next() then
                found_id = stmt:value(0)
            end
            stmt:finalize()
            db_path_cache[path] = found_id or false
            return found_id
        end

        -- Relink output is per-media: {media_id, new_path, strategy, needs_split?, split_clip_ids?}.
        -- Build media_path_changes, handle path conflicts and splits.
        local Clip = require("models.clip")
        local uuid = require("uuid")
        local priority_losers = {}  -- loser_media_id → winner_media_id

        for _, entry in ipairs(results.relinked) do
            local mid = entry.media_id

            if not media_orig_paths[mid] then
                local m = Media.load(mid)
                assert(m, string.format("ShowRelinkDialog: media not found: %s", mid))
                media_orig_paths[mid] = m:get_file_path()
            end

            -- Split: some clips fit, others don't. Clone media for the fitting clips.
            if entry.needs_split and entry.split_clip_ids then
                local original = Media.load(mid)
                assert(original, "ShowRelinkDialog: split source media not found: " .. mid)
                -- Check if target path already belongs to an existing or session-created media
                local existing_at_path = clone_path_to_id[entry.new_path] or find_existing_media_by_path(entry.new_path)
                if existing_at_path then
                    -- Path taken — reassign to existing instead of cloning
                    for _, clip_id in ipairs(entry.split_clip_ids) do
                        clip_relink_map[clip_id] = { new_media_id = existing_at_path }
                    end
                    path_to_media[entry.new_path] = path_to_media[entry.new_path] or
                        { media_id = existing_at_path, priority = 0 }
                    log.event("split→existing: media %s → existing %s (%d clips)",
                        mid:sub(1, 8), existing_at_path:sub(1, 8), #entry.split_clip_ids)
                    goto continue_relink
                end

                local dur = original.duration
                local fps_num = original.frame_rate and original.frame_rate.fps_numerator
                local fps_den = original.frame_rate and original.frame_rate.fps_denominator
                if not dur or dur <= 0 or not fps_num or fps_num <= 0 then
                    goto continue_relink
                end
                local clone_id = uuid.generate_with_prefix("media")
                -- Don't create clone here — RelinkClips Phase 1 creates it
                -- inside the command transaction (so undo can fully revert).
                clone_path_to_id[entry.new_path] = clone_id
                path_to_media[entry.new_path] = { media_id = clone_id, priority = 0 }
                new_media_records[#new_media_records + 1] = {
                    id = clone_id, path = entry.new_path, name = original.name,
                    duration_frames = dur,
                    fps_num = fps_num, fps_den = fps_den or 1,
                    audio_sample_rate = original.audio_sample_rate,
                    audio_channels = original.audio_channels,
                    width = original.width,
                    height = original.height,
                    metadata = original.metadata,
                }
                -- Reassign fitting clips to the clone
                for _, clip_id in ipairs(entry.split_clip_ids) do
                    clip_relink_map[clip_id] = { new_media_id = clone_id }
                end
                log.event("split: media %s → clone %s (%d clips) at %s",
                    mid:sub(1, 8), clone_id:sub(1, 8), #entry.split_clip_ids,
                    entry.new_path:match("([^/]+)$") or entry.new_path)
                goto continue_relink
            end

            -- Check if path already belongs to an existing or session-created media
            local db_owner = clone_path_to_id[entry.new_path] or find_existing_media_by_path(entry.new_path)
            if db_owner and db_owner ~= mid then
                priority_losers[mid] = db_owner
                goto continue_relink
            end

            local my_priority = get_folder_priority(media_orig_paths[mid], folder_priority)
            local existing = path_to_media[entry.new_path]

            if not existing or existing.media_id == mid then
                if not existing then
                    path_to_media[entry.new_path] = {
                        media_id = mid, priority = my_priority
                    }
                end
                media_path_changes[mid] = entry.new_path
            elseif my_priority < existing.priority then
                log.event("folder priority: %s (pri=%d) beats %s (pri=%d) for %s",
                    mid:sub(1, 8), my_priority,
                    existing.media_id:sub(1, 8), existing.priority,
                    entry.new_path:match("([^/]+)$") or entry.new_path)
                media_path_changes[existing.media_id] = nil
                priority_losers[existing.media_id] = mid
                media_path_changes[mid] = entry.new_path
                path_to_media[entry.new_path] = {
                    media_id = mid, priority = my_priority
                }
            else
                priority_losers[mid] = existing.media_id
            end

            ::continue_relink::
        end

        -- Reassign clips from priority-loser media to winners (lazy clip load)
        for loser_mid, winner_mid in pairs(priority_losers) do
            local clips = Clip.find_clips_for_media(loser_mid)
            for _, clip in ipairs(clips) do
                clip_relink_map[clip.id] = { new_media_id = winner_mid }
            end
            log.event("priority reassign: %d clips from media %s → winner %s",
                #clips, loser_mid:sub(1, 8), winner_mid:sub(1, 8))
        end

        -- Second pass: salvage failed entries by looking for a pre-existing
        -- media row that points at a valid on-disk file. This handles the
        -- duplicate-media-row case: two media rows share the same basename,
        -- one is already at the fixture path (previous session or explicit
        -- import), but the failing clip still references the other "local"
        -- row. The relinker's own candidates failed containment against the
        -- failing media's metadata, but a sibling row's metadata may match.
        -- Reassign the clip's media_id to the sibling row; no new path write.
        -- Dedupe salvage: for failed media, check for sibling media rows
        -- with the same name whose file_path exists on disk. Reassign all clips.
        local dedupe_stmt = db:prepare([[
            SELECT id, file_path FROM media
            WHERE project_id = ?
              AND name = (SELECT name FROM media WHERE id = ?)
              AND id != ?
        ]])
        local dedupe_salvaged = 0
        for _, entry in ipairs(results.failed or {}) do
            local mid = entry.media_id
            if mid then
                dedupe_stmt:bind_value(1, project_id)
                dedupe_stmt:bind_value(2, mid)
                dedupe_stmt:bind_value(3, mid)
                if dedupe_stmt:exec() then
                    while dedupe_stmt:next() do
                        local sibling_id = dedupe_stmt:value(0)
                        local sibling_path = dedupe_stmt:value(1)
                        local f = sibling_path and io.open(sibling_path, "r")
                        if f then
                            f:close()
                            -- Sibling row points at a file that exists — reassign all clips
                            local clips = Clip.find_clips_for_media(mid)
                            for _, clip in ipairs(clips) do
                                if not clip_relink_map[clip.id] then
                                    clip_relink_map[clip.id] = { new_media_id = sibling_id }
                                end
                            end
                            log.event("dedupe: media %s → sibling %s (%d clips, %s)",
                                mid:sub(1, 8), sibling_id:sub(1, 8), #clips,
                                sibling_path:match("([^/]+)$") or sibling_path)
                            dedupe_salvaged = dedupe_salvaged + #clips
                            break
                        end
                    end
                end
                dedupe_stmt:reset()
            end
        end
        dedupe_stmt:finalize()

        local path_change_count = 0
        for _ in pairs(media_path_changes) do path_change_count = path_change_count + 1 end
        local clip_change_count = 0
        for _ in pairs(clip_relink_map) do clip_change_count = clip_change_count + 1 end
        log.event("ShowRelinkDialog: dispatching RelinkClips — %d clip changes, %d media path changes, %d new media, %d salvaged via dedupe",
            clip_change_count, path_change_count, #new_media_records, dedupe_salvaged)

            local command_manager = require("core.command_manager")
            apply_result = command_manager.execute("RelinkClips", {
                clip_relink_map = clip_relink_map,
                media_path_changes = media_path_changes,
                new_media_records = new_media_records,
                project_id = project_id,
            })
        end

        local results = media_relink_dialog.show(media_list, parent_window,
            { on_apply = do_apply })

        if not results then
            log.event("ShowRelinkDialog: user cancelled")
            return { success = true, cancelled = true }
        end

        return apply_result or { success = true }
    end

    return {
        ["ShowRelinkDialog"] = {
            executor = executors["ShowRelinkDialog"],
            spec = SPEC,
        },
    }
end

return M
