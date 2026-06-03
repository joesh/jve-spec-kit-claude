--- State-query helpers for smoke tests + the debug terminal.
--
-- A flat namespace of stable, named accessors. Smokes call these via
-- `self.eval_str("return require('core.debug_helpers').X()")` instead
-- of hand-writing `require(...)` chains in every test body.
--
-- Two surfaces:
--   * Query functions — pure reads. Return primitive (string/int/bool)
--     or a small flat table; never deep nested structures (debug-terminal
--     repr cap is depth 3). No caching; each call re-reads.
--   * `stash_*` producers — fetch a large array, write it into the
--     module-local `_stashed` table under a fixed key, and return the
--     count. Paired with `array_chunk(key, start, end)` so smokes can
--     fetch arrays that would overflow the 256-char repr cap. These
--     mutate `_stashed` and are named honestly to say so.
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
    return require("core.command_manager").get_active_project_id()
end

--- @return string|nil currently-active sequence id (the edit target — feature 015)
function M.active_sequence_id()
    return require("core.command_manager").get_active_sequence_id()
end

--- @return string|nil currently-displayed sequence id (which sequence is rendered;
--- can differ from active when a source tab is displayed per spec 015)
function M.displayed_sequence_id()
    return require("ui.timeline.state.strip_holder").displayed_sequence_id()
end

--- @return string|nil 'record' / 'source' / nil — which tab kind is currently displayed
function M.displayed_tab_kind()
    return require("ui.timeline.timeline_state").get_displayed_tab_kind()
end

-- ─── Counts (for fast smoke assertions) ─────────────────────────────
--
-- All counts route through the appropriate model — only models/ may
-- execute SQL per JVE's SQL-isolation policy. debug_helpers is a thin
-- forwarder, not its own SQL caller.

--- @return integer number of sequences in the database
function M.sequence_count()
    return require("models.sequence").count()
end

--- @param sequence_id string
--- @return integer total clip count on the given sequence
function M.clip_count_on_sequence(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.clip_count_on_sequence: sequence_id required")
    return #require("models.clip").list_in_sequence(sequence_id)
end

--- @return integer total media rows in the database
function M.media_count()
    return require("models.media").count()
end

--- @param sequence_id string
--- @return integer clip count on the given sequence (raw DB count)
function M.sequence_clip_count(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.sequence_clip_count: sequence_id required")
    return require("models.sequence").count_clips(sequence_id)
end

-- ─── Marks / selection ──────────────────────────────────────────────

--- @return integer|nil mark-in frame on the displayed sequence, or nil if unset
function M.mark_in()
    return require("ui.timeline.timeline_state").get_display_mark_in()
end

--- @return integer|nil mark-out frame on the displayed sequence, or nil if unset
function M.mark_out()
    return require("ui.timeline.timeline_state").get_display_mark_out()
end

--- @return integer count of currently selected clips on the displayed sequence
function M.selection_count()
    local ids = require("ui.timeline.timeline_state").get_selected_clip_ids()
    assert(ids, "debug_helpers.selection_count: timeline_state returned no "
        .. "selection table (no displayed sequence?)")
    return #ids
end

-- ─── Focus / UI state ───────────────────────────────────────────────

--- @return string|nil id of the panel currently holding keyboard focus
function M.focused_panel()
    return require("ui.focus_manager").get_focused_panel()
end

-- ─── Clip state (for undo/redo assertions) ──────────────────────────

--- @param clip_id string
--- @return boolean clip.enabled — true if enabled, false if muted
function M.clip_enabled(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_enabled: clip_id required")
    local clip = require("models.clip").load(clip_id)
    assert(clip, "debug_helpers.clip_enabled: clip not found: " .. clip_id)
    return clip.enabled and true or false
end

-- Whitelist of Lua Clip field names exposed via clip_field. Mirrors
-- the row mapping in `models/clip.lua` (the SQL '_frame'/'_frames'
-- suffix is dropped on load). Unknown fields fail-fast rather than
-- silently returning nil — guards against the recurring smoke-test
-- bug of typing the SQL column name ('source_in_frame', 'start_frame')
-- which would otherwise return nil and crash eval_int's parse downstream.
-- Real fields exposed by `Clip.load` (mirrors `models/clip.lua:87-145`).
-- An unknown name fails fast — keeps the rename-friction the whitelist
-- exists to provide; do NOT add speculative entries.
local CLIP_FIELDS = {
    id = true, project_id = true, name = true,
    track_id = true, track_type = true,
    owner_sequence_id = true, sequence_id = true,
    sequence_start = true, duration = true,
    source_in = true, source_out = true,
    enabled = true, volume = true,
    mark_in = true, mark_out = true, playhead_frame = true,
    master_layer_track_id = true, master_audio_track_id = true,
    fps_mismatch_policy = true, source_sequence_kind = true,
    source_in_subframe = true, source_out_subframe = true,
    created_at = true, modified_at = true,
    media_path = true,
}

--- @param clip_id string
--- @param field string  — see CLIP_FIELDS whitelist above
--- @return any field value (raw from Clip:load)
function M.clip_field(clip_id, field)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_field: clip_id required")
    assert(type(field) == "string" and field ~= "",
        "debug_helpers.clip_field: field required")
    assert(CLIP_FIELDS[field],
        "debug_helpers.clip_field: unknown field '" .. field
        .. "'. Did you use the SQL column name? Lua Clip drops "
        .. "'_frame'/'_frames' suffix — see CLIP_FIELDS in debug_helpers.lua "
        .. "and the row mapping in models/clip.lua.")
    local clip = require("models.clip").load(clip_id)
    assert(clip, "debug_helpers.clip_field: clip not found: " .. clip_id)
    return clip[field]
end

--- @param clip_id string
--- @return boolean true if Clip.load_optional returns a row
function M.clip_exists(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_exists: clip_id required")
    return require("models.clip").load_optional(clip_id) ~= nil
end

-- ─── Playhead / viewport ────────────────────────────────────────────

--- @return integer|nil playhead frame on the displayed sequence (or nil if no displayed seq)
function M.playhead()
    local sid = M.displayed_sequence_id()
    if not sid then return nil end
    local s = require("models.sequence").load(sid)
    if not s then return nil end
    return s.playhead_position
end

--- @param sequence_id string
--- @return integer|nil playhead frame on a specific sequence
function M.playhead_of(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.playhead_of: sequence_id required")
    local s = require("models.sequence").load(sequence_id)
    if not s then return nil end
    return s.playhead_position
end

--- @param sequence_id string
--- @return integer|nil start_timecode_frame
function M.sequence_start_tc(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.sequence_start_tc: sequence_id required")
    local s = require("models.sequence").load(sequence_id)
    if not s then return nil end
    return s.start_timecode_frame
end

local SEQUENCE_FIELDS = {
    id = true, name = true, project_id = true, kind = true,
    mark_in = true, mark_out = true,
    playhead_position = true,
    start_timecode_frame = true, frame_rate = true,
    duration_frames = true,
    viewport_start_time = true, viewport_duration = true,
}

--- @param sequence_id string
--- @param field string  — see SEQUENCE_FIELDS whitelist above
--- @return any field value
function M.sequence_field(sequence_id, field)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "debug_helpers.sequence_field: sequence_id required")
    assert(type(field) == "string" and field ~= "",
        "debug_helpers.sequence_field: field required")
    assert(SEQUENCE_FIELDS[field],
        "debug_helpers.sequence_field: unknown field '" .. field
        .. "' — see SEQUENCE_FIELDS in debug_helpers.lua")
    local s = require("models.sequence").load(sequence_id)
    if not s then return nil end
    return s[field]
end

-- ─── Source viewer / transport / tabs ───────────────────────────────

--- @return string|nil source-viewer mode: 'neutral' 'staged_sequence' 'live_bound_clip'
function M.source_viewer_mode()
    return require("ui.source_viewer").get_mode()
end

--- @return string|nil staged-master sequence id loaded into the source viewer
function M.source_viewer_sequence_id()
    return require("ui.source_viewer").get_staged_seq_id()
end

--- @return string|nil live-bound clip id loaded into the source viewer
function M.source_viewer_clip_id()
    return require("ui.source_viewer").get_live_clip_id()
end

--- @return string|nil transport target: 'source' 'record' nil
function M.transport_target()
    return require("core.playback.transport").get_target()
end

--- @return string|nil record engine's loaded sequence id
function M.record_engine_sequence_id()
    local engine = require("core.playback.transport").record_engine
    return engine and engine.loaded_sequence_id or nil
end

--- @return string|nil source engine's loaded sequence id
function M.source_engine_sequence_id()
    local engine = require("core.playback.transport").source_engine
    return engine and engine.loaded_sequence_id or nil
end

--- @return integer number of clips on the displayed sequence's tab strip
function M.displayed_clips_count()
    local strip = require("ui.timeline.timeline_state").get_tab_strip()
    assert(strip, "debug_helpers.displayed_clips_count: no tab strip "
        .. "(timeline not initialized yet?)")
    return #strip:displayed_clips()
end

--- @return integer number of open tabs in the strip
function M.open_tabs_count()
    return #require("ui.timeline.timeline_panel").get_open_tab_ids()
end

-- ─── Bridge command completion (spec 023 FR-023) ────────────────────

--- Per-op monotonic completion counter for the four bridge commands.
--- Snap before a menu pick, settle, snap after — the delta is the
--- "the async tail actually reached notify()" assertion that the
--- bridge-menu smoke uses. A registered op that's never fired returns
--- 0; an unregistered op asserts (catches typos before the smoke says
--- "0 → 0, passes").
--- @param op_name string one of: "SendToResolve", "ConnectToResolveProject", "SyncGradesFromResolve", "SyncEditsFromResolve"
--- @return integer count
function M.bridge_completion_count(op_name)
    return require("core.commands.bridge_completion").completion_count(op_name)
end

-- ─── Coords for clicking (forwards to timeline_panel) ───────────────

--- @param clip_id string
--- @return string "<gx>,<gy>" formatted coords, or empty string if not visible
function M.clip_global_center(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "debug_helpers.clip_global_center: clip_id required")
    local tp = require("ui.timeline.timeline_panel")
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

-- ─── Probe: first armed video clip with body ────────────────────────

--- Find the first non-gap clip on an armed (autoselect=1, locked=0)
--- video track on the displayed record sequence whose duration > min_frames.
--- @param min_frames integer (default 48)
--- @return string "<clip_id>|<track_id>|<sequence_start>|<duration>|<rec_seq>|<sequence_id>" or "" if none
function M.first_armed_video_clip(min_frames)
    -- Optional arg — explicit nil-check so `min_frames=0` (legitimate
    -- "any non-empty clip") isn't silently rewritten to 48 by `or`.
    if min_frames == nil then min_frames = 48 end
    assert(type(min_frames) == "number" and min_frames >= 0,
        "debug_helpers.first_armed_video_clip: min_frames must be a "
        .. "non-negative integer")
    local transport = require("core.playback.transport")
    assert(transport.record_engine,
        "debug_helpers.first_armed_video_clip: no record engine bound — "
        .. "transport not initialized (was a project ever opened?)")
    local rec_seq = transport.record_engine.loaded_sequence_id
    assert(rec_seq and rec_seq ~= "",
        "debug_helpers.first_armed_video_clip: record engine has no "
        .. "loaded sequence — fixture broken")
    local strip = require("ui.timeline.timeline_state").get_tab_strip()
    assert(strip, "debug_helpers.first_armed_video_clip: no tab strip — "
        .. "timeline not initialized")
    local Track = require("models.track")
    local armed = {}
    for _, t in ipairs(Track.find_by_sequence(rec_seq)) do
        if t.track_type == "VIDEO" and t.autoselect and not t.locked then
            armed[t.id] = true
        end
    end
    -- Empty return = "no clip in fixture matched the criteria" (a
    -- legitimate caller-level signal; the Python wrapper asserts on it).
    -- Environmental preconditions (transport/strip) already asserted above.
    for _, c in ipairs(strip:displayed_clips()) do
        if armed[c.track_id] and not c.is_gap
            and type(c.duration) == "number" and c.duration > min_frames then
            -- `c.sequence_id` is TEXT NOT NULL per schema.sql (clips table);
            -- the `not c.is_gap` filter excludes synthetic gaps that lack one.
            return string.format("%s|%s|%d|%d|%s|%s",
                c.id, c.track_id, c.sequence_start, c.duration, rec_seq,
                c.sequence_id)
        end
    end
    return ""
end

-- ─── Array stashers (paired with array_chunk) ───────────────────────
--
-- Producers stash large arrays into `_stashed` keyed by a stable name,
-- then `array_chunk` pages them back to the smoke runner in CSV
-- fragments. The 256-char debug-terminal repr cap makes this the only
-- way to ferry large arrays across the wire.
--
-- Mutating `_stashed` is the whole point; the names lead with `stash_`
-- so the contract is honest. State is module-local — no `_G` pollution.

local _stashed = {}

local function stash(key, arr)
    _stashed[key] = arr
    return #arr
end

--- Clip spans (track_id, start, end) for every non-gap displayed clip,
--- in iteration order. Stashed under `"displayed_clip_spans"` as
--- strings ``"<track_id>:<start>:<end>"``; pair with `array_chunk`.
--- @return integer number of spans
function M.stash_displayed_clip_spans()
    local strip = require("ui.timeline.timeline_state").get_tab_strip()
    assert(strip, "debug_helpers.stash_displayed_clip_spans: no tab strip")
    local out = {}
    for _, c in ipairs(strip:displayed_clips()) do
        if not c.is_gap then
            out[#out + 1] = string.format("%s:%d:%d",
                c.track_id, c.sequence_start, c.sequence_start + c.duration)
        end
    end
    return stash("displayed_clip_spans", out)
end

--- Edit points (distinct clip start/end frames) on the displayed
--- sequence, sorted ascending — the set that GoToNext/PrevEdit walks.
--- Stashed under `"edit_points"`; pair with `array_chunk`.
--- @return integer number of edit points
function M.stash_edit_points_on_displayed_sequence()
    local strip = require("ui.timeline.timeline_state").get_tab_strip()
    assert(strip, "debug_helpers.stash_edit_points_on_displayed_sequence: no tab strip")
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
    return stash("edit_points", out)
end

--- Page from a stashed array. Pair with a `stash_*` producer that
--- writes the array under `key`. Returns a comma-separated string of
--- items in `[start_idx, end_idx]` (1-based, inclusive). Caller sizes
--- the chunk so the resulting CSV fits inside the debug-terminal repr
--- cap (≤ 256 chars — 20 ints with up to 11 digits each + commas = ~240).
--- @param key string name of the stashed array (matches `stash_*` producer's key)
--- @param start_idx integer 1-based start (inclusive)
--- @param end_idx integer 1-based end (inclusive)
--- @return string comma-separated items
function M.array_chunk(key, start_idx, end_idx)
    assert(type(key) == "string" and key ~= "",
        "debug_helpers.array_chunk: key required")
    assert(type(start_idx) == "number" and start_idx >= 1,
        "debug_helpers.array_chunk: start_idx must be >= 1")
    assert(type(end_idx) == "number" and end_idx >= start_idx,
        "debug_helpers.array_chunk: end_idx must be >= start_idx")
    local arr = _stashed[key]
    assert(type(arr) == "table",
        "debug_helpers.array_chunk: no array stashed under key " .. key)
    local n = #arr
    if start_idx > n then return "" end
    if end_idx > n then end_idx = n end
    local pieces = {}
    for i = start_idx, end_idx do pieces[#pieces + 1] = tostring(arr[i]) end
    return table.concat(pieces, ",")
end

return M
