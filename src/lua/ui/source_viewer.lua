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

-- Take the first 8 chars of an id — JVE's existing log/identifier
-- convention for short labels.
local function id_prefix(id)
    return tostring(id):sub(1, 8)
end

-- FR-016f: title sentinel selection for the clip-label component.
-- Returns clip.name when it's a non-empty string; otherwise the clip-id
-- prefix. Clips can legitimately be nameless (gap-as-clip rows,
-- freshly-created clips before naming) — this is not a fallback masking
-- an error, it's deterministic identification from available row data.
local function clip_label(clip)
    if type(clip.name) == "string" and clip.name ~= "" then
        return clip.name
    end
    return id_prefix(clip.id)
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
        return string.format("Source: %s",
            (sequence and sequence.name) or id_prefix(sequence and sequence.id))
    elseif mode == "live_bound_clip" then
        return string.format("Source: %s (in %s)",
            clip_label(clip),
            (owner_sequence and owner_sequence.name)
                or id_prefix(clip.owner_sequence_id))
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

    -- 017 derived-target binding (unchanged).
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

--- Compatibility alias retained for the 019→020 transition window per
--- plan.md Complexity Tracking. Spec 020 §FR-014 deletes this.
function M.load_master_clip(sequence_id, opts)
    return M.load_sequence(sequence_id, opts)
end

--- Load a timeline clip into the source monitor in live-bound mode.
--- @param clip_id string       The clips-table row id.
--- @param opts table|nil       Options: skip_focus (bool)
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

    -- Bind playback to the clip's SOURCE sequence (clip.sequence_id) via
    -- the same code path staged mode uses. No new entity / no wrap
    -- (FR-005, research.md §3).
    source:load_sequence(clip.sequence_id)
    require("core.playback.transport").bind_role_to_sequence("source", clip.sequence_id)

    transition_to_live_bound(clip_id)
    publish_live_bound(clip)
    update_effective_source_live(clip)
    set_monitor_title(source, compute_title("live_bound_clip", nil, clip, owner))

    Signals.emit("source_loaded_changed", clip_id, prev_id)

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

-- ─── I/O key dispatch (FR-013, FR-016b) ─────────────────────────────────────

-- In live-bound mode, route I/O presses to the active trim command
-- (Ripple or Overwrite per edit_mode.get_trim_mode()), with the right
-- edge ("left"=IN, "right"=OUT) and delta. In staged mode, delegate
-- to the underlying SequenceMonitor's existing Sequence:set_in/set_out
-- path. Key-repeat events (is_auto_repeat=true) are dropped (FR-016b).
function M.handle_mark_key(mark_kind, frame, is_auto_repeat)
    assert(mark_kind == "in" or mark_kind == "out", string.format(
        "source_viewer.handle_mark_key: mark_kind must be 'in' or 'out'; got %q",
        tostring(mark_kind)))
    assert(type(frame) == "number", string.format(
        "source_viewer.handle_mark_key: frame must be a number; got %s (%s)",
        type(frame), tostring(frame)))

    if is_auto_repeat then return end
    if _state.mode == "neutral" then return end

    if _state.mode == "live_bound_clip" then
        local Clip = require("models.clip")
        local clip = Clip.load(_state.live_clip_id)
        assert(clip, string.format(
            "source_viewer.handle_mark_key: live-bound clip %s no longer exists; "
            .. "stale state — sequence_content_changed listener should have fired",
            tostring(_state.live_clip_id)))

        local edge       = (mark_kind == "in") and "left" or "right"
        local current    = (mark_kind == "in") and clip.source_in or clip.source_out
        local delta      = frame - current
        if delta == 0 then return end  -- mark is already at this frame

        local edit_mode  = require("core.edit_mode")
        local cmd_name   = (edit_mode.get_trim_mode() == "ripple")
            and "RippleTrimEdge" or "OverwriteTrimEdge"
        require("core.command_manager").execute_interactive(cmd_name, {
            clip_id      = clip.id,
            edge         = edge,
            delta_frames = delta,
            sequence_id  = clip.owner_sequence_id,
            project_id   = clip.project_id,
        })
        return
    end

    -- staged_sequence mode: existing behavior — delegate to monitor's
    -- get/set on the loaded sequence row's mark_in/out.
    local source = get_source_monitor()
    if mark_kind == "in" then
        source.sequence:set_in(frame)
    else
        source.sequence:set_out(frame)
    end
    source.sequence:save()
end

-- ─── Reactor: sequence_content_changed → FR-004a unload / FR-004b refresh ───

local function on_sequence_content_changed(changed_seq_id)
    if _state.mode == "neutral" then return end

    if _state.mode == "staged_sequence" then
        if changed_seq_id ~= _state.staged_seq_id then return end
        local Sequence = require("models.sequence")
        local seq = Sequence.load(_state.staged_seq_id)
        if not seq then
            -- FR-004a: loaded sequence vanished.
            M.unload()
            return
        end
        -- FR-004b: refresh title + selection_hub publish.
        local source = get_source_monitor()
        publish_staged(_state.staged_seq_id, seq)
        set_monitor_title(source, compute_title("staged_sequence", seq))
        return
    end

    -- live_bound_clip
    local Clip = require("models.clip")
    local clip = Clip.load(_state.live_clip_id)
    if not clip then
        -- FR-004a: loaded clip vanished (e.g., DeleteClip).
        M.unload()
        return
    end
    if changed_seq_id ~= clip.owner_sequence_id then return end

    -- FR-004b: refresh from current model state.
    local Sequence = require("models.sequence")
    local owner = Sequence.load(clip.owner_sequence_id)
    local source = get_source_monitor()
    publish_live_bound(clip)
    update_effective_source_live(clip)
    set_monitor_title(source, compute_title("live_bound_clip", nil, clip, owner))
    -- Note: we do NOT call source:load_sequence again here on every change.
    -- Rate/duration changes that need engine re-bind would come through a
    -- different path; routine retrim mutations don't require it.
end

Signals.connect("sequence_content_changed", on_sequence_content_changed)

-- ─── Test helpers ──────────────────────────────────────────────────────────

function M._reset_for_tests()
    transition_to_neutral()
end

return M
