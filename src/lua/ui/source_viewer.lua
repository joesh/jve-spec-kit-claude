--- Source Viewer: load a sequence (staged mode) or a timeline clip
--- (live-bound mode) into the source monitor. Per spec 019.
---
--- Two modes (FR-001):
---   * staged_sequence — holds a sequence_id; I/O keys mutate
---     sequences.mark_in/out_frame (existing behavior).
---   * live_bound_clip — holds a clip_id; I/O keys dispatch
---     Ripple/OverwriteTrimEdge to mutate the clip's source_in/out
---     directly. The playback engine binds to `clip.sequence_id` (same
---     code path as staged), so no new entity is introduced (FR-005,
---     research.md §3).
---
--- The viewer is a reactive listener of the model (3.14 MVC): a single
--- `sequence_content_changed` handler covers BOTH auto-unload-on-delete
--- (FR-004a) and re-resolve-on-mutation (FR-004b), distinguished by
--- whether `Clip.load` / `Sequence.load` returns nil for the loaded id.
---
--- @file source_viewer.lua
local M = {}

local Signals       = require("core.signals")
local selection_hub = require("ui.selection_hub")

-- panel_id under which the loaded entity is published to selection_hub.
-- Matches the view_id the source SequenceMonitor registers with
-- panel_manager / focus_manager.
local SOURCE_PANEL_ID = "source_monitor"

-- Module-level state. Invariant (asserted on every transition by the
-- transition helpers): exactly one of staged_seq_id / live_clip_id is
-- non-nil unless mode == "neutral" (then both are nil).
local _state = {
    mode          = "neutral",
    staged_seq_id = nil,
    live_clip_id  = nil,
}

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function get_source_monitor()
    local pm = require("ui.panel_manager")
    local source = pm.get_sequence_monitor("source_monitor")
    assert(source, "source_viewer: source_monitor not registered in panel_manager")
    return source
end

-- Display name for any entity (clip, sequence): the row's `name` when
-- non-empty, otherwise the first 8 chars of its id (JVE's standard
-- short-label convention). FR-016f: clips and sequences can legitimately
-- be nameless (gap-as-clip rows, freshly-created entities before naming);
-- this is deterministic identification from available row data, not a
-- fallback masking an error.
local function display_name(name, id)
    if type(name) == "string" and name ~= "" then return name end
    assert(id, "source_viewer.display_name: id required when name is missing")
    return tostring(id):sub(1, 8)
end

local function set_monitor_title(monitor, text)
    assert(monitor._set_title, string.format(
        "source_viewer.set_monitor_title: monitor missing _set_title method "
        .. "(text=%q) — both production SequenceMonitor and test stubs must "
        .. "expose it", tostring(text)))
    monitor:_set_title(text)
end

local function compute_title(mode, sequence, clip, owner_sequence)
    if mode == "staged_sequence" then
        assert(sequence, "compute_title(staged_sequence): sequence required")
        return string.format("Source: %s", display_name(sequence.name, sequence.id))
    elseif mode == "live_bound_clip" then
        assert(clip, "compute_title(live_bound_clip): clip required")
        assert(owner_sequence, "compute_title(live_bound_clip): owner_sequence required")
        return string.format("Source: %s (in %s)",
            display_name(clip.name, clip.id),
            display_name(owner_sequence.name, clip.owner_sequence_id))
    end
    return "Source"
end

-- ─── selection_hub publish ──────────────────────────────────────────────────

local function publish_staged(sequence_id, sequence)
    local project_id = assert(sequence and sequence.project_id, string.format(
        "source_viewer.publish_staged: loaded sequence %s has no project_id",
        tostring(sequence_id)))
    assert(project_id ~= "", string.format(
        "source_viewer.publish_staged: project_id is empty for %s",
        tostring(sequence_id)))
    selection_hub.update_selection(SOURCE_PANEL_ID, {
        {
            item_type   = "timeline",
            id          = sequence_id,
            sequence_id = sequence_id,
            project_id  = project_id,
            sequence    = sequence,
        },
    })
end

local function publish_live_bound(clip)
    assert(clip and clip.project_id and clip.project_id ~= "",
        "source_viewer.publish_live_bound: clip.project_id required")
    assert(clip.owner_sequence_id and clip.owner_sequence_id ~= "",
        "source_viewer.publish_live_bound: clip.owner_sequence_id required")
    selection_hub.update_selection(SOURCE_PANEL_ID, {
        {
            item_type   = "clip",
            clip_id     = clip.id,
            project_id  = clip.project_id,
            sequence_id = clip.owner_sequence_id,  -- the OWNER (FR-028)
            clip        = clip,
        },
    })
end

-- ─── effective_source override channel (FR-016d) ────────────────────────────
-- Delegate to effective_source's per-direction entry points so 015's
-- single-source-id contract gets extended atomically with the
-- in/out overrides when live-bound mode is in effect. The three
-- entry points are documented in
-- specs/019-source-viewer-clip-mode/contracts/effective_source_pass_through.md
-- and are mandatory — no guards.

local function update_effective_source_staged(sequence_id)
    require("core.effective_source")._set_source_viewer_sequence(sequence_id)
end

local function update_effective_source_live(clip)
    require("core.effective_source")._set_source_viewer_clip(
        clip.sequence_id, clip.source_in, clip.source_out)
end

local function clear_effective_source()
    require("core.effective_source")._clear_source_viewer()
end

-- Where to park the source-side playhead for a `load_clip` call.
-- Caller-supplied (`opts.playhead_frame`) wins; otherwise `clip.source_in`.
-- The raw value is then clamped to the loaded clip's source window: in
-- live-bound mode the clip IS the user's viewport, so a load-time park
-- outside its range would render a frame the user can't see in their
-- marks. Common driver: Shift+F-ing a clip whose timeline extent
-- doesn't cover the rec playhead (e.g. double-click on a distant clip)
-- — owner_frame_to_source then maps to a value outside [source_in,
-- source_out], which this clamp pulls back to the nearest edge.
--
-- Rule (Joe 2026-05-22): rec playhead *before* clip on the timeline
-- → snap to IN; *after* → snap to OUT. Forward clips only: for forward
-- clips `min(in, out) == source_in` and `max(in, out) == source_out`,
-- so a plain min/max implements the rule. Reverse clips
-- (`source_in > source_out`) can't reach this path today —
-- `effective_source._set_source_viewer_clip` asserts `out > in` first
-- — so we don't carry direction-aware logic; if reverse-clip support
-- is added upstream this clamp needs a revisit (see the
-- direction-aware version in git history `6158cd0e^..6158cd0e`).
--
-- Free scrubbing / jogging post-load is NOT clamped (FR-016a — the
-- playhead is a free cursor). This is parking-only.
local function pick_playhead_target(opts, clip, clip_id)
    -- Preconditions: source_in/source_out gate both the default-target
    -- branch and the clamp window. Assert before picking so an error
    -- points at the missing column, not at arithmetic on nil.
    assert(type(clip.source_in) == "number", string.format(
        "source_viewer.load_clip: clip %s missing source_in",
        tostring(clip_id)))
    assert(type(clip.source_out) == "number", string.format(
        "source_viewer.load_clip: clip %s missing source_out",
        tostring(clip_id)))

    local raw
    if opts.playhead_frame ~= nil then
        assert(type(opts.playhead_frame) == "number", string.format(
            "source_viewer.load_clip: opts.playhead_frame must be a "
            .. "number; got %s", type(opts.playhead_frame)))
        raw = opts.playhead_frame
    else
        raw = clip.source_in
    end

    return math.max(clip.source_in, math.min(raw, clip.source_out))
end

-- ─── State transitions (assert invariants) ──────────────────────────────────

local function assert_neutral_invariants()
    assert(_state.staged_seq_id == nil and _state.live_clip_id == nil,
        "source_viewer: neutral mode must have nil staged + live ids")
end

local function transition_to_staged(sequence_id)
    _state.mode          = "staged_sequence"
    _state.staged_seq_id = sequence_id
    _state.live_clip_id  = nil
end

local function transition_to_live_bound(clip_id)
    _state.mode          = "live_bound_clip"
    _state.staged_seq_id = nil
    _state.live_clip_id  = clip_id
end

local function transition_to_neutral()
    _state.mode          = "neutral"
    _state.staged_seq_id = nil
    _state.live_clip_id  = nil
    assert_neutral_invariants()
end

-- ─── Public API ─────────────────────────────────────────────────────────────

--- Return the current source-viewer mode (FR-001).
function M.get_mode()
    return _state.mode
end

--- Return the live-bound clip id, or nil when not in live-bound mode.
--- Model accessor consumed by source-monitor-scoped commands
--- (SetMarkAndTrimIfClip and similar) that need the loaded clip
--- identity without reaching into module-private state.
function M.get_live_clip_id()
    return _state.live_clip_id
end

--- Return the staged sequence id, or nil when not in staged mode.
function M.get_staged_seq_id()
    return _state.staged_seq_id
end

--- Load a sequence into the source monitor in staged mode.
--- @param sequence_id string  Any sequence kind (master or clip-kind).
--- @param opts table|nil      Options: skip_focus (bool)
function M.load_sequence(sequence_id, opts)
    assert(sequence_id and sequence_id ~= "",
        "source_viewer.load_sequence: sequence_id required")
    opts = opts or {}

    local source = get_source_monitor()
    local prev_id = _state.staged_seq_id or _state.live_clip_id

    source:load_sequence(sequence_id)

    require("core.playback.transport").bind_role_to_sequence("source", sequence_id)

    transition_to_staged(sequence_id)
    publish_staged(sequence_id, source.sequence)
    update_effective_source_staged(sequence_id)
    set_monitor_title(source, compute_title("staged_sequence", source.sequence))

    Signals.emit("source_loaded_changed", sequence_id, prev_id)

    if not opts.skip_focus then
        require("ui.focus_manager").focus_panel("source_monitor")
    end
    return true
end

--- Compatibility alias retained for the 019→021 transition window per
--- plan.md Complexity Tracking. Spec 021 §FR-014 deletes this.
function M.load_master_clip(sequence_id, opts)
    return M.load_sequence(sequence_id, opts)
end

--- Load a timeline clip into the source monitor in live-bound mode.
--- @param clip_id string       The clips-table row id.
--- @param opts table|nil       Options:
---     * skip_focus (bool)     skip the focus-panel side effect
---     * playhead_frame (number) park the source-side playhead at this
---       frame (in clip.sequence_id's frame space). Caller-supplied;
---       Shift+F passes `Clip.owner_frame_to_source(clip, rec_playhead)`
---       so the source tab + viewer land on the source frame currently
---       under the record playhead (FR-024 v2 2026-05-22). When absent,
---       defaults to clip.source_in (the safe "no caller opinion"
---       value used by direct callers — lua unit tests, future paths
---       that don't have a rec-tab context).
function M.load_clip(clip_id, opts)
    assert(clip_id and clip_id ~= "",
        "source_viewer.load_clip: clip_id required")
    opts = opts or {}

    local Clip = require("models.clip")
    local clip = Clip.load(clip_id)
    assert(clip, string.format(
        "source_viewer.load_clip: clip not found: %s", tostring(clip_id)))

    local Sequence = require("models.sequence")
    local owner = Sequence.load(clip.owner_sequence_id)
    assert(owner, string.format(
        "source_viewer.load_clip: owner sequence %s for clip %s not found",
        tostring(clip.owner_sequence_id), tostring(clip_id)))

    local source = get_source_monitor()
    local prev_id = _state.staged_seq_id or _state.live_clip_id

    -- Set the live-bound override BEFORE binding the monitor. Without
    -- this, `source:load_sequence` below fires the monitor's listener
    -- (which the source-side mark bar subscribes to via
    -- `config.on_listener(render)` in monitor_mark_bar.lua:249) —
    -- that render reads marks through `SequenceMonitor:get_mark_in/out`,
    -- which now consults `effective_source.get_source_marks_for`. If
    -- the override isn't populated yet, the first render draws no
    -- marks and the bar stays empty until the user incidentally seeks
    -- (manual repro 2026-05-21: "src viewer marks weren't moving til
    -- I moved the playhead"). effective_source has no state dependency
    -- on the source viewer's mode flag, so it's safe to write here
    -- before transition.
    update_effective_source_live(clip)

    -- Bind playback to the clip's SOURCE sequence (clip.sequence_id) via
    -- the same code path staged mode uses. No new entity / no wrap
    -- (FR-005, research.md §3).
    source:load_sequence(clip.sequence_id)
    require("core.playback.transport").bind_role_to_sequence("source", clip.sequence_id)

    -- Park the source-side playhead via core.playhead.set — single
    -- canonical model write that fires playhead_changed; transport's
    -- listener seeks the source engine bound above and the src tab's
    -- ruler reads the freshly-written master row. No double-seek, no
    -- view/model drift.
    require("core.playhead").set(clip.sequence_id,
        pick_playhead_target(opts, clip, clip_id))

    transition_to_live_bound(clip_id)
    publish_live_bound(clip)
    set_monitor_title(source, compute_title("live_bound_clip", nil, clip, owner))

    -- Payload is the SOURCE sequence id (see
    -- contracts/source_viewer_load_clip.md). Clip identity rides
    -- selection_hub + effective_source override fields, not this signal.
    Signals.emit("source_loaded_changed", clip.sequence_id, prev_id)

    if not opts.skip_focus then
        require("ui.focus_manager").focus_panel("source_monitor")
    end
    return true
end

--- Unload whatever is currently in the source monitor.
--- No-op + no signal when already neutral.
function M.unload()
    if _state.mode == "neutral" then return end
    local prev_id = _state.staged_seq_id or _state.live_clip_id

    local source = get_source_monitor()
    source:unload()
    selection_hub.clear_selection(SOURCE_PANEL_ID)
    clear_effective_source()
    transition_to_neutral()
    set_monitor_title(source, compute_title("neutral"))

    Signals.emit("source_loaded_changed", nil, prev_id)
end

-- ─── Reactor: sequence_content_changed → FR-004a unload / FR-004b refresh ───

local function refresh_staged(changed_seq_id)
    if changed_seq_id ~= _state.staged_seq_id then return end
    -- FR-004a: a sequence-content-changed signal MAY mean the staged
    -- sequence was deleted. Use the nil-returning load variant so the
    -- "if not seq → unload" branch actually fires instead of asserting.
    local seq = require("models.sequence").load(_state.staged_seq_id)
    if not seq then M.unload(); return end                       -- FR-004a
    local source = get_source_monitor()                          -- FR-004b
    publish_staged(_state.staged_seq_id, seq)
    set_monitor_title(source, compute_title("staged_sequence", seq))
end

local function refresh_live_bound(changed_seq_id)
    -- Use load_optional: a sequence_content_changed signal can mean the
    -- live-bound clip was deleted (FR-004a). Clip.load asserts on a
    -- missing row, which would mask the auto-unload path; load_optional
    -- returns nil and lets the `if not clip` branch dispatch unload.
    local clip = require("models.clip").load_optional(_state.live_clip_id)
    if not clip then M.unload(); return end                      -- FR-004a
    if changed_seq_id ~= clip.owner_sequence_id then return end
    local owner = require("models.sequence").load(clip.owner_sequence_id)
    local source = get_source_monitor()                          -- FR-004b
    publish_live_bound(clip)
    update_effective_source_live(clip)
    set_monitor_title(source, compute_title("live_bound_clip", nil, clip, owner))
    -- Engine re-bind on rate/duration change is a separate path; routine
    -- retrim mutations don't require source:load_sequence again here.
end

local function on_sequence_content_changed(changed_seq_id)
    if _state.mode == "neutral"         then return end
    if _state.mode == "staged_sequence" then return refresh_staged(changed_seq_id) end
    return refresh_live_bound(changed_seq_id)
end

Signals.connect("sequence_content_changed", on_sequence_content_changed)

-- ─── Test helpers ──────────────────────────────────────────────────────────

function M._reset_for_tests()
    transition_to_neutral()
end

return M
