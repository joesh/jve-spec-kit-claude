--- OpenClipInSourceMonitor — load a timeline clip into the source viewer
--- in live-bound mode (spec 019 FR-017, FR-024).
---
--- Two dispatch paths converge here:
---   * Timeline double-click (FR-026): the view's hit-test resolves the
---     clip under the cursor and passes `clip_id` explicitly.
---   * `Shift+F` keymap (FR-024): no positional source for clip_id, so the
---     command resolves the clip the user "means" via the same playhead+
---     selection+topmost-autoselect policy `MatchFrame` uses (see
---     `command_helper.resolve_clips_at_playhead` / `pick_best_clip`).
---     This keeps "which clip the user means" as one canonical policy
---     across F (MatchFrame → master) and Shift+F (live-bound clip), so
---     the two commands always agree on which row to act on.
---
--- Gap-as-clip rows are rejected (FR-027): gaps have no underlying media,
--- so loading them into the source viewer is undefined.
---
--- @file open_clip_in_source_monitor.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        -- Optional: when absent, the executor resolves via the canonical
        -- playhead/selection policy (command_helper). The double-click
        -- path passes this explicitly; the keymap path leaves it nil.
        clip_id = { kind = "string" },
    },
}

local function resolve_clip_id_from_playhead()
    local command_helper = require("core.command_helper")
    local target_clips = command_helper.resolve_clips_at_playhead()
    assert(#target_clips > 0,
        "OpenClipInSourceMonitor: no clips under the playhead to load")
    local clip = command_helper.pick_best_clip(target_clips)
    assert(clip and clip.id and clip.id ~= "",
        "OpenClipInSourceMonitor: pick_best_clip returned no clip id")
    assert(not clip.is_gap, string.format(
        "OpenClipInSourceMonitor: clip %s under playhead is a gap-as-clip "
        .. "row — gaps have no source media (FR-027)", tostring(clip.id)))
    return clip.id
end

function M.register(executors, _undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        local clip_id = args.clip_id
        if clip_id == nil or clip_id == "" then
            clip_id = resolve_clip_id_from_playhead()
        end
        require("ui.source_viewer").load_clip(clip_id)
        return { success = true }
    end

    executors["OpenClipInSourceMonitor"] = executor

    return {
        executor = executor,
        spec     = SPEC,
    }
end

return M
