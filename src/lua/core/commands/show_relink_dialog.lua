--- ShowRelinkDialog command: relink master clips to new media locations
--
-- Responsibilities:
-- - If clips selected: relink their master clips (deduplicated)
-- - If no selection: relink all master clips in the project
-- - Show reconnect dialog with clip list, matching rules, search directory
-- - On user confirm: hand off the relink results to core.relink_planner,
--   then dispatch RelinkClips with the returned plan
--
-- @file show_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

local SPEC = {
    args = {},
    undoable = false,
}

--- Count keys in a hash table (where #t is meaningless).
local function count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
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
            -- V13: every clip references a sequence; gaps are in-memory only,
            -- never reach selection. No filter needed.
            selected_ids[#selected_ids + 1] = clip.id
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
            -- Dialog contract: { relink = <media_relinker return>, folder_priority = ... }
            assert(type(results.relink) == "table",
                "ShowRelinkDialog: results.relink must be media_relinker return struct")
            assert(type(results.relink.relinked) == "table",
                "ShowRelinkDialog: results.relink.relinked must be array")
            assert(type(results.relink.failed) == "table",
                "ShowRelinkDialog: results.relink.failed must be array")
            assert(type(results.folder_priority) == "table",
                "ShowRelinkDialog: results.folder_priority must be array")

            local t_plan = qt_monotonic_s()
            local relink_planner = require("core.relink_planner")
            local plan = relink_planner.build_plan(
                db, results.relink.relinked, results.relink.failed,
                results.folder_priority, project_id)
            local plan_seconds = qt_monotonic_s() - t_plan

            log.event("ShowRelinkDialog: plan built in %.2fs — %d clip changes, %d media path changes, %d new media, %d salvaged via dedupe",
                plan_seconds,
                count_keys(plan.clip_relink_map),
                count_keys(plan.media_path_changes),
                #plan.new_media_records, plan.salvaged_count)

            local t_execute = qt_monotonic_s()
            local command_manager = require("core.command_manager")
            apply_result = command_manager.execute("RelinkClips", {
                clip_relink_map       = plan.clip_relink_map,
                media_path_changes    = plan.media_path_changes,
                media_tc_updates      = plan.media_tc_updates,
                media_duration_updates = plan.media_duration_updates,
                new_media_records     = plan.new_media_records,
                media_offline_notes   = plan.media_offline_notes,
                project_id            = project_id,
            })
            log.event("ShowRelinkDialog: RelinkClips executed in %.2fs",
                qt_monotonic_s() - t_execute)
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
