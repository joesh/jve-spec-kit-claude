--- ShowRelinkDialog command: find offline media and show reconnect dialog
--
-- Responsibilities:
-- - Scan project media for offline files via media_relinker.find_offline_media
-- - Show reconnect dialog with clip list, matching rules, search directory
-- - Disambiguate when multiple media records resolve to same candidate
-- - On user confirm, dispatch RelinkClips with clip_relink_map + media changes
--
-- Non-goals:
-- - Undo support (dialog-only command, actual relink is undoable via RelinkClips)
--
-- Invariants:
-- - Requires an open project with media
-- - Asserts if no project is open
--
-- @file show_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

local SPEC = {
    args = {},
    undoable = false,
}

--- Show disambiguation dialog for path collisions.
-- When multiple original media records match the same candidate file,
-- let user pick which one gets relinked. Others stay offline.
-- @param collisions table {new_path → {media_id1, media_id2, ...}}
-- @param media_orig_paths table {media_id → original_path}
-- @param parent_window widget|nil
-- @return table {new_path → chosen_media_id} or nil if cancelled
local function show_disambiguation_dialog(collisions, media_orig_paths, parent_window)
    local qt = require("core.qt_constants")

    local collision_list = {}
    for new_path, media_ids in pairs(collisions) do
        collision_list[#collision_list + 1] = {new_path = new_path, media_ids = media_ids}
    end

    local choices = {}  -- new_path → chosen media_id

    for _, collision in ipairs(collision_list) do
        local new_path = collision.new_path
        local media_ids = collision.media_ids
        local filename = new_path:match("([^/\\]+)$") or new_path

        -- Build message listing the original paths
        local lines = {}
        lines[#lines + 1] = string.format("Multiple media records match:\n%s\n", filename)
        lines[#lines + 1] = "Which original should be relinked to this file?\n"
        for i, mid in ipairs(media_ids) do
            lines[#lines + 1] = string.format("  %d.  %s", i, media_orig_paths[mid] or mid)
        end
        lines[#lines + 1] = "\nUnchosen media will remain offline."

        -- Create dialog with radio-button-like selection via combobox
        local dialog = qt.DIALOG.CREATE("Duplicate Media", 600, 300, parent_window)
        local layout = qt.LAYOUT.CREATE_VBOX()

        local msg = qt.WIDGET.CREATE_TEXT_EDIT(table.concat(lines, "\n"))
        qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(msg, true)
        qt.PROPERTIES.SET_SIZE(msg, 560, 180)
        qt.LAYOUT.ADD_WIDGET(layout, msg)
        qt.LAYOUT.ADD_SPACING(layout, 8)

        -- Combobox with original paths
        local combo_row = qt.LAYOUT.CREATE_HBOX()
        qt.LAYOUT.ADD_WIDGET(combo_row, qt.WIDGET.CREATE_LABEL("Use:"))
        local combo = qt.WIDGET.CREATE_COMBOBOX()
        for _, mid in ipairs(media_ids) do
            qt.PROPERTIES.ADD_COMBOBOX_ITEM(combo, media_orig_paths[mid] or mid)
        end
        qt.LAYOUT.ADD_WIDGET(combo_row, combo)
        qt.LAYOUT.ADD_LAYOUT(layout, combo_row)

        qt.LAYOUT.ADD_STRETCH(layout)

        -- Buttons
        local btn_row = qt.LAYOUT.CREATE_HBOX()
        qt.LAYOUT.ADD_STRETCH(btn_row)
        local ok_btn = qt.WIDGET.CREATE_BUTTON("OK")
        local skip_btn = qt.WIDGET.CREATE_BUTTON("Skip All Duplicates")

        local result_choice = nil
        local skip_all = false

        local ok_name = "__disambig_ok"
        _G[ok_name] = function()
            local idx = qt.PROPERTIES.GET_COMBOBOX_CURRENT_INDEX(combo)
            result_choice = media_ids[(idx or 0) + 1] or media_ids[1]
            qt.DIALOG.CLOSE(dialog, true)
        end
        qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ok_btn, ok_name)

        local skip_name = "__disambig_skip"
        _G[skip_name] = function()
            skip_all = true
            qt.DIALOG.CLOSE(dialog, false)
        end
        qt.CONTROL.SET_BUTTON_CLICK_HANDLER(skip_btn, skip_name)

        qt.LAYOUT.ADD_WIDGET(btn_row, ok_btn)
        qt.LAYOUT.ADD_SPACING(btn_row, 8)
        qt.LAYOUT.ADD_WIDGET(btn_row, skip_btn)
        qt.LAYOUT.ADD_LAYOUT(layout, btn_row)

        qt.DIALOG.SET_LAYOUT(dialog, layout)
        qt.DIALOG.SHOW(dialog)

        _G[ok_name] = nil
        _G[skip_name] = nil

        if skip_all then
            -- User wants to skip all duplicates — first media_id wins for all
            for _, c in ipairs(collision_list) do
                if not choices[c.new_path] then
                    choices[c.new_path] = c.media_ids[1]
                end
            end
            break
        elseif result_choice then
            choices[new_path] = result_choice
        else
            -- Dialog closed/cancelled — first wins
            choices[new_path] = media_ids[1]
        end
    end

    return choices
end

function M.register(executors, _undoers, db)

    executors["ShowRelinkDialog"] = function(_command)
        local media_relinker = require("core.media_relinker")
        local timeline_state = require("ui.timeline.timeline_state")

        local project_id = timeline_state.get_project_id()
        assert(project_id, "ShowRelinkDialog: no project open")

        local offline = media_relinker.find_offline_media(db, project_id)

        if #offline == 0 then
            log.event("ShowRelinkDialog: no offline media found")
            return { success = true, message = "All media is online" }
        end

        log.event("ShowRelinkDialog: found %d offline media file(s)", #offline)

        -- Get parent window for dialog
        local parent_window = nil
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if ui_state_ok and ui_state.get_main_window then
            parent_window = ui_state.get_main_window()
        end

        -- Show reconnect dialog (blocking modal, clip-level)
        local media_relink_dialog = require("ui.media_relink_dialog")
        local results = media_relink_dialog.show(offline, parent_window, project_id)

        if not results then
            log.event("ShowRelinkDialog: user cancelled")
            return { success = true, cancelled = true }
        end

        -- Phase 1: Detect path collisions
        -- Group relinked entries by new_path to find duplicates
        local Media = require("models.media")
        local path_to_media_ids = {}  -- new_path → {media_id, ...} (unique)
        local media_orig_paths = {}   -- media_id → original file_path

        for _, entry in ipairs(results.relinked) do
            local mid = entry.original_media_id
            if entry.new_path and not entry.new_media_id and mid then
                if not media_orig_paths[mid] then
                    local m = Media.load(mid)
                    media_orig_paths[mid] = m and m:get_file_path() or "?"
                end

                local group = path_to_media_ids[entry.new_path]
                if not group then
                    group = {}
                    path_to_media_ids[entry.new_path] = group
                end
                -- Add media_id if not already in group
                local found = false
                for _, existing in ipairs(group) do
                    if existing == mid then found = true; break end
                end
                if not found then
                    group[#group + 1] = mid
                end
            end
        end

        -- Separate collisions (>1 media_id per path)
        local collisions = {}
        local collision_count = 0
        for new_path, media_ids in pairs(path_to_media_ids) do
            if #media_ids > 1 then
                collisions[new_path] = media_ids
                collision_count = collision_count + 1
            end
        end

        -- Phase 2: Disambiguate collisions
        local path_winners = {}  -- new_path → chosen media_id
        if collision_count > 0 then
            log.event("ShowRelinkDialog: %d path collision(s) to resolve", collision_count)
            path_winners = show_disambiguation_dialog(collisions, media_orig_paths, parent_window)
        end

        -- Phase 3: Build command args with disambiguation applied
        local clip_relink_map = {}
        local media_path_changes = {}
        local path_owner = {}  -- new_path → media_id that owns it

        for _, entry in ipairs(results.relinked) do
            local mid = entry.original_media_id

            if entry.new_path and not entry.new_media_id and mid then
                local winner = path_winners[entry.new_path]
                local owner = path_owner[entry.new_path]

                if not owner then
                    -- First claim — check if this media_id is the winner (or no collision)
                    if not winner or winner == mid then
                        path_owner[entry.new_path] = mid
                        media_path_changes[mid] = entry.new_path
                    else
                        log.detail("skip: media %s (%s) lost disambiguation for %s",
                            mid:sub(1, 8), media_orig_paths[mid] or "?",
                            entry.new_path:match("([^/]+)$") or entry.new_path)
                        goto continue
                    end
                elseif owner ~= mid then
                    -- Different media_id — skip, leave offline
                    log.detail("skip: media %s (%s) lost disambiguation for %s",
                        mid:sub(1, 8), media_orig_paths[mid] or "?",
                        entry.new_path:match("([^/]+)$") or entry.new_path)
                    goto continue
                end
                -- owner == mid: same media_id already claimed, just add clip
            end

            clip_relink_map[entry.clip_id] = {
                new_media_id = entry.new_media_id,
                new_source_in = entry.new_source_in,
                new_source_out = entry.new_source_out,
            }

            ::continue::
        end

        -- Count for logging
        local path_change_count = 0
        for _ in pairs(media_path_changes) do path_change_count = path_change_count + 1 end
        local clip_change_count = 0
        for _ in pairs(clip_relink_map) do clip_change_count = clip_change_count + 1 end
        log.event("ShowRelinkDialog: dispatching RelinkClips — %d clip changes, %d media path changes, %d new media",
            clip_change_count, path_change_count, #(results.new_media or {}))

        -- Dispatch RelinkClips (undoable)
        local command_manager = require("core.command_manager")
        local result = command_manager.execute("RelinkClips", {
            clip_relink_map = clip_relink_map,
            media_path_changes = media_path_changes,
            new_media_records = results.new_media or {},
            project_id = project_id,
        })

        return result
    end

    return {
        ["ShowRelinkDialog"] = {
            executor = executors["ShowRelinkDialog"],
            spec = SPEC,
        },
    }
end

return M
