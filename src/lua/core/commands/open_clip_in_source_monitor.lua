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

-- Read the rec-tab playhead. The record tab's playhead lives on the
-- record engine's currently-loaded sequence; its `playhead_position`
-- column is the model-side source of truth.
local function read_record_tab_playhead()
    local transport = require("core.playback.transport")
    assert(transport.is_bootstrapped(),
        "OpenClipInSourceMonitor: transport not bootstrapped — "
        .. "Shift+F dispatch requires an open project")
    local rec_engine = transport.record_engine
    assert(rec_engine, "OpenClipInSourceMonitor: record_engine is nil")
    local rec_seq_id = rec_engine.loaded_sequence_id
    assert(type(rec_seq_id) == "string" and rec_seq_id ~= "", string.format(
        "OpenClipInSourceMonitor: record_engine has no loaded sequence "
        .. "(loaded_sequence_id=%s) — Shift+F requires a record tab",
        tostring(rec_seq_id)))
    local rec_seq = require("models.sequence").load(rec_seq_id)
    assert(rec_seq, string.format(
        "OpenClipInSourceMonitor: record sequence %s not found",
        tostring(rec_seq_id)))
    assert(type(rec_seq.playhead_position) == "number", string.format(
        "OpenClipInSourceMonitor: record sequence %s missing playhead_position",
        tostring(rec_seq_id)))
    return rec_seq.playhead_position
end

function M.register(executors, _undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        local clip_id = args.clip_id
        if clip_id == nil or clip_id == "" then
            clip_id = resolve_clip_id_from_playhead()
        end
        local Clip = require("models.clip")
        local clip = Clip.load(clip_id)
        assert(clip, string.format(
            "OpenClipInSourceMonitor: clip not found: %s", tostring(clip_id)))
        local source_frame = Clip.owner_frame_to_source(clip, read_record_tab_playhead())
        -- skip_focus=true: the src tab + viewer are the read-out surface
        -- for the loaded clip; the Timeline panel stays the user's input
        -- surface (FR-024 v2 — focus stays on Timeline so the user can
        -- continue navigating / setting marks via keyboard without an
        -- intervening panel switch).
        require("ui.source_viewer").load_clip(clip_id, {
            playhead_frame = source_frame,
            skip_focus     = true,
        })
        return { success = true }
    end

    executors["OpenClipInSourceMonitor"] = executor

    return {
        executor = executor,
        spec     = SPEC,
    }
end

return M
