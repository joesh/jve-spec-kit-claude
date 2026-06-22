--- DeleteSelection command: unified delete for timeline and browser.
--
-- Priority: (1) browser delete if browser focused, (2) mark-based lift/extract if marks set,
-- (3) ripple delete if shift+clips selected, (4) batch delete selected clips,
-- (5) ripple delete selected gaps.
-- Named param: ripple=true triggers ripple delete / extract.
--
-- Non-undoable wrapper — delegates to LiftRange/ExtractRange/DeleteClip/RippleDeleteSelection/RippleDelete.
--
-- @file delete_selection.lua
local M = {}
local log = require("core.logger").for_area("commands")
local through_edit = require("core.through_edit")

local SPEC = {
    undoable = false,
    args = {
        ripple = { kind = "boolean" },
        project_id = {},
        sequence_id = {},
    }
}

-- Project browser delete: forwarded to the browser module if present.
local function delete_browser_selection()
    local ok, project_browser = pcall(require, "ui.project_browser")
    if ok and project_browser and project_browser.delete_selected_items then
        project_browser.delete_selected_items()
    end
end

-- Mark-based lift/extract: when both marks bracket a range, run
-- LiftRange (delete) or ExtractRange (ripple-delete) on the marked
-- range, then ClearMarks. Asserts on missing sequence/project context.
local function delete_mark_range(timeline_state, command_manager, ripple)
    local mark_in  = timeline_state.get_mark_in  and timeline_state.get_mark_in()
    local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out()
    if not (mark_in and mark_out and mark_out > mark_in) then
        return false
    end
    local sequence_id = timeline_state.get_tab_strip():active_sequence_id()
    assert(sequence_id, "DeleteSelection: missing sequence_id for mark-based delete")
    local project_id = timeline_state.get_project_id
        and timeline_state.get_project_id()
    assert(project_id and project_id ~= "", "DeleteSelection: missing project_id")

    command_manager.begin_undo_group("DeleteMarkRange")
    local cmd_name = ripple and "ExtractRange" or "LiftRange"
    local result = command_manager.execute(cmd_name, {
        project_id = project_id,
        sequence_id = sequence_id,
        mark_in = mark_in,
        mark_out = mark_out,
    })
    assert(result.success, string.format(
        "DeleteSelection: %s failed: %s",
        cmd_name, result.error_message or "unknown"))
    command_manager.execute("ClearMarks",
        { project_id = project_id, sequence_id = sequence_id })
    command_manager.end_undo_group()
    return true
end

-- Extract clip ids from the timeline's selected_clips list (which may
-- contain id strings or objects with an id field).
local function selected_clip_ids(selected_clips)
    local ids = {}
    for _, clip in ipairs(selected_clips or {}) do
        if type(clip) == "table" then
            ids[#ids + 1] = clip.id or clip.clip_id
        elseif type(clip) == "string" then
            ids[#ids + 1] = clip
        end
    end
    return ids
end

local function ripple_delete_selected(timeline_state, command_manager, selected_clips)
    local clip_ids = selected_clip_ids(selected_clips)
    if #clip_ids == 0 then return false end
    local params = { clip_ids = clip_ids }
    params.sequence_id = timeline_state.get_tab_strip():active_sequence_id()
    if timeline_state.get_project_id then
        params.project_id = timeline_state.get_project_id()
    end
    local result = command_manager.execute("RippleDeleteSelection", params)
    if not result.success then
        log.warn("Failed to ripple delete selection: %s",
            tostring(result.error_message or "unknown error"))
    end
    return true
end

-- Group DeleteClip children into a single undo atom. On any failure the
-- whole group rolls back — partial deletes (some clips gone, some still
-- selected) would be confusing and non-atomic.
local function delete_selected_clips(timeline_state, command_manager, selected_clips)
    if not selected_clips or #selected_clips == 0 then return false end
    local active_sequence_id = timeline_state.get_tab_strip():active_sequence_id()
    local project_id = timeline_state.get_project_id
        and timeline_state.get_project_id()
    assert(project_id and project_id ~= "", "DeleteSelection: missing active project_id")

    -- Snapshot ids before the loop — apply_mutations mutates the live list.
    local clip_ids_to_delete = {}
    for _, clip in ipairs(selected_clips) do
        clip_ids_to_delete[#clip_ids_to_delete + 1] = clip.id
    end

    command_manager.begin_undo_group("DeleteSelection")
    local deleted, failure_reason, failed_clip_id = 0, nil, nil
    for _, clip_id in ipairs(clip_ids_to_delete) do
        local result = command_manager.execute("DeleteClip", {
            clip_id = clip_id,
            project_id = project_id,
            sequence_id = active_sequence_id,
        })
        if result.success then
            deleted = deleted + 1
        else
            failure_reason = result.error_message or "unknown"
            failed_clip_id = clip_id
            log.error("DeleteSelection: DeleteClip failed for %s: %s",
                clip_id, failure_reason)
            break
        end
    end
    command_manager.end_undo_group()

    if failure_reason then
        log.warn("DeleteSelection: aborted after %d successful delete(s); "
            .. "selection preserved. Cause: %s (clip=%s)",
            deleted, failure_reason, tostring(failed_clip_id))
        return {
            success = false,
            error_message = string.format(
                "DeleteSelection aborted: %s", failure_reason),
        }
    end
    if deleted > 0 then
        if timeline_state.set_selection then
            timeline_state.set_selection({})
        end
        log.event("Deleted %d clips (single undo)", deleted)
    end
    return true
end

-- Ripple-delete the first selected gap, if any.
local function ripple_delete_selected_gap(timeline_state, command_manager)
    local selected_gaps = timeline_state.get_selected_gaps()
    if not selected_gaps or #selected_gaps == 0 then return false end
    local gap = selected_gaps[1]
    local params = {
        track_id     = gap.track_id,
        gap_start    = gap.start_value,
        gap_duration = gap.duration,
    }
    params.sequence_id = timeline_state.get_tab_strip():active_sequence_id()
    if timeline_state.get_project_id then
        params.project_id = timeline_state.get_project_id()
    end
    local result = command_manager.execute("RippleDelete", params)
    if result.success then
        if timeline_state.clear_gap_selection then
            timeline_state.clear_gap_selection()
        end
        log.event("Ripple deleted gap of %s on track %s",
            tostring(gap.duration), tostring(gap.track_id))
    else
        log.warn("Failed to ripple delete gap: %s",
            tostring(result.error_message or "unknown error"))
    end
    return true
end

-- Select-an-edit-and-Delete = remove a through-edit by joining it (the
-- FCP7/Premiere gesture). A single cut selected as a roll puts exactly two
-- "roll" edges in the edge selection: the left clip's out-edge and the right
-- clip's in-edge. When that cut is a through-edit, Delete joins the pair (one
-- undoable JoinThroughEdit on the left clip). A roll on a GENUINE cut is left
-- to fall through untouched — JoinThroughEdit asserts the pair is a
-- through-edit, so the predicate must gate the dispatch.
local function join_selected_through_edit(timeline_state, command_manager)
    local edges = timeline_state.get_selected_edges and timeline_state.get_selected_edges()
    if not (edges and #edges == 2
        and edges[1].trim_type == "roll" and edges[2].trim_type == "roll") then
        return false
    end

    local left_id, right_id
    for _, e in ipairs(edges) do
        if e.edge_type == "out" then left_id = e.clip_id
        elseif e.edge_type == "in" then right_id = e.clip_id end
    end
    if not (left_id and right_id) then return false end  -- not a single in/out cut

    local strip = timeline_state.get_tab_strip()
    local left_clip, right_clip = strip:clip_by_id(left_id), strip:clip_by_id(right_id)
    if not (left_clip and right_clip) then return false end

    local track = require("ui.timeline.state.track_state").get_by_id(left_clip.track_id)
    local kind = (track and track.track_type == "AUDIO") and "audio" or "video"
    if not through_edit.is_through_edit(left_clip, right_clip, kind) then
        return false  -- a genuine cut: Delete on the roll does nothing here
    end

    local project_id = timeline_state.get_project_id()
    assert(project_id and project_id ~= "",
        "DeleteSelection: missing project_id for through-edit join")
    local result = command_manager.execute("JoinThroughEdit", {
        project_id  = project_id,
        sequence_id = strip:active_sequence_id(),
        clip_id     = left_id,
    })
    assert(result.success, string.format(
        "DeleteSelection: JoinThroughEdit failed: %s", result.error_message or "unknown"))
    return true
end

function M.register(executors, undoers, db)
    local function executor(command)
        local args = command:get_all_parameters()
        local ripple = args.ripple or false

        local focus_manager = require("ui.focus_manager")
        local focused_panel = focus_manager.get_focused_panel
            and focus_manager.get_focused_panel()

        if focused_panel == "project_browser" then
            delete_browser_selection()
            return true
        end
        if focused_panel ~= "timeline" then
            return true  -- not in a deletable context
        end

        local timeline_state   = require('ui.timeline.timeline_state')
        local command_manager  = require("core.command_manager")

        if delete_mark_range(timeline_state, command_manager, ripple) then
            return true
        end

        -- A selected through-edit (roll on an invisible cut) → join it.
        if join_selected_through_edit(timeline_state, command_manager) then
            return true
        end

        local selected_clips = timeline_state.get_selected_clips()
        if ripple and selected_clips and #selected_clips > 0 then
            if ripple_delete_selected(timeline_state, command_manager, selected_clips) then
                return true
            end
        end

        local clip_result = delete_selected_clips(
            timeline_state, command_manager, selected_clips)
        if clip_result then return clip_result end

        ripple_delete_selected_gap(timeline_state, command_manager)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
