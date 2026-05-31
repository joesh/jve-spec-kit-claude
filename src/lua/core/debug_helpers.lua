--- State-query helpers for smoke tests + the debug terminal.
--
-- A flat namespace of stable, named, READ-ONLY queries. Smokes call
-- these via `self.eval_str("return require('core.debug_helpers').X()")`
-- instead of hand-writing `require(...)` chains in every test body.
--
-- Contract:
--   * Every function is a state query. None mutate, none fire signals,
--     none execute commands.
--   * Each returns a primitive (string/int/bool) or a small flat table,
--     never deep nested structures (debug-terminal repr cap is depth 3).
--   * No caching. Each call re-reads the underlying state.
--
-- Smoke tests use this for assertions. Real actions still go through
-- real OS input (osascript keystroke, click) per
-- feedback_drive_jve_via_ui_only — debug_helpers never substitutes for
-- a user action.
--
-- Adding helpers: grep callers when an underlying name changes; the
-- whole point of this module is to be the single seam between smoke
-- tests and JVE's internal getter names.
--
-- @file debug_helpers.lua

local M = {}

-- ─── Project / sequence identity ────────────────────────────────────

--- @return string|nil currently-active project id (or nil if no project loaded)
function M.active_project_id()
    local ok, command_manager = pcall(require, "core.command_manager")
    if not ok then return nil end
    return command_manager.get_active_project_id()
end

--- @return string|nil currently-active sequence id (the edit target — feature 015)
function M.active_sequence_id()
    local ok, command_manager = pcall(require, "core.command_manager")
    if not ok then return nil end
    return command_manager.get_active_sequence_id()
end

--- @return string|nil currently-displayed sequence id (which sequence is rendered;
--- can differ from active when a source tab is displayed per spec 015)
function M.displayed_sequence_id()
    local ok, strip_holder = pcall(require, "ui.timeline.state.strip_holder")
    if not ok then return nil end
    return strip_holder.displayed_sequence_id()
end

--- @return string|nil 'record' / 'source' / nil — which tab kind is currently displayed
function M.displayed_tab_kind()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    if not ok then return nil end
    if type(ts.get_displayed_tab_kind) ~= "function" then return nil end
    return ts.get_displayed_tab_kind()
end

-- ─── Counts (for fast smoke assertions) ─────────────────────────────
--
-- All counts route through the appropriate model — only models/ may
-- execute SQL per JVE's SQL-isolation policy. debug_helpers is a thin
-- forwarder, not its own SQL caller.

--- @return integer number of sequences in the database
function M.sequence_count()
    local ok, Sequence = pcall(require, "models.sequence")
    if not ok then return 0 end
    return Sequence.count() or 0
end

--- @param sequence_id string
--- @return integer total clip count on the given sequence
function M.clip_count_on_sequence(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.clip_count_on_sequence: sequence_id required")
    local ok, Clip = pcall(require, "models.clip")
    if not ok then return 0 end
    local clips = Clip.list_in_sequence(sequence_id)
    if type(clips) ~= "table" then return 0 end
    return #clips
end

--- @return integer total media rows in the database
function M.media_count()
    local ok, Media = pcall(require, "models.media")
    if not ok then return 0 end
    return Media.count() or 0
end

--- @param sequence_id string
--- @return integer clip count on the given sequence (raw DB count)
function M.sequence_clip_count(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.sequence_clip_count: sequence_id required")
    local ok, Sequence = pcall(require, "models.sequence")
    if not ok then return 0 end
    return Sequence.count_clips(sequence_id) or 0
end

-- ─── Marks / selection ──────────────────────────────────────────────

--- @return integer|nil mark-in frame on the displayed sequence, or nil if unset
function M.mark_in()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    if not ok then return nil end
    if type(ts.get_display_mark_in) == "function" then
        return ts.get_display_mark_in()
    end
    if type(ts.get_mark_in) == "function" then
        return ts.get_mark_in()
    end
    return nil
end

--- @return integer|nil mark-out frame on the displayed sequence, or nil if unset
function M.mark_out()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    if not ok then return nil end
    if type(ts.get_display_mark_out) == "function" then
        return ts.get_display_mark_out()
    end
    if type(ts.get_mark_out) == "function" then
        return ts.get_mark_out()
    end
    return nil
end

--- @return integer count of currently selected clips on the displayed sequence
function M.selection_count()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    if not ok then return 0 end
    if type(ts.get_selected_clip_ids) ~= "function" then return 0 end
    local ids = ts.get_selected_clip_ids()
    if type(ids) ~= "table" then return 0 end
    return #ids
end

-- ─── Focus / UI state ───────────────────────────────────────────────

--- @return string|nil id of the panel currently holding keyboard focus
function M.focused_panel()
    local ok, fm = pcall(require, "ui.focus_manager")
    if not ok then return nil end
    if type(fm.get_focused_panel) ~= "function" then return nil end
    return fm.get_focused_panel()
end

-- ─── Clip state (for undo/redo assertions) ──────────────────────────

--- @param clip_id string
--- @return boolean clip.enabled — true if enabled, false if muted
function M.clip_enabled(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_enabled: clip_id required")
    local ok, Clip = pcall(require, "models.clip")
    assert(ok, "debug_helpers.clip_enabled: models.clip not loadable")
    local clip = Clip.load(clip_id)
    assert(clip, "debug_helpers.clip_enabled: clip not found: " .. clip_id)
    return clip.enabled and true or false
end

--- @param clip_id string
--- @param field string  — one of: source_in source_out sequence_start duration enabled track_id name
--- @return any field value (raw from Clip:load)
function M.clip_field(clip_id, field)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_field: clip_id required")
    assert(type(field) == "string" and field ~= "",
        "debug_helpers.clip_field: field required")
    local ok, Clip = pcall(require, "models.clip")
    assert(ok, "debug_helpers.clip_field: models.clip not loadable")
    local clip = Clip.load(clip_id)
    assert(clip, "debug_helpers.clip_field: clip not found: " .. clip_id)
    return clip[field]
end

--- @param clip_id string
--- @return boolean true if Clip.load_optional returns a row
function M.clip_exists(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_exists: clip_id required")
    local ok, Clip = pcall(require, "models.clip")
    if not ok then return false end
    if type(Clip.load_optional) == "function" then
        return Clip.load_optional(clip_id) ~= nil
    end
    local ok2, clip = pcall(Clip.load, clip_id)
    return ok2 and clip ~= nil
end

-- ─── Playhead / viewport ────────────────────────────────────────────

--- @return integer|nil playhead frame on the displayed sequence (or nil if no displayed seq)
function M.playhead()
    local sid = M.displayed_sequence_id()
    if not sid then return nil end
    local ok, Sequence = pcall(require, "models.sequence")
    if not ok then return nil end
    local s = Sequence.load(sid)
    if not s then return nil end
    return s.playhead_position
end

--- @param sequence_id string
--- @return integer|nil playhead frame on a specific sequence
function M.playhead_of(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.playhead_of: sequence_id required")
    local ok, Sequence = pcall(require, "models.sequence")
    if not ok then return nil end
    local s = Sequence.load(sequence_id)
    if not s then return nil end
    return s.playhead_position
end

--- @param sequence_id string
--- @return integer|nil start_timecode_frame
function M.sequence_start_tc(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.sequence_start_tc: sequence_id required")
    local ok, Sequence = pcall(require, "models.sequence")
    if not ok then return nil end
    local s = Sequence.load(sequence_id)
    if not s then return nil end
    return s.start_timecode_frame
end

--- @param sequence_id string
--- @param field string  — mark_in mark_out playhead_position start_timecode_frame frame_rate
--- @return any field value
function M.sequence_field(sequence_id, field)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.sequence_field: sequence_id required")
    assert(type(field) == "string" and field ~= "",
        "debug_helpers.sequence_field: field required")
    local ok, Sequence = pcall(require, "models.sequence")
    if not ok then return nil end
    local s = Sequence.load(sequence_id)
    if not s then return nil end
    return s[field]
end

-- ─── Source viewer / transport / tabs ───────────────────────────────

--- @return string|nil source-viewer mode: 'neutral' 'staged_sequence' 'live_bound_clip'
function M.source_viewer_mode()
    local ok, sv = pcall(require, "ui.source_viewer")
    if not ok then return nil end
    if type(sv.get_mode) == "function" then return sv.get_mode() end
    return rawget(sv, "mode")
end

--- @return string|nil source-viewer's loaded sequence id (master or live-bound clip's owner)
function M.source_viewer_sequence_id()
    local ok, sv = pcall(require, "ui.source_viewer")
    if not ok then return nil end
    if type(sv.get_loaded_sequence_id) == "function" then return sv.get_loaded_sequence_id() end
    return nil
end

--- @return string|nil source-viewer's loaded clip id (live-bound mode only)
function M.source_viewer_clip_id()
    local ok, sv = pcall(require, "ui.source_viewer")
    if not ok then return nil end
    if type(sv.get_loaded_clip_id) == "function" then return sv.get_loaded_clip_id() end
    return nil
end

--- @return string|nil transport target: 'source' 'record' nil
function M.transport_target()
    local ok, transport = pcall(require, "core.playback.transport")
    if not ok then return nil end
    if type(transport.get_target) == "function" then return transport.get_target() end
    return nil
end

--- @return string|nil record engine's loaded sequence id
function M.record_engine_sequence_id()
    local ok, transport = pcall(require, "core.playback.transport")
    if not ok then return nil end
    local engine = rawget(transport, "record_engine")
    if not engine then return nil end
    return rawget(engine, "loaded_sequence_id")
end

--- @return string|nil source engine's loaded sequence id
function M.source_engine_sequence_id()
    local ok, transport = pcall(require, "core.playback.transport")
    if not ok then return nil end
    local engine = rawget(transport, "source_engine")
    if not engine then return nil end
    return rawget(engine, "loaded_sequence_id")
end

--- @return integer number of clips on the displayed sequence's tab strip
function M.displayed_clips_count()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    if not ok then return 0 end
    local strip = ts.get_tab_strip()
    if not strip then return 0 end
    local clips = strip:displayed_clips()
    if type(clips) ~= "table" then return 0 end
    return #clips
end

--- @return integer number of open tabs in the strip
function M.open_tabs_count()
    local ok, tp = pcall(require, "ui.timeline.timeline_panel")
    if not ok then return 0 end
    if type(tp.get_open_tab_ids) ~= "function" then return 0 end
    local ids = tp.get_open_tab_ids()
    if type(ids) ~= "table" then return 0 end
    return #ids
end

-- ─── Coords for clicking (forwards to timeline_panel) ───────────────

--- @param clip_id string
--- @return string "<gx>,<gy>" formatted coords, or empty string if not visible
function M.clip_global_center(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_global_center: clip_id required")
    local ok, tp = pcall(require, "ui.timeline.timeline_panel")
    if not ok then return "" end
    if type(tp.get_clip_global_center_for_test) ~= "function" then return "" end
    local gx, gy = tp.get_clip_global_center_for_test(clip_id)
    if not gx or not gy then return "" end
    return string.format("%d,%d", gx, gy)
end

--- Global click coords that the edge picker will resolve to a specific
--- edge selection on `clip_id`. Thin wrapper around
--- timeline_panel.get_clip_edge_global_point_for_test so the smoke runner
--- can call through the same debug_helpers surface it uses for other
--- coord lookups. Asserts on missing args; the underlying helper asserts
--- on every precondition failure (clip not found, viewport not laid out,
--- target/partner clip too narrow, etc.) so any "" return from here
--- means the picker explicitly refused — not a silent failure path.
--- @param clip_id string
--- @param edge_type string "in" | "out"
--- @param trim_type string "ripple" | "roll"
--- @return string "<gx>,<gy>" coords
function M.clip_edge_global_point(clip_id, edge_type, trim_type)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_edge_global_point: clip_id required")
    assert(edge_type == "in" or edge_type == "out",
        "debug_helpers.clip_edge_global_point: edge_type must be 'in'|'out'")
    assert(trim_type == "ripple" or trim_type == "roll",
        "debug_helpers.clip_edge_global_point: trim_type must be 'ripple'|'roll'")
    local tp = require("ui.timeline.timeline_panel")
    local gx, gy = tp.get_clip_edge_global_point_for_test(clip_id, edge_type, trim_type)
    assert(gx and gy, "debug_helpers.clip_edge_global_point: helper returned "
        .. "nil coords without asserting — bug in get_clip_edge_global_point_for_test")
    return string.format("%d,%d", gx, gy)
end

--- @param frame integer
--- @return string "<gx>,<gy>" coords for ruler click that seeks to frame
function M.ruler_global_point(frame)
    assert(type(frame) == "number",
        "debug_helpers.ruler_global_point: frame required (integer)")
    local ok, tp = pcall(require, "ui.timeline.timeline_panel")
    if not ok then return "" end
    if type(tp.get_ruler_global_point_for_test) ~= "function" then return "" end
    local gx, gy = tp.get_ruler_global_point_for_test(frame)
    if not gx or not gy then return "" end
    return string.format("%d,%d", gx, gy)
end

-- ─── Probe: first armed video clip with body ────────────────────────

--- Find the first non-gap clip on an armed (autoselect=1, locked=0)
--- video track on the displayed record sequence whose duration > min_frames.
--- @param min_frames integer (default 48)
--- @return string "<clip_id>|<track_id>|<sequence_start>|<duration>|<rec_seq>" or "" if none
function M.first_armed_video_clip(min_frames)
    min_frames = min_frames or 48
    local ok, transport = pcall(require, "core.playback.transport")
    if not ok then return "" end
    local rec_seq = transport.record_engine and transport.record_engine.loaded_sequence_id
    if not rec_seq then return "" end
    local ok_t, Track = pcall(require, "models.track")
    if not ok_t then return "" end
    local armed = {}
    for _, t in ipairs(Track.find_by_sequence(rec_seq)) do
        if t.track_type == "VIDEO" and t.autoselect and not t.locked then
            armed[t.id] = true
        end
    end
    local ok_ts, ts = pcall(require, "ui.timeline.timeline_state")
    if not ok_ts then return "" end
    local strip = ts.get_tab_strip()
    if not strip then return "" end
    for _, c in ipairs(strip:displayed_clips()) do
        if armed[c.track_id] and not c.is_gap
            and type(c.duration) == "number" and c.duration > min_frames
            and c.sequence_id and c.sequence_id ~= "" then
            return string.format("%s|%s|%d|%d|%s|%s",
                c.id, c.track_id, c.sequence_start, c.duration, rec_seq,
                c.sequence_id)
        end
    end
    return ""
end

--- Clip spans (track_id, start, end) for every non-gap displayed clip,
--- in iteration order. Stashed on `_smoke_clip_spans` as strings
--- ``"<track_id>:<start>:<end>"``; pair with `smoke_array_chunk`. Lets
--- multi-track edit-nav smokes enumerate every clip span without
--- hitting the 256-char repr cap on the producer's return value.
--- @return integer number of spans (also sets the global)
function M.compute_displayed_clip_spans()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    assert(ok, "debug_helpers.compute_displayed_clip_spans: timeline_state not loadable")
    local strip = ts.get_tab_strip()
    assert(strip, "debug_helpers.compute_displayed_clip_spans: no tab strip")
    local out = {}
    for _, c in ipairs(strip:displayed_clips()) do
        if not c.is_gap then
            out[#out + 1] = string.format("%s:%d:%d",
                c.track_id, c.sequence_start, c.sequence_start + c.duration)
        end
    end
    _G._smoke_clip_spans = out
    return #out
end

--- Edit points (distinct clip start/end frames) on the displayed sequence,
--- sorted ascending. The set is what GoToNext/PrevEdit walks.
--- Stashed on `_smoke_edit_points` global so smoke tests can fetch
--- the count + items via `_smoke_array_chunk` without re-running the
--- query (avoids the debug-terminal 256-char repr cap on long CSVs).
--- @return integer number of edit points (also sets the global)
function M.compute_edit_points_on_displayed_sequence()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    assert(ok, "debug_helpers.compute_edit_points_on_displayed_sequence: timeline_state not loadable")
    local strip = ts.get_tab_strip()
    assert(strip, "debug_helpers.compute_edit_points_on_displayed_sequence: no tab strip")
    local set = {}
    for _, c in ipairs(strip:displayed_clips()) do
        if not c.is_gap then
            set[c.sequence_start] = true
            set[c.sequence_start + c.duration] = true
        end
    end
    local out = {}
    for k, _ in pairs(set) do table.insert(out, k) end
    table.sort(out)
    _G._smoke_edit_points = out
    return #out
end

--- Page from a smoke-array global. Pair with the producer (e.g.
--- `compute_edit_points_on_displayed_sequence`) that stashes the array
--- on `_G[global_name]`. Returns a comma-separated string of items in
--- `[start_idx, end_idx]` (1-based, inclusive). Caller sizes the chunk
--- so the resulting CSV fits inside the debug-terminal repr cap
--- (≤ 256 chars — 20 ints with up to 11 digits each + commas = ~240).
--- @param global_name string name of the stashed array
--- @param start_idx integer 1-based start (inclusive)
--- @param end_idx integer 1-based end (inclusive)
--- @return string comma-separated items
function M.smoke_array_chunk(global_name, start_idx, end_idx)
    assert(type(global_name) == "string" and global_name ~= "",
        "debug_helpers.smoke_array_chunk: global_name required")
    assert(type(start_idx) == "number" and start_idx >= 1,
        "debug_helpers.smoke_array_chunk: start_idx must be >= 1")
    assert(type(end_idx) == "number" and end_idx >= start_idx,
        "debug_helpers.smoke_array_chunk: end_idx must be >= start_idx")
    local arr = _G[global_name]
    assert(type(arr) == "table",
        "debug_helpers.smoke_array_chunk: no array at _G." .. global_name)
    local n = #arr
    if start_idx > n then return "" end
    if end_idx > n then end_idx = n end
    local pieces = {}
    for i = start_idx, end_idx do pieces[#pieces + 1] = tostring(arr[i]) end
    return table.concat(pieces, ",")
end

return M
