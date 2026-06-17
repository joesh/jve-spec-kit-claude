--- RenameTrack command (023 Feature B) — interactive starter.
---
--- Opens the inline rename editor on a track header. This is the UI entry
--- point bound to double-click (carries the clicked track_id) and F2 (no
--- track_id → the focused track). Committing the editor dispatches the
--- undoable SetTrackName command. Non-undoable: opening an editor mutates
--- nothing.
---
--- @file rename_track.lua

local M = {}

--- Resolve which track the rename editor should open on. Pure (no global
--- state) so the precedence is black-box testable:
---   1. explicit arg_track_id      — double-click carries the clicked track.
---   2. focused_track_id           — header the user last clicked.
---   3. the selection's track      — F2 after selecting a clip, when every
---                                   selected clip lives on ONE track.
--- Returns nil when nothing anchors it (no focus, no/ambiguous selection).
function M.resolve_target(arg_track_id, focused_track_id, selected_clips)
    if arg_track_id and arg_track_id ~= "" then return arg_track_id end
    if focused_track_id and focused_track_id ~= "" then return focused_track_id end

    local track_id = nil
    for _, clip in ipairs(selected_clips or {}) do
        if track_id == nil then
            track_id = clip.track_id
        elseif clip.track_id ~= track_id then
            return nil  -- selection spans multiple tracks — ambiguous.
        end
    end
    return track_id
end

function M.register()
    return {
        executor = function(command)
            local timeline_state = require("ui.timeline.timeline_state")
            local track_id = M.resolve_target(
                command:get_parameter("track_id"),
                timeline_state.get_focused_track_id(),
                timeline_state.get_selected_clips())
            assert(track_id and track_id ~= "",
                "RenameTrack: no track to rename — click a track header, "
                .. "select a clip, or double-click a track name")
            local timeline_panel = require("ui.timeline.timeline_panel")
            assert(timeline_panel.start_track_rename,
                "RenameTrack: timeline_panel.start_track_rename missing")
            timeline_panel.start_track_rename(track_id)
            return true
        end,
        spec = {
            keyboard = {
                category     = "Timeline ▸ Track Header",
                display_name = "Rename Track",
                description  = "Open the inline editor to rename the focused "
                    .. "track (or double-click a track name).",
            },
            undoable = false,
            mutates_clips = false,
            args = { track_id = {} },
        },
    }
end

return M
