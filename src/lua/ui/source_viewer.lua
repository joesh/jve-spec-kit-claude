--- Source Viewer: public API for loading master clips into the source monitor.
--
-- Decouples "load a master clip for viewing" from the project browser.
-- Both the browser (double-click) and commands (MatchFrame) use this
-- instead of reaching into panel_manager directly.
--
-- @file source_viewer.lua
local M = {}

local Signals = require("core.signals")
local selection_hub = require("ui.selection_hub")

-- panel_id under which the loaded sequence is published to selection_hub
-- so the Inspector (and any other panel-keyed listener) can pick up the
-- focused source monitor's target. Matches the view_id the source
-- SequenceMonitor registers with panel_manager / focus_manager.
local SOURCE_PANEL_ID = "source_monitor"

local function get_source_monitor()
    local pm = require("ui.panel_manager")
    local source = pm.get_sequence_monitor("source_monitor")
    assert(source, "source_viewer: source_monitor not registered in panel_manager")
    return source
end

-- Publish the loaded sequence as a single-item selection under
-- SOURCE_PANEL_ID. item_type "timeline" routes to the Inspector's
-- sequence schema (see selection_binding.lua:157,168), which works
-- uniformly for both kinds of sequence the source monitor can hold
-- (media-kind wrapping one file, or compositional clip-kind).
local function publish_loaded_sequence(monitor, sequence_id)
    local seq = monitor.sequence
    assert(seq, string.format(
        "source_viewer.publish_loaded_sequence: monitor.sequence must be "
        .. "set after load_sequence(%s)", tostring(sequence_id)))
    local project_id = seq.project_id
    assert(project_id and project_id ~= "", string.format(
        "source_viewer.publish_loaded_sequence: loaded sequence %s has "
        .. "no project_id", tostring(sequence_id)))
    selection_hub.update_selection(SOURCE_PANEL_ID, {
        {
            item_type   = "timeline",
            id          = sequence_id,
            sequence_id = sequence_id,
            project_id  = project_id,
            sequence    = seq,
        },
    })
end

--- Load a master sequence into the source monitor.
-- Emits source_loaded_changed(new_master_seq_id, previous_master_seq_id).
-- @param master_seq_id string  The master sequence id
-- @param opts table|nil  Options:
--   skip_focus (bool): if true, don't focus the source_monitor panel
function M.load_master_clip(master_seq_id, opts)
    assert(master_seq_id and master_seq_id ~= "",
        "source_viewer.load_master_clip: master_seq_id required")
    opts = opts or {}

    local source = get_source_monitor()
    local prev_seq_id = source:get_loaded_master_seq_id()

    source:load_sequence(master_seq_id)

    -- 017: bind the source-role engine to this master. Transport target
    -- routing is DERIVED from UI state (focus + displayed tab), not set
    -- here — when this call path completes, focus_manager.focus_panel
    -- below moves focus to source_monitor and transport.get_target()
    -- automatically resolves to "source".
    -- bind_role_to_sequence is idempotent and a pre-bootstrap no-op for
    -- headless tests. load asserts on qt_constants — tests exercising
    -- this path bootstrap the stub via helpers.test_017_setup.
    require("core.playback.transport").bind_role_to_sequence("source", master_seq_id)

    publish_loaded_sequence(source, master_seq_id)

    Signals.emit("source_loaded_changed", master_seq_id, prev_seq_id)

    if not opts.skip_focus then
        local focus_manager = require("ui.focus_manager")
        focus_manager.focus_panel("source_monitor")
    end

    return true
end

--- Unload the source monitor, clearing the loaded master clip.
-- Emits source_loaded_changed(nil, previous_master_seq_id).
-- No-op (no signal) when nothing is currently loaded.
function M.unload()
    local source = get_source_monitor()
    local prev_seq_id = source:get_loaded_master_seq_id()
    if not prev_seq_id then return end

    source:unload()
    selection_hub.clear_selection(SOURCE_PANEL_ID)
    Signals.emit("source_loaded_changed", nil, prev_seq_id)
end

return M
