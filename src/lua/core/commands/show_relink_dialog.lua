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

-- ---------------------------------------------------------------------------
-- Apply-state: per-session bookkeeping while building the RelinkClips payload
-- ---------------------------------------------------------------------------
--
-- The dialog returns a list of relinked + failed media. Translating that into
-- a clip-level relink map requires resolving:
--   - path conflicts when two media want the same target file
--   - splits when a candidate covers only some of a media's clips
--   - dedup salvage for failures (sibling row already at the right path)
--
-- All cross-entry state lives in a single state table so each helper takes
-- one bundle instead of half-a-dozen positional args.

--- Build a fresh state bundle for one do_apply invocation.
local function new_apply_state(folder_priority)
    return {
        folder_priority      = folder_priority,
        clip_relink_map      = {},
        media_path_changes   = {},
        new_media_records    = {},   -- split-created clone media descriptors
        clone_path_to_id     = {},   -- new_path → clone media_id (this session)
        path_to_media        = {},   -- new_path → {media_id, priority}
        media_orig_paths     = {},   -- media_id → original file_path
        priority_losers      = {},   -- loser_media_id → winner_media_id
        db_path_cache        = {},   -- path → media_id|false (DB lookup memo)
    }
end

--- Resolve who already owns a target path.
-- Checks (in order): clones created this session, non-split path claims, DB.
-- @return string|nil owner media_id, or nil if unclaimed
local function find_path_owner(state, db, path)
    if state.clone_path_to_id[path] then return state.clone_path_to_id[path] end
    local claim = state.path_to_media[path]
    if claim then return claim.media_id end

    local cached = state.db_path_cache[path]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local stmt = db:prepare("SELECT id FROM media WHERE file_path = ? LIMIT 1")
    if not stmt then state.db_path_cache[path] = false; return nil end
    stmt:bind_value(1, path)
    local found_id = nil
    if stmt:exec() and stmt:next() then
        found_id = stmt:value(0)
    end
    stmt:finalize()
    state.db_path_cache[path] = found_id or false
    return found_id
end

--- Memoize the original file_path for a given media_id.
local function record_orig_path(state, Media, mid)
    if state.media_orig_paths[mid] then return end
    local m = Media.load(mid)
    assert(m, string.format("ShowRelinkDialog: media not found: %s", mid))
    state.media_orig_paths[mid] = m:get_file_path()
end

--- Handle a split entry: some clips fit in the candidate file, others don't.
-- If the target path is already claimed → reassign fitting clips to the
-- existing owner. Otherwise → register a clone (created later by RelinkClips).
local function handle_split_entry(state, db, Media, uuid, entry)
    local mid = entry.media_id
    local original = Media.load(mid)
    assert(original, "ShowRelinkDialog: split source media not found: " .. mid)

    local existing_at_path = find_path_owner(state, db, entry.new_path)
    if existing_at_path then
        for _, clip_id in ipairs(entry.split_clip_ids) do
            state.clip_relink_map[clip_id] = { new_media_id = existing_at_path }
        end
        state.path_to_media[entry.new_path] = state.path_to_media[entry.new_path] or
            { media_id = existing_at_path, priority = 0 }
        log.event("split→existing: media %s → existing %s (%d clips)",
            mid:sub(1, 8), existing_at_path:sub(1, 8), #entry.split_clip_ids)
        return
    end

    local dur = original.duration
    local fps_num = original.frame_rate and original.frame_rate.fps_numerator
    local fps_den = original.frame_rate and original.frame_rate.fps_denominator
    -- Schema enforces duration_frames > 0, fps_num > 0, fps_den > 0 on media.
    -- Nil/zero here means the source media row violates schema invariants and
    -- the split clone would inherit garbage. Surface the bad row instead of
    -- silently abandoning the relink (which would leave split_clip_ids
    -- unreferenced in clip_relink_map — a Half-2 silent failure).
    assert(dur and dur > 0, string.format(
        "ShowRelinkDialog.handle_split_entry: media %s has invalid duration=%s — cannot clone for split",
        mid, tostring(dur)))
    assert(fps_num and fps_num > 0, string.format(
        "ShowRelinkDialog.handle_split_entry: media %s has invalid fps_numerator=%s — cannot clone for split",
        mid, tostring(fps_num)))
    assert(fps_den and fps_den > 0, string.format(
        "ShowRelinkDialog.handle_split_entry: media %s has invalid fps_denominator=%s — cannot clone for split",
        mid, tostring(fps_den)))

    -- The clone is materialized inside RelinkClips Phase 1 so undo can fully
    -- revert. Here we only register intent.
    local clone_id = uuid.generate_with_prefix("media")
    state.clone_path_to_id[entry.new_path] = clone_id
    state.path_to_media[entry.new_path] = { media_id = clone_id, priority = 0 }
    state.new_media_records[#state.new_media_records + 1] = {
        id = clone_id, path = entry.new_path, name = original.name,
        duration_frames = dur,
        fps_num = fps_num, fps_den = fps_den,
        audio_sample_rate = original.audio_sample_rate,
        audio_channels = original.audio_channels,
        width = original.width,
        height = original.height,
        metadata = original.metadata,
    }
    for _, clip_id in ipairs(entry.split_clip_ids) do
        state.clip_relink_map[clip_id] = { new_media_id = clone_id }
    end
    log.event("split: media %s → clone %s (%d clips) at %s",
        mid:sub(1, 8), clone_id:sub(1, 8), #entry.split_clip_ids,
        entry.new_path:match("([^/]+)$") or entry.new_path)
end

--- Handle a non-split entry: pick a winner via folder priority when two
-- media want the same target path. Losers go into priority_losers.
local function handle_normal_entry(state, db, entry)
    local mid = entry.media_id

    local db_owner = find_path_owner(state, db, entry.new_path)
    if db_owner and db_owner ~= mid then
        state.priority_losers[mid] = db_owner
        return
    end

    local my_priority = get_folder_priority(state.media_orig_paths[mid], state.folder_priority)
    local existing = state.path_to_media[entry.new_path]

    if not existing or existing.media_id == mid then
        if not existing then
            state.path_to_media[entry.new_path] = {
                media_id = mid, priority = my_priority
            }
        end
        state.media_path_changes[mid] = entry.new_path
    elseif my_priority < existing.priority then
        log.event("folder priority: %s (pri=%d) beats %s (pri=%d) for %s",
            mid:sub(1, 8), my_priority,
            existing.media_id:sub(1, 8), existing.priority,
            entry.new_path:match("([^/]+)$") or entry.new_path)
        state.media_path_changes[existing.media_id] = nil
        state.priority_losers[existing.media_id] = mid
        state.media_path_changes[mid] = entry.new_path
        state.path_to_media[entry.new_path] = {
            media_id = mid, priority = my_priority
        }
    else
        state.priority_losers[mid] = existing.media_id
    end
end

--- Walk priority_losers: reassign every clip on a loser to the winner.
local function reassign_priority_losers(state, Clip)
    for loser_mid, winner_mid in pairs(state.priority_losers) do
        local clips = Clip.find_clips_for_media(loser_mid)
        for _, clip in ipairs(clips) do
            state.clip_relink_map[clip.id] = { new_media_id = winner_mid }
        end
        log.event("priority reassign: %d clips from media %s → winner %s",
            #clips, loser_mid:sub(1, 8), winner_mid:sub(1, 8))
    end
end

--- Salvage failed entries via sibling-row dedup.
-- Two media rows can share the same name (one from the project DB, one from
-- a prior import). The relinker rejected this media's candidates, but a
-- sibling row's existing file_path may still be on disk. If so, reassign
-- this media's clips to the sibling row — no new path write needed.
-- @return integer count of clips salvaged
local function salvage_via_dedupe(state, db, Clip, project_id, failed_entries)
    local dedupe_stmt = db:prepare([[
        SELECT id, file_path FROM media
        WHERE project_id = ?
          AND name = (SELECT name FROM media WHERE id = ?)
          AND id != ?
    ]])
    local salvaged = 0
    for _, entry in ipairs(failed_entries or {}) do
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
                        local clips = Clip.find_clips_for_media(mid)
                        for _, clip in ipairs(clips) do
                            if not state.clip_relink_map[clip.id] then
                                state.clip_relink_map[clip.id] = { new_media_id = sibling_id }
                            end
                        end
                        log.event("dedupe: media %s → sibling %s (%d clips, %s)",
                            mid:sub(1, 8), sibling_id:sub(1, 8), #clips,
                            sibling_path:match("([^/]+)$") or sibling_path)
                        salvaged = salvaged + #clips
                        break
                    end
                end
            end
            dedupe_stmt:reset()
        end
    end
    dedupe_stmt:finalize()
    return salvaged
end

--- Count keys in a hash table (where #t is meaningless).
local function count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Half-2 invariant: every input entry must be accounted for in the output.
-- Verifies each results.relinked entry's media_id appears as either a
-- winner (media_path_changes), a loser (priority_losers), or a split source
-- (registered clone in clone_path_to_id whose split_clip_ids were assigned).
-- Bypasses silent drops if any handler regression sneaks in.
local function assert_all_entries_accounted(state, relinked_entries)
    -- Build the set of split-source media_ids whose clips made it into
    -- clip_relink_map (split→existing path doesn't create a clone, so we can't
    -- check clone_path_to_id alone).
    local split_clips_assigned = {}
    for _, entry in ipairs(relinked_entries) do
        if entry.needs_split and entry.split_clip_ids and #entry.split_clip_ids > 0 then
            -- Verify at least one of the split_clip_ids landed in the map
            for _, clip_id in ipairs(entry.split_clip_ids) do
                if state.clip_relink_map[clip_id] then
                    split_clips_assigned[entry.media_id] = true
                    break
                end
            end
        end
    end

    for _, entry in ipairs(relinked_entries) do
        local mid = entry.media_id
        local accounted = state.media_path_changes[mid] ~= nil
            or state.priority_losers[mid] ~= nil
            or split_clips_assigned[mid] == true
        assert(accounted, string.format(
            "do_apply: relinked entry for media %s produced no state change "
            .. "(needs_split=%s, split_clip_ids=%s) — silent pipeline drop",
            tostring(mid), tostring(entry.needs_split),
            entry.split_clip_ids and tostring(#entry.split_clip_ids) or "nil"))
    end
end

--- Dispatch the assembled state as a RelinkClips command.
local function dispatch_relink(state, project_id, salvaged)
    log.event("ShowRelinkDialog: dispatching RelinkClips — %d clip changes, %d media path changes, %d new media, %d salvaged via dedupe",
        count_keys(state.clip_relink_map),
        count_keys(state.media_path_changes),
        #state.new_media_records, salvaged)

    local command_manager = require("core.command_manager")
    return command_manager.execute("RelinkClips", {
        clip_relink_map    = state.clip_relink_map,
        media_path_changes = state.media_path_changes,
        new_media_records  = state.new_media_records,
        project_id         = project_id,
    })
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
            assert(results.folder_priority, "ShowRelinkDialog: results missing folder_priority")
            local Media = require("models.media")
            local Clip = require("models.clip")
            local uuid = require("uuid")

            local state = new_apply_state(results.folder_priority)

            -- Translate per-media relink results into per-clip assignments.
            -- Each entry is either a split (partial fit needing a clone or
            -- reassignment) or a normal entry (target path may conflict via
            -- folder priority).
            for _, entry in ipairs(results.relinked) do
                record_orig_path(state, Media, entry.media_id)
                if entry.needs_split and entry.split_clip_ids then
                    handle_split_entry(state, db, Media, uuid, entry)
                else
                    handle_normal_entry(state, db, entry)
                end
            end

            reassign_priority_losers(state, Clip)

            -- Half-2 (NSF): verify every input entry is reflected in the
            -- output state before dispatching. Catches silent drops.
            assert_all_entries_accounted(state, results.relinked)

            local salvaged = salvage_via_dedupe(state, db, Clip, project_id, results.failed)

            apply_result = dispatch_relink(state, project_id, salvaged)
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
