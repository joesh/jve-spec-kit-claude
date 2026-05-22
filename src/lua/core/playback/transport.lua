--- core.playback.transport — owner of the two role-bound PlaybackEngine
--- singletons (017).
---
--- The transport TARGET — "which engine receives Space/J/K/L right now" —
--- is DERIVED from current UI state, not stored. There is no
--- set_user_transport(); there is no _target pointer to keep in sync.
--- The single source of truth is the combination of:
---   1. focus_manager.get_focused_panel() — is the source viewer focused?
---   2. timeline_state.get_displayed_tab_kind() — is the timeline panel
---      showing the source tab, or a record tab?
---
--- This eliminates the four-pointer coordination problem (active_sequence_id
--- / displayed_tab_id / focused_panel / _audio_owner) by collapsing the
--- transport-routing question to a pure projection of UI state. Audio
--- handover still happens lazily on engine:play / shuttle / slow_play
--- via audio_playback.halt_current + acquire_for — target changes alone
--- never touch audio.
---
--- Engine loads are signal-driven (single observer per role):
---   active_sequence_changed → record_engine:load(new_seq_id)
---   displayed_tab_changed (source tab) → source_engine:load(master_seq_id)
---
--- @file transport.lua
local log = require("core.logger").for_area("ticks")

local M = {}

M.source_engine = nil
M.record_engine = nil
M._project_id = nil
local playhead_changed_conn = nil

-- Listener registered in transport.init: when any module writes to the
-- model's playhead (SetPlayhead, MovePlayhead, GoToMark*, …) and emits
-- playhead_changed, seek every engine bound to that sequence so the
-- engines stay reactive to model state. Service-layer ownership of
-- engine sync — works in both UI (where sequence_monitor's listener
-- also fires; engine:seek is idempotent on same-frame) and headless
-- contexts (where no sequence_monitor exists).
local function sync_engines_on_playhead_changed(seq_id, frame)
    if not M.is_bootstrapped() then return end
    if type(frame) ~= "number" then return end
    for _, engine in ipairs({ M.source_engine, M.record_engine }) do
        if engine and engine.loaded_sequence_id == seq_id then
            if engine:is_playing() then engine:stop() end
            engine:seek(frame)
        end
    end
end

local function assert_initialized(fn_name)
    assert(M._project_id ~= nil, string.format(
        "core.playback.transport.%s: transport not initialized; call transport.init(project_id) first",
        fn_name))
end

--- Public bootstrap-state predicate. External readers asking "is the
--- transport singleton up?" use this instead of poking M._project_id —
--- _underscore signals private; the field is an internal sentinel that
--- could be replaced with a state machine without breaking callers.
function M.is_bootstrapped()
    return M._project_id ~= nil
end

--- The project_id this transport is initialized for, or nil pre-init /
--- post-shutdown. command_manager uses it to detect "different project
--- than the one transport currently holds" without reading the private
--- field.
function M.bound_project_id()
    return M._project_id
end

local function valid_role(role)
    return role == "source" or role == "record"
end

--- Initialize the transport for `project_id`. Constructs both engines and
--- wires the signal-driven engine-load observers. The target is derived
--- on demand; nothing is persisted or pre-resolved here.
function M.init(project_id)
    assert(type(project_id) == "string" and project_id ~= "", string.format(
        "core.playback.transport.init: project_id must be a non-empty string, got %s",
        tostring(project_id)))
    assert(M._project_id == nil, string.format(
        "core.playback.transport.init: already initialized for project '%s'; "
        .. "call transport.shutdown() first", tostring(M._project_id)))

    local PlaybackEngine = require("core.playback.playback_engine")
    M.source_engine = PlaybackEngine.new("source")
    M.record_engine = PlaybackEngine.new("record")

    M._project_id = project_id

    -- Priority 25: ahead of timeline_state (40) + view modules (50/100)
    -- so by the time UI listeners read engine state, the seek has landed.
    assert(playhead_changed_conn == nil,
        "transport.init: playhead_changed listener already connected")
    playhead_changed_conn = require("core.signals").connect(
        "playhead_changed", sync_engines_on_playhead_changed, 25)

    log.event("transport.init project=%s", project_id:sub(1, 8))

    -- Layout creates SequenceMonitor views at app startup, BEFORE any
    -- project opens — at that point transport.source_engine / record_engine
    -- are still nil, so each view fell back to a locally-owned PlaybackEngine
    -- and attached its video surface to THAT engine. Now that the role-bound
    -- singletons exist, views must rebind so movement-class routing
    -- (transport.engine_for_target) hits an engine that owns a surface.
    require("core.signals").emit("transport_ready")
end

--- Tear down the transport. Engines are released (GC reclaims them).
function M.shutdown()
    assert(M._project_id ~= nil,
        "core.playback.transport.shutdown: transport not initialized")
    if playhead_changed_conn ~= nil then
        require("core.signals").disconnect(playhead_changed_conn)
        playhead_changed_conn = nil
    end
    M.source_engine = nil
    M.record_engine = nil
    M._project_id = nil
    log.event("transport.shutdown")
end

--- Derive the current transport target from UI state. Pure projection:
---   1. source viewer focused → "source"
---   2. timeline panel showing a source tab → "source"
---   3. anything else → "record"
function M.get_target()
    assert_initialized("get_target")
    if require("ui.focus_manager").get_focused_panel() == "source_monitor" then
        return "source"
    end
    if require("ui.timeline.timeline_state").get_displayed_tab_kind() == "source" then
        return "source"
    end
    return "record"
end

--- Return the engine bound to the given role.
function M.engine_for_role(role)
    assert_initialized("engine_for_role")
    assert(valid_role(role), string.format(
        "core.playback.transport.engine_for_role: role must be 'source'|'record', got %s",
        tostring(role)))
    if role == "source" then return M.source_engine end
    return M.record_engine
end

--- Return the engine receiving transport commands right now (derived).
function M.engine_for_target()
    return M.engine_for_role(M.get_target())
end

--- Fire jog-audio burst on the displayed-side engine when it's the one
--- bound to `seq_id`. No-op pre-bootstrap or when the target engine has
--- no audio surface (still-only masters; legacy stubs).
function M.play_frame_audio_target_if_loaded(seq_id, frame)
    if not M.is_bootstrapped() then return end
    local te = M.engine_for_target()
    if te == nil or te.loaded_sequence_id ~= seq_id then return end
    if te.play_frame_audio then te:play_frame_audio(frame) end
end

--- When the displayed tab is cleared (close-last-tab / ShowSourceTab
--- no-master / Toggle no-master), stop the role-bound engine that holds
--- the cleared sequence. Without this, a deferred Park scheduled by the
--- timeline panel viewer-seek (single_shot_timer captured the old
--- sequence's stale playhead) fires AFTER core.clear blanks the model;
--- PlaybackController::Park then asserts `frame >= m_start_frame`
--- against the new (smaller or absent) sequence's bounds. TSO
--- 2026-05-17: frame=122559 vs m_start_frame=63164 after closing source
--- tab.
---
--- Resource-model shape (017): we don't iterate any "all engines"
--- collection — we walk the two role-bound singletons and stop the one
--- (if any) whose loaded sequence matches. Pre-bootstrap → no engines
--- exist, no-op.
local function stop_engine_holding(seq_id)
    if not M.is_bootstrapped() then return end
    for _, role in ipairs({"source", "record"}) do
        local engine = M.engine_for_role(role)
        if engine.sequence and engine.sequence.id == seq_id then
            engine:stop()
        end
    end
end

local Signals = require("core.signals")

Signals.connect("displayed_tab_cleared", function(prev_seq_id)
    assert(type(prev_seq_id) == "string" and prev_seq_id ~= "",
        "transport displayed_tab_cleared listener: prev_seq_id required "
        .. "— core.clear must emit the outgoing seq_id so we know which "
        .. "role-bound engine to stop")
    stop_engine_holding(prev_seq_id)
end)

-- Switching the displayed tab (source↔record, record↔record) parks any
-- in-flight playback on either engine. Target is derived from displayed
-- state, so a swap reassigns which engine receives Space/J/K/L. Continuing
-- to play the prior engine after the user changed what they're looking at
-- is surprising. Stop both engines unconditionally — engine:stop() is
-- idempotent when already parked.
Signals.connect("displayed_tab_changed", function(_new_seq_id, _prev_seq_id)
    if not M.is_bootstrapped() then return end
    for _, role in ipairs({"source", "record"}) do
        local engine = M.engine_for_role(role)
        if engine:is_playing() then engine:stop() end
    end
end)

-- Project change: tear down both role-bound PlaybackControllers + the
-- shared audio session BEFORE media_cache clears its reader pool.
-- Transport owns the cross-engine resource lifecycle — it walks "which
-- engines exist"; the engine module owns per-engine teardown semantics.
-- Priority 5: after project_generation (priority 1), before media_cache
-- (priority 20) so PlaybackController finishes with TMB references
-- before underlying media readers are released.
Signals.connect("project_changed", function()
    if not M.is_bootstrapped() then return end
    local PlaybackEngine = require("core.playback.playback_engine")
    for _, role in ipairs({"source", "record"}) do
        PlaybackEngine.teardown_engine(M.engine_for_role(role))
    end
    PlaybackEngine.shutdown_audio_session()
end, 5)

--- Rebind a role's engine to `seq_id`, stopping any in-flight playback.
--- Idempotent: no-op when the engine is already loaded with the target.
--- Pre-bootstrap (transport.init not run): no-op. Used by UI surfaces
--- that drive what sequence each role observes (source tab click, source
--- viewer load, record tab activation).
function M.bind_role_to_sequence(role, seq_id)
    assert(role == "source" or role == "record", string.format(
        "core.playback.transport.bind_role_to_sequence: role must be "
        .. "'source'|'record', got %s", tostring(role)))
    if not M.is_bootstrapped() then return end
    local engine = M.engine_for_role(role)
    if engine.loaded_sequence_id == seq_id then return end
    if engine.state == "playing" then engine:stop() end
    engine:load(seq_id)
end

return M
