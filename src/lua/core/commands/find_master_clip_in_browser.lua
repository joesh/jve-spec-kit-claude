--- Find Master Clip in Browser: reveal and select the master sequence
-- in the project browser.
--
-- From timeline: resolves the clip under the playhead (same logic as
--   MatchFrame), gets its nested_sequence_id (V13 master ref), and
--   selects it in the browser.
-- From source viewer: uses the currently-loaded master sequence.
--
-- Always focuses the project browser panel.
--
-- @file find_master_clip_in_browser.lua
local M = {}
local log = require("core.logger").for_area("commands")
local command_helper = require("core.command_helper")

local SPEC = {
    undoable = false,
    no_persist = true,
    args = {
        project_id = { required = true },
        sequence_id = {},
    }
}

--- From timeline: find clip under playhead, return its nested_sequence_id.
local function resolve_from_timeline()
    local target_clips = command_helper.resolve_clips_at_playhead()
    if #target_clips == 0 then return nil, "No clips under playhead" end

    local best = command_helper.pick_best_clip(target_clips)
    if not best or not best.nested_sequence_id or best.nested_sequence_id == "" then
        return nil, "Clip has no nested sequence"
    end
    return best.nested_sequence_id
end

--- From source viewer: get the currently-loaded master clip sequence ID.
local function resolve_from_source_viewer()
    local pm = require("ui.panel_manager")
    local source = pm.get_sequence_monitor("source_monitor")
    if not source or not source.sequence_id then
        return nil, "No clip loaded in source viewer"
    end
    local Sequence = require("models.sequence")
    local seq = Sequence.load(source.sequence_id)
    if not seq then
        return nil, "Source viewer sequence not found"
    end
    if not seq:is_master() then
        return nil, "Source viewer is not showing a master clip"
    end
    return source.sequence_id
end

function M.register(command_executors, _command_undoers, _db, set_last_error)
    command_executors["FindMasterClipInBrowser"] = function(command)
        local focus_manager = require("ui.focus_manager")
        local project_browser = require("ui.project_browser")

        local panel = focus_manager.get_focused_panel()
        local master_seq_id, err

        if panel == "source_monitor" then
            master_seq_id, err = resolve_from_source_viewer()
        else
            -- Default: timeline (also handles timeline_monitor)
            master_seq_id, err = resolve_from_timeline()
        end

        if not master_seq_id then
            set_last_error("FindMasterClipInBrowser: " .. (err or "unknown error"))
            return false
        end

        local ok, focus_err = pcall(project_browser.focus_master_clip, master_seq_id, {
            skip_activate = true,  -- don't load into source viewer
        })
        if not ok then
            set_last_error("FindMasterClipInBrowser: " .. tostring(focus_err))
            return false
        end

        log.event("FindMasterClipInBrowser: revealed %s (from %s)",
            master_seq_id:sub(1, 8), panel or "timeline")
        return true
    end

    return {
        executor = command_executors["FindMasterClipInBrowser"],
        spec = SPEC,
    }
end

return M
