--- Timeline state facade.
--
-- Post-022/1.3e (5a5ba9ef) the bulk per-clip / per-track read methods
-- (get_clips, get_tracks, get_clip_by_id, get_clips_for_track,
-- get_track_clip_index, get_clips_at_time, get_sequence_id) all moved
-- onto TimelineTabStrip and its ergonomic methods. Callers go through
-- M.get_tab_strip() and call strip:displayed_clips() / track_clip_index /
-- clip_by_id / active_sequence_id directly.
--
-- This module's remaining responsibilities are the cross-cutting concerns
-- that don't fit cleanly on any single tab:
-- - apply_mutations: dispatch a mutation bucket to the target tab's
--   per-tab cache, then scoped gap recompute on touched tracks, then
--   emit timeline_mutations_applied
-- - View-state pointer accessors (sequence_frame_rate getters, viewport,
--   scroll offsets, playhead) that since H1 (2026-05-27) route through
--   strip_holder.displayed_cache() onto the per-tab cache. Marks remain
--   on the active sequence row (loaded into data.sequence by core_state)
--   because they persist per-sequence in DB, not per-view.
-- - Tab lifecycle wrappers (switch_to_record_tab / switch_to_source_tab /
--   close_displayed_tab) that need to coordinate with persistence
-- - Selection facade (delegates to selection_state)
--
-- Non-goals:
-- - Owning per-tab clip / track / view-state data (lives on TimelineTab)
-- - Command execution (goes through command_manager)
-- - Direct clip mutation from callers — use commands; the public
--   update_clip / add_clip / remove_clip wrappers error on purpose
--
-- Invariants:
-- - Gap recompute is scoped to the touched tracks when every affected
--   track id is derivable from the payload; falls back to full recompute
--   only when a delete references a clip the tab can't resolve
-- - Views pull from this facade or the strip (per MVC, rule 3.0); nothing
--   here pushes to them. timeline_mutations_applied is a notification,
--   not a payload channel.
--
-- @file timeline_state.lua
local M = {}

-- Sub-modules
local data = require("ui.timeline.state.timeline_state_data")
local core = require("ui.timeline.state.timeline_core_state")
local viewport = require("ui.timeline.state.viewport_state")
local selection = require("ui.timeline.state.selection_state")
local tracks = require("ui.timeline.state.track_state")
local clips = require("ui.timeline.state.clip_state")
local Signals = require("core.signals")

-- TimelineTabStrip — encapsulates the open-tab list + DisplayedTab /
-- ActiveRecordTab pointers per spec 015 architectural foundation. Held
-- module-private; accessed via M.get_tab_strip(). Reset on project_changed
-- so each project gets a fresh strip (Phase 2a; consumer migration in 2b).
local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")
local strip_holder     = require("ui.timeline.state.strip_holder")
local log = require("core.logger").for_area("ui")

-- Replace the strip with a fresh, empty one and publish it to the holder.
-- Used at module init and on every project boundary (pre-swap detach and
-- post-swap reset) so all three sites share one definition of "blank strip".
local tab_strip
local function reset_tab_strip()
    tab_strip = TimelineTabStrip.new()
    strip_holder.set(tab_strip)
end
reset_tab_strip()

-- Shared Data & Constants
M.dimensions = data.dimensions
M.colors = {
    background = "#232323",
    track_odd = "#2b2b2b",
    track_even = "#252525",
    video_track_header = "#1d1d1f",
    audio_track_header = "#1d1d1f",
    clip = "#548bb5",
    clip_video = "#548bb5",
    clip_audio = "#32986b",
    clip_audio_disabled = "#555555",
    clip_video_disabled = "#555555",
    clip_selected = "#ff8c42",
    clip_disabled = "#3f7fcc",
    clip_disabled_text = "#c3d6ff",
    clip_video_offline = "#8b4444",
    clip_audio_offline = "#8b4444",
    clip_offline_text = "#ff6666",
    clip_boundary = "#232323",
    gap_selected_fill = "#ff8c42",
    gap_selected_outline = "#ff8c42",
    mark_range_fill = "#19dfeeff",
    mark_range_edge = "#ff6b6b",
    playhead = "#ff6b6b",
    text = "#cccccc",
    grid_line = "#3a3a3a",
    selection_box = "#ff8c42",
    edge_selected_available = "#66ff66",
    edge_selected_limit = "#ff6666",
}

-- Core Lifecycle
-- Strip-authoritative (015 #6): init opens a record/source tab for the
-- sequence and sets it active+displayed BEFORE delegating to core, so the
-- strip is the source of truth from the first frame. core.init still
-- loads tracks/clips and view-state into the displayed tab's per-tab
-- cache (H1, 2026-05-27); only the active-edit pointer + selection
-- + marks land on data.state / data.sequence.
function M.init(sequence_id, project_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "timeline_state.init: sequence_id required")
    local Sequence = require("models.sequence")
    local seq = Sequence.load(sequence_id)
    assert(seq, string.format(
        "timeline_state.init: sequence %s not found", sequence_id))
    -- FR-005: the active sequence (edit target) must NEVER be a master.
    -- timeline_state.init sets active=sequence_id unconditionally inside
    -- core.init, so a master id here would poison data.state.sequence_id
    -- AND the persisted `last_open_sequence_id` setting (active_sequence_changed
    -- listener writes it). Refuse loudly — the caller (project restore) is
    -- responsible for picking a record sequence id; use M.activate_displayed
    -- afterwards if you also want a master to be the displayed SourceTab.
    assert(not seq:is_master(), string.format(
        "timeline_state.init: sequence %s (%q) is a master — masters cannot "
        .. "be the active edit target (FR-005). Pass a record sequence id "
        .. "and use activate_displayed/switch_to_source_tab to show a master.",
        sequence_id, tostring(seq.name)))
    local rec_tab = tab_strip:find_record_tab_by_sequence_id(sequence_id)
    if rec_tab then
        -- Existing tab may be stale: same sequence_id can map to a different
        -- DB row after a project re-open (tests share a process across
        -- multiple DBs without firing project_changed). Refresh the per-tab
        -- cache here for the same reason core.init reloads — the model on
        -- disk just changed.
        rec_tab:load_from_database()
    else
        rec_tab = tab_strip:open_record_tab(sequence_id)
    end
    tab_strip:switch_active_record(rec_tab)
    return core.init(sequence_id, project_id)
end
-- Strip-authoritative: clearing the active-sequence reference also drops
-- the strip's displayed pointer so external readers see "no displayed tab".
-- We capture the outgoing displayed sequence id BEFORE clearing the strip
-- so core.clear can emit displayed_tab_cleared(prev_seq_id) — subscribers
-- (playback engine, deferred viewer seeks) need the id to know which
-- engine/timer to shut down.
--
-- Flush per-sequence view-state to the OUTGOING row BEFORE the strip is
-- cleared. core.persist_state_to_db resolves the target row via
-- strip_holder; clearing the strip first would leave the gate seeing nil
-- and silently drop the dirty bit, losing the user's unsaved viewport /
-- scroll / selection on the round-trip.
M.clear = function()
    local prev_seq_id = strip_holder.displayed_sequence_id()
    if prev_seq_id then
        core.persist_state_to_db(true)
    end
    tab_strip:clear_displayed()
    -- Drop both pointers so post-clear state is fully blank — leaving
    -- active set leaves get_active_sequence_id returning a stale id and
    -- views can't render blank (FR-005).
    tab_strip:clear_active_record()
    return core.clear(prev_seq_id)
end
M.set_project_id = core.set_project_id
M.reset = data.reset
M.persist_state_to_db = core.persist_state_to_db
M.reload_clips = core.reload_clips
-- Strip-authoritative displayed pointer (015 #6): every call routes through
-- the TimelineTabStrip first so the strip's `displayed_tab` is the SOLE
-- source of truth for "which sequence is the timeline view rendering".
-- Master id → SourceTab (singleton, opened on demand). Non-master → record
-- tab (opened on demand, idempotent). Once the strip is synced we delegate
-- to `core.activate_displayed` to load tracks/clips into the per-tab cache
-- (H1) and marks into data.sequence (per-sequence, DB-persisted).
--
-- Flush ordering (data-corruption bait, fixed 2026-05-17): persist
-- resolves the target DB row via strip_holder, so any pending
-- per-sequence view-state (debounced viewport/scroll/selection) MUST be
-- flushed BEFORE the strip pointer is swapped. Without the pre-swap
-- flush, the dirty A-side values get written to B's row when B becomes
-- displayed — A's pending edits silently corrupt B's persisted playhead
-- / viewport / selection.
function M.activate_displayed(seq_id)
    assert(type(seq_id) == "string" and seq_id ~= "",
        "timeline_state.activate_displayed: seq_id required")
    local prev_seq_id = strip_holder.displayed_sequence_id()
    if prev_seq_id and prev_seq_id ~= seq_id then
        core.persist_state_to_db(true)
    end

    local Sequence = require("models.sequence")
    local seq = Sequence.load(seq_id)
    assert(seq, string.format(
        "timeline_state.activate_displayed: sequence %s not found", seq_id))
    if seq:is_master() then
        local source_tab = tab_strip:get_source_tab()
        if not source_tab or source_tab.sequence_id ~= seq_id then
            source_tab = tab_strip:open_source_tab(seq_id)
        end
        tab_strip:switch_displayed(source_tab)
    else
        local rec_tab = tab_strip:find_record_tab_by_sequence_id(seq_id)
            or tab_strip:open_record_tab(seq_id)
        tab_strip:switch_displayed(rec_tab)
    end
    return core.activate_displayed(seq_id, prev_seq_id)
end

--- Close a tab and refresh the timeline view if it was the displayed tab.
--- The strip's close handler falls the displayed pointer back to a
--- remaining tab (source-tab close → active record; record-tab close →
--- another record or source). The timeline view must follow — otherwise
--- the strip says "displayed is X" while the timeline view still pulls
--- Y's clips (TSO 2026-05-16: clicked × on source tab, view kept
--- rendering master's V1 clip under the now-record-only strip).
---
--- Does NOT touch the active pointer or open_tabs/Qt state — those are
--- panel-layer concerns. Panel-level close_tab wraps this call.
---
--- Takes the strip TimelineTab object (not a sequence_id) so the empty
--- source tab — which has no sequence_id — closes through the same path.
function M.close_displayed_tab(strip_tab)
    assert(type(strip_tab) == "table" and strip_tab.id,
        "timeline_state.close_displayed_tab: a strip tab with an id is required")
    local prev_displayed = tab_strip:get_displayed()
    local was_displayed = (prev_displayed == strip_tab)
    -- The outgoing displayed sequence_id (nil if the displayed tab was the
    -- empty source tab) — used to flush/announce the right row.
    local prev_seq_id = prev_displayed and prev_displayed.sequence_id or nil

    -- Flush any pending per-sequence view-state to the OUTGOING row before
    -- the strip mutation below changes which row persist resolves to. Only
    -- meaningful when the closing tab is displayed AND has a sequence row
    -- (the empty source tab has none). Unlike the switch paths
    -- (flush_outgoing_displayed_view_state) this deliberately skips
    -- persist_scroll_offsets — the tab is being closed, so its scroll position
    -- is discarded, not preserved.
    if was_displayed and prev_seq_id then
        core.persist_state_to_db(true)
    end

    -- Close in the strip by kind — the strip tab carries its own kind, so
    -- the caller never has to know which singleton a sequence_id maps to.
    if strip_tab.kind == "source" then
        tab_strip:close_source_tab()
    else
        tab_strip:close_record_tab(strip_tab)
    end

    if was_displayed then
        local new_displayed = tab_strip:get_displayed()
        if new_displayed then
            if new_displayed.sequence_id then
                -- Call core.activate_displayed directly with the pre-close
                -- prev_seq_id. The public M.activate_displayed re-reads the
                -- strip for prev, which by now matches new_displayed (the
                -- strip already swapped), and core short-circuits on equal
                -- prev/new — the timeline view never reloads.
                return core.activate_displayed(new_displayed.sequence_id, prev_seq_id)
            end
            -- The fallback displayed tab is the empty source tab (no
            -- sequence to load) — emit the rebuild signal directly so the
            -- panel re-pulls the blank body.
            Signals.emit("displayed_tab_changed", nil, prev_seq_id)
            data.notify_listeners()
            return
        end
        -- Strip is empty after close (the user closed the lone tab). Clear so
        -- MVC pull yields no clips and the timeline view renders blank (TSO
        -- 2026-05-17: without this, closed sequence's clips stayed on screen
        -- under an empty strip).
        --
        -- prev_seq_id is the sequence that JUST closed (nil if it was the
        -- empty source tab) — pass it through so core.clear emits
        -- displayed_tab_cleared(prev_seq_id) and transport subscribers can
        -- stop the engine that had been driving the closed sequence.
        core.clear(prev_seq_id)
    end
end
M.add_listener = data.add_listener
M.remove_listener = data.remove_listener
M.flush_pending_notify = data.flush_pending_notify

-- Active Edge Drag State (shared across panes; not persisted)
M.get_active_edge_drag_state = function()
    return data.state.active_edge_drag_state
end

M.set_active_edge_drag_state = function(edge_drag_state)
    data.state.active_edge_drag_state = edge_drag_state
    data.notify_listeners()
end

M.clear_active_edge_drag_state = function()
    data.state.active_edge_drag_state = nil
    data.notify_listeners()
end

-- Active Clip Drag State (shared across panes; not persisted)
M.get_active_clip_drag_state = function()
    return data.state.active_clip_drag_state
end

M.set_active_clip_drag_state = function(clip_drag_state)
    data.state.active_clip_drag_state = clip_drag_state
    data.notify_listeners()
end

M.clear_active_clip_drag_state = function()
    data.state.active_clip_drag_state = nil
    data.notify_listeners()
end

-- Viewport & Playhead
M.get_viewport_start_time = viewport.get_viewport_start_time
M.set_viewport_start_time = function(time_obj)
    return viewport.set_viewport_start_time(time_obj, core.persist_state_to_db)
end
M.get_viewport_duration = viewport.get_viewport_duration
M.get_timeline_extent = viewport.get_timeline_extent
M.set_viewport_duration = function(duration_obj, opts)
    return viewport.set_viewport_duration(duration_obj, opts, core.persist_state_to_db)
end
M.get_playhead_position = viewport.get_playhead_position
M.set_playhead_position = viewport.set_playhead_position

-- Last frame the pointer was over inside a timeline widget.
-- Updated by timeline_view_input on mouse move; consumed by zoom-at-pointer
-- commands. Nil when the pointer has never been over a timeline.
function M.get_last_pointer_frame()
    return data.state.last_pointer_frame
end
function M.set_last_pointer_frame(frame)
    if frame == nil then
        data.state.last_pointer_frame = nil
        return
    end
    assert(type(frame) == "number" and frame == math.floor(frame),
        "set_last_pointer_frame: frame must be integer or nil")
    data.state.last_pointer_frame = frame
end
M.surface_playhead = function()
    return viewport.surface_playhead(core.persist_state_to_db)
end
M.surface_range = function(start_frame, end_frame)
    return viewport.surface_range(start_frame, end_frame, core.persist_state_to_db)
end
M.set_is_playing = function(playing) data.state.is_playing = playing end
M.time_to_pixel = viewport.time_to_pixel
M.pixel_to_time = viewport.pixel_to_time
M.capture_viewport = function()
    return {
        start_time = viewport.get_viewport_start_time(),
        duration = viewport.get_viewport_duration()
    }
end
M.restore_viewport = function(snapshot)
    if not snapshot then return end
    if snapshot.duration then viewport.set_viewport_duration(snapshot.duration) end
    if snapshot.start_time then viewport.set_viewport_start_time(snapshot.start_time) end
end
M.push_viewport_guard = viewport.push_viewport_guard
M.pop_viewport_guard = viewport.pop_viewport_guard

-- Tracks
-- Per-tab track/clip reads live on TimelineTabStrip (displayed_tracks,
-- displayed_clips, clip_by_id, clips_for_track, track_clip_index,
-- clips_at_time) — reach via timeline_state.get_tab_strip().
M.get_video_tracks = tracks.get_video_tracks
M.get_audio_tracks = tracks.get_audio_tracks
M.get_track_height = tracks.get_height
-- Every real height change must trigger a persist flush. Without this
-- wrapping, the splitter-release handler (the sole interactive caller)
-- only marks track_layout_dirty=true and waits for an unrelated state
-- change to flush — quit between resize and the next event loses the
-- height. The persist_callback indirection mirrors what
-- selection/viewport setters use.
M.set_track_height = function(track_id, height)
    assert(core and core.persist_state_to_db,
        "timeline_state.set_track_height: timeline_core_state.persist_state_to_db missing — wiring broken")
    tracks.set_height(track_id, height, function(_force)
        core.persist_state_to_db()
    end)
end
M.get_track_by_id = tracks.get_by_id
M.get_primary_track_id = tracks.get_primary_id
M.get_default_video_track_id = function() return tracks.get_primary_id("VIDEO") end
M.get_default_audio_track_id = function() return tracks.get_primary_id("AUDIO") end

-- Clips: read accessors live on TimelineTabStrip (see Tracks comment above).
-- Derive the set of track_ids touched by a mutation payload. Updates,
-- inserts, and bulk_shifts carry track_id directly. Deletes carry only
-- clip_id, so resolve via clip_lookup before clip_state removes the row.
--
-- Returns (set, scope_is_known). scope_is_known is false when a delete
-- references a clip that isn't in the live state — in that case the
-- caller must fall back to a full gap recompute.
local function collect_affected_track_ids(mutations)
    local affected = {}
    local scope_is_known = true

    local function note(track_id)
        if track_id and track_id ~= "" then
            affected[track_id] = true
        else
            scope_is_known = false
        end
    end

    if mutations.updates then
        for _, m in ipairs(mutations.updates) do note(m.track_id) end
    end
    if mutations.inserts then
        for _, m in ipairs(mutations.inserts) do note(m.track_id) end
    end
    if mutations.bulk_shifts then
        for _, m in ipairs(mutations.bulk_shifts) do note(m.track_id) end
    end
    if mutations.deletes then
        for _, entry in ipairs(mutations.deletes) do
            local clip_id = type(entry) == "table" and entry.clip_id or entry
            local existing = clips.get_by_id(clip_id)
            note(existing and existing.track_id)
        end
    end

    return affected, scope_is_known
end

-- Resolve a mutation bucket's target tab via the strip. Writes go to the
-- tab whose sequence_id matches the mutation's target — never to "active"
-- or "displayed". Returns nil when no tab is open for that sequence; the
-- caller treats this as "DB write already done; next open hydrates fresh."
local function resolve_target_tab(target_seq)
    local rec = tab_strip:find_record_tab_by_sequence_id(target_seq)
    if rec then return rec end
    local src = tab_strip:get_source_tab()
    if src and src.sequence_id == target_seq then return src end
    return nil
end

-- Prune deleted clips from the global selection state. Selection is a
-- cross-tab singleton on data.state; per-tab cache mutate path leaves
-- it alone, so this orchestration step handles it.
local function prune_selection_for_deletes(deletes)
    if not deletes then return end
    for _, entry in ipairs(deletes) do
        local clip_id = type(entry) == "table" and entry.clip_id or entry
        if data.state.selected_clips then
            for i = #data.state.selected_clips, 1, -1 do
                local sel = data.state.selected_clips[i]
                if sel and sel.id == clip_id then
                    table.remove(data.state.selected_clips, i)
                end
            end
        end
        if data.state.selected_edges then
            for i = #data.state.selected_edges, 1, -1 do
                local edge = data.state.selected_edges[i]
                if edge and edge.clip_id == clip_id then
                    table.remove(data.state.selected_edges, i)
                end
            end
        end
    end
end

-- Hydrate any clips referenced by updates that aren't yet in the target
-- tab's cache. Skips gap-id updates — gaps are in-memory only and
-- "missing gap" means "the gap was evicted" (legitimate).
local function hydrate_updates_for_tab(target_tab, updates)
    if not updates then return end
    for _, update in ipairs(updates) do
        assert(update.clip_id, "hydrate_updates_for_tab: update payload "
            .. "missing clip_id — every producer (add_update_mutation, "
            .. "blade/split_clip mutation_entry) must set it")
        local clip_id = update.clip_id
        local is_gap = update.is_gap
            or (type(clip_id) == "string" and clip_id:sub(1, 4) == "gap_")
        if not is_gap and not target_tab:get_clip_by_id(clip_id) then
            clips.hydrate_into_tab(target_tab, clip_id, update.track_sequence_id)
        end
    end
end

local function apply_mutations(sequence_or_mutations, maybe_mutations, persist_callback)
    local target_seq, mutations, callback
    if type(sequence_or_mutations) == "string" or type(sequence_or_mutations) == "number" then
        target_seq = sequence_or_mutations
        mutations  = maybe_mutations
        callback   = persist_callback
    else
        mutations = sequence_or_mutations
        callback  = maybe_mutations
    end

    assert(type(mutations) == "table",
        "timeline_state.apply_mutations: mutations must be a table, got " .. type(mutations))

    -- Target sequence_id MUST be derivable — either the 3-arg form or
    -- mutations.sequence_id. Rule 2.13: no fallback to "active" / "displayed".
    -- command_manager already asserts mutations.sequence_id at its boundary;
    -- this reaffirms the contract at the timeline_state layer.
    if not target_seq then target_seq = mutations.sequence_id end
    assert(target_seq and target_seq ~= "", string.format(
        "timeline_state.apply_mutations: target sequence_id required "
        .. "(pass as first arg or set mutations.sequence_id); got %s",
        tostring(target_seq)))

    local target_tab = resolve_target_tab(target_seq)
    -- No open tab for the target sequence: the DB write happened already
    -- (executor + command_helper.apply_mutations). When the user opens or
    -- displays this sequence, tab:load_from_database hydrates the cache
    -- fresh. Treat as applied so command_manager's safety-net reload
    -- doesn't fire. Signal still emits so cross-cutting subscribers
    -- (inspector, mutation generation bump) see the event.
    if not target_tab then
        Signals.emit("timeline_mutations_applied", mutations, true)
        return true
    end

    -- Unified orchestration: tab cache is the model; this function adds
    -- cross-cutting concerns (selection cleanup, gap recompute, version
    -- stamping, view-listener notify, signal).
    local affected_tracks, scope_is_known = collect_affected_track_ids(mutations)
    hydrate_updates_for_tab(target_tab, mutations.updates)
    prune_selection_for_deletes(mutations.deletes)

    local changed = target_tab:apply_mutations(mutations)
    if changed then
        local core_state = require("ui.timeline.state.timeline_core_state")
        if scope_is_known and next(affected_tracks) ~= nil then
            core_state.recompute_gap_clips_for_tab(target_tab, affected_tracks)
        else
            core_state.recompute_gap_clips_for_tab(target_tab)
        end
        -- Version stamping: validate_clip_fresh checks per-clip _version
        -- against the module-level counter. Stamping unconditionally on
        -- the changed tab keeps any held clip reference detectable as
        -- stale by handlers reading from non-target tabs after this.
        clips.inc_version()
        local v = clips.get_version()
        for _, c in ipairs(target_tab.cache.clips) do c._version = v end
        if callback then callback() end
        -- Notify view listeners only when the displayed cache changed.
        -- Non-displayed mutations don't visually change the timeline.
        if target_tab == tab_strip:get_displayed() then
            data.notify_listeners()
        end
    end
    Signals.emit("timeline_mutations_applied", mutations, changed)
    return changed
end

M.apply_mutations = apply_mutations
M.update_clip = function()
    error("timeline_state.update_clip: removed — route through command_manager.execute()")
end
M.add_clip = function()
    error("timeline_state.add_clip: removed — route through command_manager.execute()")
end
M.remove_clip = function()
    error("timeline_state.remove_clip: removed — route through command_manager.execute()")
end
M.validate_clip_fresh = function(clip)
    if not clip then return false, "Nil clip" end
    if not clip._version then return false, "No version" end
    if clip._version ~= clips.get_version() then return false, "Stale" end
    return true
end
M.get_state_version = clips.get_version

-- Selection
M.get_selected_clips = selection.get_selected_clips
local function persist_selection_state()
    if core and core.persist_state_to_db then
        core.persist_state_to_db()
    end
end

M.set_selection = function(clip_list)
    selection.set_selection(clip_list, persist_selection_state)
end

M.get_selected_edges = selection.get_selected_edges

M.set_edge_selection = function(edges, opts)
    selection.set_edge_selection(edges, opts, persist_selection_state)
end

M.restore_edge_selection = function(edges, opts)
    selection.restore_edge_selection(edges, opts, persist_selection_state)
end

M.toggle_edge_selection = function(clip_id, edge_type, trim_type)
    return selection.toggle_edge_selection(clip_id, edge_type, trim_type, persist_selection_state)
end

M.clear_edge_selection = function()
    selection.clear_edge_selection(persist_selection_state)
end

M.get_selected_gaps = selection.get_selected_gaps

M.set_gap_selection = function(gaps)
    selection.set_gap_selection(gaps)
    persist_selection_state()
end

M.toggle_gap_selection = function(gap)
    local changed = selection.toggle_gap_selection(gap)
    if changed ~= nil then
        persist_selection_state()
    end
    return changed
end
M.clear_gap_selection = function() selection.set_gap_selection({}) end
M.set_on_selection_changed = selection.set_on_selection_changed
M.normalize_edge_selection = selection.normalize_edge_selection

-- Project/Sequence Accessors
M.get_project_id = function() return data.state.project_id end
-- Active record sequence_id lives on TimelineTabStrip — use
-- timeline_state.get_tab_strip():active_sequence_id().

-- Tab / sequence pointer accessors (FR-005, data-model.md §3)
--
-- active_sequence_id: the Record sequence that edit commands target.
--   Backed by data.state.sequence_id; exposed under the spec-canonical name.
--   NEVER set to a SourceTab master sequence_id.
-- displayed_tab_id: the tab whose content the timeline view renders.
--   May be a source master sequence_id while active_sequence_id is unchanged.

M.get_active_sequence_id = function() return data.state.sequence_id end
-- Strip-authoritative: the displayed tab lives on TimelineTabStrip; this
-- accessor is a pure projection. Returns nil when no tab is displayed
-- (project-changed reset, blank panel).
M.get_displayed_tab_id   = function()
    local displayed = tab_strip:get_displayed()
    return displayed and displayed.sequence_id or nil
end

-- 017: returns the kind of the currently-displayed timeline tab ("source"
-- or "record"), or nil when the panel is blank. The transport target is
-- derived from this — never stored independently.
M.get_displayed_tab_kind = function()
    local displayed = tab_strip:get_displayed()
    return displayed and displayed.kind or nil
end

-- Movement-class commands (SetPlayhead, SetMarkIn/Out, GoToMarkIn/Out, ...)
-- fired from the timeline panel target the *displayed* tab. Movement is
-- not an edit (FR-005): edits go to active_sequence_id, but marks and the
-- playhead belong to whatever the user is looking at. When the source
-- tab is displayed, displayed_tab_id is the source master; otherwise it
-- equals the active record. Either way, displayed is the right answer
-- for the timeline panel's ruler/key dispatchers. Returns nil when the
-- panel is blank (no displayed tab).
M.get_movement_target_sequence_id = function()
    local displayed = tab_strip:get_displayed()
    return displayed and displayed.sequence_id or nil
end

-- Flush the OUTGOING displayed tab's per-sequence view-state (scroll offsets
-- included) to its DB row BEFORE the displayed pointer moves to next_seq_id.
-- persist resolves the target row via the strip's displayed pointer; after the
-- swap it would write the outgoing values into the incoming row. Returns the
-- outgoing displayed sequence_id (nil if the displayed tab had none — e.g. the
-- empty source tab), which callers thread into activate_displayed / signal
-- payloads. next_seq_id may be nil (switching TO the empty source tab, which
-- has no sequence) — then any displayed sequence is "outgoing" and is flushed.
local function flush_outgoing_displayed_view_state(next_seq_id)
    local prev_tab = tab_strip:get_displayed()
    local prev_seq_id = prev_tab and prev_tab.sequence_id or nil
    if prev_seq_id and prev_seq_id ~= next_seq_id then
        M.persist_scroll_offsets()
        core.persist_state_to_db(true)
    end
    return prev_seq_id
end

-- Switch to the Source tab. Only displayed_tab_id changes; active_sequence_id
-- is untouched (FR-005). Delegates to core.activate_displayed which persists
-- outgoing displayed view-state, loads incoming, and emits displayed_tab_changed.
-- Also keeps the TimelineTabStrip's displayed pointer in sync (Phase 2c).
function M.switch_to_source_tab(source_seq_id)
    assert(source_seq_id and source_seq_id ~= "",
        "timeline_state.switch_to_source_tab: source_seq_id required")
    -- Capture + flush the outgoing displayed view-state before the swap so
    -- core knows where to flush and the row is written to the right sequence.
    local prev_seq_id = flush_outgoing_displayed_view_state(source_seq_id)
    -- Ensure the strip has a source tab pointing at this seq, then make it
    -- the displayed pointer. open_source_tab is idempotent (reloads in
    -- place if a source tab is already open).
    local source_tab = tab_strip:get_source_tab()
    if not source_tab or source_tab.sequence_id ~= source_seq_id then
        source_tab = tab_strip:open_source_tab(source_seq_id)
    end
    tab_strip:switch_displayed(source_tab)
    core.activate_displayed(source_seq_id, prev_seq_id)
    -- 017: transport target is DERIVED from displayed-tab kind — no
    -- explicit set is needed. Bind the source engine to this master so
    -- Space/J/K/L have a sequence to act on. bind_role_to_sequence is
    -- a no-op pre-bootstrap (headless tests).
    require("core.playback.transport").bind_role_to_sequence("source", source_seq_id)
    M.persist_tab_strip()
end

-- Switch to a Record tab. Both displayed_tab_id and active_sequence_id are
-- updated. activate_displayed handles the displayed swap + signal; this
-- function additionally manages the active edit target and emits
-- active_sequence_changed when it transitions. Also keeps the
-- TimelineTabStrip's active+displayed pointers in sync (Phase 2c).
function M.switch_to_record_tab(seq_id)
    assert(seq_id and seq_id ~= "",
        "timeline_state.switch_to_record_tab: seq_id required")
    local prev_active = data.state.sequence_id
    -- Flush the outgoing displayed view-state before the strip pointer moves.
    local prev_seq_id = flush_outgoing_displayed_view_state(seq_id)
    -- Ensure the strip has a record tab for this seq, then make it both
    -- active and displayed (FR-004). open_record_tab is idempotent.
    local rec_tab = tab_strip:find_record_tab_by_sequence_id(seq_id)
        or tab_strip:open_record_tab(seq_id)
    tab_strip:switch_active_record(rec_tab)
    core.activate_displayed(seq_id, prev_seq_id)
    -- 017: transport target is DERIVED from displayed-tab kind. The
    -- switch_displayed call above updates the strip's pointer; the next
    -- transport.get_target() resolves to "record".
    if prev_active ~= seq_id then
        data.state.sequence_id = seq_id
        -- 017 FR-005a/b: rebind the record-role engine to the new active
        -- sequence (no-op pre-bootstrap).
        require("core.playback.transport").bind_role_to_sequence("record", seq_id)
        Signals.emit("active_sequence_changed", seq_id, prev_active)
    end
    M.persist_tab_strip()
end

-- Project setting holding the serialized TimelineTabStrip — the SINGLE
-- source of truth for tab restore. It supersedes the former trio of
-- must-agree settings (open_sequence_ids / source_tab_sequence_id /
-- displayed_tab_kind): the blob carries the tab list, the displayed/active
-- pointers, AND each tab's kind, so the displayed side and the source tab
-- identity fall out of one round-trip. last_open_sequence_id stays separate
-- — it has secondary consumers (codec-probe priority, initial-sequence
-- resolution) that read it without the strip.
local TAB_STRIP_SETTING = "timeline_tab_strip"

--- Persist the whole TimelineTabStrip (tabs + displayed/active pointers) so
--- the next project open restores every tab — including the empty source
--- tab, whose absent sequence_id round-trips naturally. No-op pre-project
--- (headless tests). Called at every strip mutation the facade owns
--- (switch_to_*_tab, show_empty_source_tab) and by the panel after it
--- opens/closes a tab (persist_open_tabs).
function M.persist_tab_strip()
    local project_id = data.state.project_id
    if not project_id or project_id == "" then return end
    local database = require("core.database")
    database.set_project_setting(project_id, TAB_STRIP_SETTING, tab_strip:serialize())
end

--- Read the persisted strip blob, or nil when none was saved (fresh project,
--- pre-015 .jvp, or a project that never opened a tab). Used by layout
--- restore to decide whether to rebuild from the blob.
function M.get_persisted_tab_strip_blob()
    local project_id = data.state.project_id
    if not project_id or project_id == "" then return nil end
    local database = require("core.database")
    local blob = database.get_project_setting(project_id, TAB_STRIP_SETTING)
    if type(blob) ~= "table" then return nil end
    return blob
end

--- Show the empty source tab — the source side displayed while the source
--- monitor holds nothing (sequence_id=nil, blank body). Opens the singleton
--- empty source tab in the strip and makes it the displayed tab; ONLY the
--- displayed pointer moves (FR-005 — the active record edit target is
--- untouched). There is no sequence to load, so this emits
--- displayed_tab_changed directly (the empty tab's cache is already the
--- blank-body state the timeline view tolerates) rather than routing through
--- core.activate_displayed, which requires a real sequence. Persists so
--- quit/restart restores the empty source tab like any other.
function M.show_empty_source_tab()
    -- Flush the outgoing displayed view-state before the displayed pointer
    -- moves. next_seq_id is nil — the empty source tab has no sequence — so
    -- any displayed sequence counts as outgoing and is flushed.
    local prev_seq_id = flush_outgoing_displayed_view_state(nil)
    local source_tab = tab_strip:ensure_empty_source_tab()
    tab_strip:switch_displayed(source_tab)
    -- displayed_tab_changed subscribers (panel rebuild, transport) ignore the
    -- payload; new=nil because the empty source tab has no sequence_id.
    Signals.emit("displayed_tab_changed", nil, prev_seq_id)
    data.notify_listeners()
    M.persist_tab_strip()
end
-- Per-sequence view-state getters/setters route through the displayed
-- tab's cache (audit H1). Singleton mirror (data.state.*) is gone — every
-- per-sequence field lives on tab.cache and is loaded by tab:load_from_database.
-- Returns nil when no tab is displayed; callers that do arithmetic must
-- assert. Setters no-op when no displayed cache (matches "blank panel"
-- semantics — a stray Qt scroll event during transition has no target).
M.get_sequence_frame_rate = function()
    local cache = strip_holder.displayed_cache()
    return cache and cache.sequence_frame_rate or nil
end
M.get_start_timecode_frame = function()
    local cache = strip_holder.displayed_cache()
    return cache and cache.sequence_timecode_start_frame or nil
end
M.get_video_scroll_offset = function()
    local cache = strip_holder.displayed_cache()
    return cache and cache.video_scroll_offset or nil
end
M.get_audio_scroll_offset = function()
    local cache = strip_holder.displayed_cache()
    return cache and cache.audio_scroll_offset or nil
end
-- Scroll setters update the displayed-tab cache and throttle-persist to DB.
-- The throttle (~SCROLL_PERSIST_THROTTLE_MS, rough estimate) coalesces
-- drag/wheel storms into one DB write per idle window. Tab-switch and
-- shutdown remain explicit save points for kill paths that don't let the
-- timer fire.
--
-- Offsets are ANCHORED, in each pane's natural coordinate (single-owner
-- redesign, 2026-06-09): video = pixels from the BOTTOM of the content
-- (V1 sits at the bottom of the stack, so 0 = V1 visible — the fresh-
-- sequence default needs no sentinel); audio = pixels from the TOP
-- (0 = A1 visible). timeline_panel converts to/from Qt's top-anchored
-- scrollbar values at the view boundary. Anchored coordinates survive
-- viewport and content resizes without adjustment, which is what lets
-- the view re-apply the model on every Qt rangeChanged instead of
-- needing the old BottomAnchorFilter timer dance.
--
-- These setters are called ONLY from timeline_panel's gesture/navigation
-- entry points — never from Qt change events, which can't distinguish
-- user intent from layout side effects.
--
-- Silent no-op when no displayed cache: legitimate transient state during
-- tab close / project switch. Logged at `event` level (off by default).
local SCROLL_PERSIST_THROTTLE_MS = 250  -- estimate; settle time of Qt rebuild storm not measured
local scroll_persist_pending = false
local function schedule_scroll_persist()
    if scroll_persist_pending then return end
    if type(qt_create_single_shot_timer) ~= "function" then return end  -- lint-allow: R004 Qt binding may not be wired in pure-Lua test harnesses -- luacheck: globals qt_create_single_shot_timer
    scroll_persist_pending = true
    qt_create_single_shot_timer(SCROLL_PERSIST_THROTTLE_MS, function()
        scroll_persist_pending = false
        M.persist_scroll_offsets()
    end)
end
-- M.reset is bound to data.reset above (line 157), which cannot see this
-- module-level upvalue. Wrap it so a project close / re-init also clears
-- the throttle flag — without this, a timer in flight at reset leaves
-- pending=true and the first scroll in the next project silently skips
-- scheduling.
local _scroll_data_reset = M.reset
M.reset = function(...)
    scroll_persist_pending = false
    return _scroll_data_reset(...)
end
M.set_video_scroll_offset = function(offset)
    local cache = strip_holder.displayed_cache()
    if not cache then
        log.event("set_video_scroll_offset: no displayed cache; dropping offset=%s", tostring(offset))
        return
    end
    cache.video_scroll_offset = math.floor(offset)
    schedule_scroll_persist()
end
M.set_audio_scroll_offset = function(offset)
    local cache = strip_holder.displayed_cache()
    if not cache then
        log.event("set_audio_scroll_offset: no displayed cache; dropping offset=%s", tostring(offset))
        return
    end
    cache.audio_scroll_offset = math.floor(offset)
    schedule_scroll_persist()
end

--- Persist current scroll offsets to DB. Call at save points only.
-- Reads the displayed tab's cache and nothing else. The cache is the
-- single owner of scroll position (single-owner redesign, 2026-06-09):
-- it is written ONLY by user gestures and explicit navigation through
-- timeline_panel's scroll entry points, so it is always the value the
-- user last chose. The Qt widget is a projection of this value and is
-- deliberately NOT consulted — a widget can sit clamped at a stale
-- position while Qt's deferred layout catches up with content changes,
-- and persisting that transient destroyed saved offsets (Joe's
-- kill/restart scroll loss; test_scroll_survives_tab_switch.lua).
M.persist_scroll_offsets = function()
    -- Scroll offsets are view-state and belong to the DISPLAYED sequence
    -- (FR-005, FR-007), not the active edit target. With option A
    -- (source-tab persistence to the master row, decided 2026-05-13),
    -- this writes to whatever sequence the strip's displayed tab points
    -- at — including masters when the SourceTab is shown.
    local displayed = tab_strip:get_displayed()
    if not displayed then return end
    local seq_id = displayed.sequence_id
    local cache = displayed.cache
    -- Cache fields are populated by tab:load_from_database; on a freshly
    -- opened tab with no load yet they're nil. Skip — nothing to persist.
    local v_off = cache.video_scroll_offset
    local a_off = cache.audio_scroll_offset
    if v_off == nil or a_off == nil then return end
    local Sequence = require("models.sequence")
    Sequence.update_scroll_offsets(seq_id, v_off, a_off)
end
M.get_video_audio_split_ratio = function()
    local cache = strip_holder.displayed_cache()
    return cache and cache.video_audio_split_ratio or nil
end
M.set_video_audio_split_ratio = function(ratio)
    local cache = strip_holder.displayed_cache()
    if not cache then
        -- Same rationale as set_video_scroll_offset: legitimate transient
        -- during tab close / project switch. Logged so the drop is
        -- observable in JVE_LOG=ui:event.
        log.event("set_video_audio_split_ratio: no displayed cache; dropping ratio=%s", tostring(ratio))
        return
    end
    cache.video_audio_split_ratio = math.max(0.05, math.min(0.95, ratio))
    core.persist_state_to_db()
end
M.get_sequence_fps_numerator = function()
    local cache = strip_holder.displayed_cache()
    assert(cache and cache.sequence_frame_rate,
        "timeline_state.get_sequence_fps_numerator: no displayed tab or sequence_frame_rate not initialized")
    return cache.sequence_frame_rate.fps_numerator
end
M.get_sequence_fps_denominator = function()
    local cache = strip_holder.displayed_cache()
    assert(cache and cache.sequence_frame_rate,
        "timeline_state.get_sequence_fps_denominator: no displayed tab or sequence_frame_rate not initialized")
    return cache.sequence_frame_rate.fps_denominator
end

-- Marks: read from sequence model (set via undoable mark commands)
-- Always returns active (record) sequence marks regardless of displayed tab.
M.get_mark_in  = function() return data.sequence and data.sequence.mark_in end
M.get_mark_out = function() return data.sequence and data.sequence.mark_out end

-- Source-sequence marks (FR-038): marks on the loaded master sequence.
-- Strip-authoritative (015 #6): pull from the SourceTab via TimelineTab
-- rather than from a parallel data.source_sequence cache. TimelineTab
-- pulls fresh from the sequence row each call (Sequence.load ≈ 21µs,
-- well within frame budget — see test_timeline_tab_get_marks_perf.lua).
local function source_tab_marks()
    local source_tab = tab_strip:get_source_tab()
    return source_tab and source_tab:get_marks() or nil
end
M.get_source_mark_in  = function()
    local m = source_tab_marks(); return m and m.in_frame
end
M.get_source_mark_out = function()
    local m = source_tab_marks(); return m and m.out_frame
end
M.get_source_sequence_fps = function()
    local source_tab = tab_strip:get_source_tab()
    if not source_tab then return nil end
    -- Empty source tab: nothing loaded ⇒ no source row, no frame-rate.
    -- Same blank-state contract as TimelineTab:get_marks().
    if source_tab:is_empty_source() then return nil end
    local Sequence = require("models.sequence")
    local seq = Sequence.load(source_tab.sequence_id)
    return seq and seq.frame_rate
end

-- Display-aware mark accessors (FR-038): return the marks of whichever tab
-- the timeline view is currently rendering. Phase 3: backed by the
-- TimelineTabStrip's displayed tab — no flat-singleton dispatch helper.
-- TimelineTab:get_marks() pulls fresh from the sequence row (MVC rule 3.0).
M.get_display_mark_in = function()
    local displayed = tab_strip:get_displayed()
    return displayed and displayed:get_marks().in_frame or nil
end
M.get_display_mark_out = function()
    local displayed = tab_strip:get_displayed()
    return displayed and displayed:get_marks().out_frame or nil
end

-- Strip-backed predicate used by get_ghost_mark to decide whether the
-- computed mark belongs to the side currently rendered (so the ruler renders
-- it in the right coordinate space). Phase 3: kind-driven instead of the
-- "displayed != active means source" flat-singleton heuristic.
local function is_source_tab_displayed()
    local displayed = tab_strip:get_displayed()
    return displayed ~= nil and displayed.kind == "source"
end

-- Pull the (source_seq, record_seq) pair currently driving ghost-mark
-- math. Returns nil if either side is absent (no source/record tab open
-- or the sequence row is gone).
local function load_ghost_seq_pair()
    local source_tab = tab_strip:get_source_tab()
    local record_tab = tab_strip:get_active_record()
    if not source_tab or not record_tab then return nil end
    -- Empty source tab: nothing loaded ⇒ no source row to anchor ghost
    -- math. Same blank-state contract as TimelineTab:get_marks().
    if source_tab:is_empty_source() then return nil end
    local Sequence = require("models.sequence")
    local src_seq = Sequence.load(source_tab.sequence_id)
    local rec_seq = Sequence.load(record_tab.sequence_id)
    if not src_seq or not rec_seq then return nil end
    return src_seq, rec_seq
end

local function assert_ghost_frame_rates(src_fps, rec_fps)
    assert(src_fps and src_fps.fps_numerator and src_fps.fps_denominator,
        "timeline_state.get_ghost_mark: source sequence has invalid frame_rate")
    assert(rec_fps and rec_fps.fps_numerator and rec_fps.fps_denominator,
        "timeline_state.get_ghost_mark: active sequence has invalid frame_rate")
end

-- Returns the {src_in, src_out, rec_in, rec_out} table ONLY when exactly
-- 3 of 4 marks are set AND any present src/rec range is positive. Returns
-- nil for any state where ghost computation should be skipped (zero/
-- negative ranges are transient editing states, not errors).
local function collect_three_point_marks(src_seq, rec_seq)
    local marks = {
        src_in  = src_seq.mark_in,
        src_out = src_seq.mark_out,
        rec_in  = rec_seq.mark_in,
        rec_out = rec_seq.mark_out,
    }
    local nil_count = 0
    for _, k in ipairs({ "src_in", "src_out", "rec_in", "rec_out" }) do
        if marks[k] == nil then nil_count = nil_count + 1 end
    end
    if nil_count ~= 1 then return nil end
    if marks.src_in and marks.src_out and marks.src_out <= marks.src_in then return nil end
    if marks.rec_in and marks.rec_out and marks.rec_out <= marks.rec_in then return nil end
    return marks
end

-- Ghost mark (FR-036/FR-037): when exactly 3 of the 4 marks are set,
-- compute the missing one via three_point_math. Returns the result only
-- when it belongs to the CURRENTLY DISPLAYED tab's ruler (so the caller
-- renders it on the visible ruler in the right coordinate space).
-- Returns { frame = integer, key = string } or nil.
M.get_ghost_mark = function()
    local src_seq, rec_seq = load_ghost_seq_pair()
    if not src_seq then return nil end

    local src_fps, rec_fps = src_seq.frame_rate, rec_seq.frame_rate
    assert_ghost_frame_rates(src_fps, rec_fps)

    local marks = collect_three_point_marks(src_seq, rec_seq)
    if not marks then return nil end

    -- Ghost mark is a transient UI display, not a committed edit. Cross-rate
    -- conversions don't generally divide exactly; floor for display. The
    -- Insert/Overwrite commit path uses "strict" mode (asserts non-integer).
    local tpm = require("core.three_point_math")
    local src_pair = { src_fps.fps_numerator, src_fps.fps_denominator }
    local rec_pair = { rec_fps.fps_numerator, rec_fps.fps_denominator }
    local result = tpm.compute(marks, src_pair, rec_pair, { rounding = "floor" })

    local key = result.computed_key
    local on_source_side = (key == "src_in" or key == "src_out")
    if is_source_tab_displayed() ~= on_source_side then return nil end

    return { frame = result[key], key = key }
end

-- Debug (Proxied to local vars in original? No, original had local debug_layouts. We can move that to view logic or keep it here if views call it.)
-- Since views call `debug_record...`, we need to support it.
-- I'll add a simple debug store to this facade or data.lua.
local debug_layouts = {}
M.debug_begin_layout_capture = function(id, w, h) debug_layouts[id] = {w=w, h=h, tracks={}, clips={}} end
M.debug_record_track_layout = function(id, tid, y, h) if debug_layouts[id] then debug_layouts[id].tracks[tid] = {y=y, h=h} end end
M.debug_record_clip_layout = function(id, cid, tid, x, y, w, h) if debug_layouts[id] then debug_layouts[id].clips[cid] = {x=x, y=y, w=w, h=h, track_id=tid} end end

-- Dragging (Interaction state is in data)
M.is_dragging_playhead = function() return data.state.dragging_playhead end
M.set_dragging_playhead = function(v) data.state.dragging_playhead = v end

-- Roll detection - now uses integer frame arithmetic
M.detect_edge_at_position = function(...)
    local clip, click_x, width = ...
    local ui_constants = require("core.ui_constants")
    local EDGE = ui_constants.TIMELINE.EDGE_ZONE_PX
    assert(type(clip.sequence_start) == "number", "detect_edge_at_position: sequence_start must be integer")
    assert(type(clip.duration) == "number", "detect_edge_at_position: duration must be integer")
    local sx = M.time_to_pixel(clip.sequence_start, width)
    local ex = M.time_to_pixel(clip.sequence_start + clip.duration, width)
    if math.abs(click_x - sx) <= EDGE then return "in", "ripple" end
    if math.abs(click_x - ex) <= EDGE then return "out", "ripple" end
    return nil
end

M.detect_roll_between_clips = function(c1, c2, x, w)
    local ui_constants = require("core.ui_constants")
    local ROLL = ui_constants.TIMELINE.ROLL_ZONE_PX or 0
    assert(type(c1.sequence_start) == "number" and type(c1.duration) == "number",
        "detect_roll_between_clips: c1 coords must be integers")
    assert(type(c2.sequence_start) == "number",
        "detect_roll_between_clips: c2.sequence_start must be integer")
    local boundary_left = c1.sequence_start + c1.duration
    local boundary_right = c2.sequence_start

    local sx = M.time_to_pixel(boundary_left, w)
    local ex = M.time_to_pixel(boundary_right, w)
    local span = math.abs(ex - sx)
    if span > ROLL then
        return false
    end

    local mid = (sx + ex) / 2
    return math.abs(x - mid) <= (ROLL / 2)
end

--- Clear state that shouldn't persist across projects. Delegates to the
--- core-state full reset so the new project's views render against an
--- empty model (MVC pull). Covers the feature 010 case where the new
--- project has no active sequence and `load_sequence` is never called —
--- without this, the previous project's tracks/clips keep rendering.
---
--- Post-switch by design: pending writes are flushed in the
--- project_will_change handler below (feature 014). Before that
--- pre-switch handler existed, this function had to discard
--- persist_dirty to avoid writing the outgoing project's state to the
--- incoming project's DB; pending writes were silently lost on every
--- project switch. With the pre-switch flush in place, by the time we
--- reach this handler everything has already been persisted to the
--- correct (outgoing) DB.
function M.on_project_change()
    core.reset_for_project_change()
    -- Each project gets a fresh tab strip. Phase 2b will populate it from
    -- the project's persisted `open_sequence_ids`; until then we reset
    -- (see memory todo_tab_strip_persistence_phase_2b).
    reset_tab_strip()
end

--- Access the TimelineTabStrip that encapsulates this view's open-tab list.
--- The strip is the source of truth for DisplayedTab / ActiveRecordTab
--- pointers per spec 015. Phase 2a exposes it; Phase 2b migrates consumers
--- (timeline_panel.lua tab open/close, mark accessors, etc.) to use it.
function M.get_tab_strip()
    return tab_strip
end

-- Pre-switch: flush pending timeline state to the OUTGOING DB before
-- the swap (feature 014, FR-001..FR-003). Priority 40 mirrors the
-- post-switch handler so pre/post pair line up in dispatch order.
-- core.persist_state_to_db only writes when persist_dirty is true; it
-- short-circuits otherwise. Cold start (outgoing_id == nil) has
-- nothing to flush; we skip without erroring.
assert(type(core.persist_state_to_db) == "function",
    "timeline_state: timeline_core_state.persist_state_to_db is required " ..
    "for the project_will_change pre-switch handler (feature 014). " ..
    "If this function was renamed/removed, update both modules together.")
-- ----------------------------------------------------------------------------
-- MODULE-LEVEL SIGNAL CONNECTS — intentional process-lifetime listeners.
-- All connects below run once per `require` and survive across project
-- swaps. The project_changed handler resets per-project state on the
-- same dispatch. NOT A LEAK; do not add disconnects.
-- ----------------------------------------------------------------------------
Signals.connect("project_will_change", function(outgoing_id)
    if not outgoing_id or outgoing_id == "" then return end
    core.persist_state_to_db(true)
    -- Detach the displayed tab BEFORE the database connection swaps. A
    -- long import (e.g. a large DRP) pumps Qt events mid-swap to drive
    -- the progress bar (progress_panel), which reentrantly repaints the
    -- timeline. With the outgoing tab still displayed, that repaint asks
    -- the INCOMING database for a sequence it does not contain and
    -- TimelineTab:get_marks asserts. A fresh empty strip renders blank
    -- (get_display_mark_* → nil) until project_changed repopulates it for
    -- the new project. The flush above ran first, so no view-state is lost.
    reset_tab_strip()
end, 40)

-- Register for project_changed signal
Signals.connect("project_changed", M.on_project_change, 40)

-- Prune timeline tabs whose sequence was deleted (DeleteSequence command,
-- undo of CreateSequence). Without this, the tab strip carries a zombie
-- pointer to a deleted sequence_id; the panel's next render falls back
-- to loading a master sequence (FR-005 violation) and the playback /
-- emp.clip_provider stack crashes. The strip's own close_record_tab /
-- close_source_tab repair displayed_tab + active_record_tab pointers
-- automatically, so this handler is purely "walk + close."
--
-- Filter by project_id: the signal is project-scoped, and the strip is
-- only authoritative for the currently-open project (project_changed
-- resets it).
Signals.connect("sequence_list_changed", function(project_id)
    assert(type(project_id) == "string" and project_id ~= "",
        "timeline_state.sequence_list_changed: emitter must pass non-empty project_id "
        .. "(see core/commands/delete_sequence.lua + create_sequence.lua)")
    if project_id ~= M.get_project_id() then return end

    local strip = M.get_tab_strip()
    if not strip then return end

    local Sequence = require("models.sequence")
    -- Snapshot dead tabs before mutating the list — close_*_tab mutates
    -- strip.tabs in place, so iterating while closing would skip entries.
    local dead = {}
    for _, tab in ipairs(strip.tabs) do
        -- The empty source tab references no sequence, so a sequence
        -- deletion can never orphan it — skip it (Sequence.load(nil) would
        -- assert).
        if not tab:is_empty_source() and not Sequence.load(tab.sequence_id) then
            table.insert(dead, tab)
        end
    end
    for _, tab in ipairs(dead) do
        if tab.kind == "record" then
            strip:close_record_tab(tab)
        elseif tab.kind == "source" then
            strip:close_source_tab()
        else
            error(string.format(
                "timeline_state.sequence_list_changed: unknown tab kind=%q for sequence %s",
                tostring(tab.kind), tostring(tab.sequence_id)))
        end
    end
end, 45)

return M
