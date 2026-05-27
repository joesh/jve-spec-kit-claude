--- Timeline core state: initialization, persistence, reload, and
--- derived-state (gap clip) recomputation for the active sequence.
--
-- Responsibilities:
-- - Load the active sequence from SQLite into the in-memory model
--   (tracks, clips, sequence settings, selection, scroll/zoom state)
-- - Rebuild in-memory gap clips from media clip positions, either
--   for all tracks (init/load) or scoped to a set of affected tracks
--   (after a mutation)
-- - Migrate edge selections when gap clip ids change (the selected
--   edge gets redirected to the nearest new gap on the same track)
-- - Persist pending state to SQLite on sequence switch or app exit
--
-- Non-goals:
-- - Applying mutations to clip positions (that's timeline_state.apply_mutations)
-- - Rendering (views pull from this state, per MVC)
-- - Command execution (goes through command_manager)
--
-- Invariants:
-- - Gap clips are derived state: never mutated directly, always
--   recomputed from media clip positions via gap_lifecycle.
-- - Scoped recompute only touches tracks in the affected set; clips
--   on untouched tracks keep byte-identical ids and positions so
--   edge selections stay valid without migration.
-- - Full recompute (nil affected_track_ids) is required on sequence
--   init/load — there's no baseline gap state to preserve.
--
-- @file timeline_core_state.lua
local M = {}
local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")
local track_state = require("ui.timeline.state.track_state")
local selection_state = require("ui.timeline.state.selection_state")
local db = require("core.database")
local json = require("dkjson")
local ui_constants = require("core.ui_constants")
local command_manager = require("core.command_manager")
local Command = require("command")
local Signals = require("core.signals")
local project_gen = require("core.project_generation")
local strip_holder = require("ui.timeline.state.strip_holder")
local gap_lifecycle = require("core.gap_lifecycle")
local clip_geometry = require("ui.timeline.clip_geometry")
local log = require("core.logger").for_area("timeline")

local persist_timer = nil
local persist_dirty = false
local persist_gen = 0  -- project generation at init time
local PERSIST_DEBOUNCE_MS = ui_constants.TIMELINE.PERSIST_DEBOUNCE_MS or 75

-- Qt timer bridge
local function create_single_shot_timer(delay_ms, callback)
    if type(qt_create_single_shot_timer) == "function" then
        return qt_create_single_shot_timer(delay_ms, callback)
    end
    callback()
    return nil
end

--- Recompute gap clips for all tracks.
-- Strips existing gap clips, recomputes from media clip positions, appends.
-- Partition the current clip list into "kept" (unchanged) and
-- "media_for_scope" (media clips on tracks whose gaps we're rebuilding),
-- and record the destroyed gap ids so we can migrate selections pointing
-- at them. When `scoped` is false every gap is destroyed and every media
-- clip goes into media_for_scope.
local function partition_clips_for_recompute(clips, scoped, affected_track_ids)
    local old_gap_tracks = {}
    local kept = {}
    local media_for_scope = {}
    for _, clip in ipairs(clips) do
        assert(clip.track_id and clip.track_id ~= "",
            string.format("recompute_gap_clips: clip %s missing track_id", tostring(clip.id)))
        local in_scope = (not scoped) or affected_track_ids[clip.track_id]
        if clip.is_gap then
            if in_scope then
                old_gap_tracks[clip.id] = clip.track_id
            else
                table.insert(kept, clip)
            end
        else
            table.insert(kept, clip)
            if in_scope then
                table.insert(media_for_scope, clip)
            end
        end
    end
    return kept, media_for_scope, old_gap_tracks
end

-- Rebuild gap clips for every in-scope track and append them to `clips`.
-- Returns a per-track map of the new gaps so edge-selection migration can
-- find a replacement for any destroyed gap.
local function rebuild_gaps_for_tracks(tracks, track_clips, scoped, affected_track_ids, seq_fr, clips)
    local new_gaps_by_track = {}
    for _, track in ipairs(tracks) do
        assert(track.id and track.id ~= "",
            "recompute_gap_clips: track has empty id")
        if (not scoped) or affected_track_ids[track.id] then
            local sorted = track_clips[track.id] or {}
            local gaps = gap_lifecycle.compute_gaps_for_track(track.id, sorted, seq_fr)
            new_gaps_by_track[track.id] = gaps
            for _, gap in ipairs(gaps) do
                table.insert(clips, gap)
            end
        end
    end
    return new_gaps_by_track
end

-- An edge selection may reference a gap clip that was just destroyed.
-- Redirect it to the nearest new gap on the same track (closest by
-- starting frame, parsed out of the old gap id).
local function migrate_stale_edge_selections(old_gap_tracks, new_gaps_by_track)
    local selected_edges = data.state.selected_edges
    if not selected_edges or #selected_edges == 0 then return end

    local migrated = false
    for _, edge in ipairs(selected_edges) do
        local old_track = old_gap_tracks[edge.clip_id]
        if old_track then
            local new_gaps = new_gaps_by_track[old_track]
            if new_gaps and #new_gaps > 0 then
                -- Old gap id format: gap_<track_id>_<start_frame>
                local old_start = tonumber(edge.clip_id:match("_(%d+)$"))
                local best_gap = new_gaps[1]
                if old_start then
                    local best_dist = math.abs(best_gap.sequence_start - old_start)
                    for _, g in ipairs(new_gaps) do
                        local dist = math.abs(g.sequence_start - old_start)
                        if dist < best_dist then
                            best_gap = g
                            best_dist = dist
                        end
                    end
                end
                edge.clip_id = best_gap.id
                migrated = true
            end
        end
    end
    if migrated then
        log.event("recompute_gap_clips: migrated edge selection to new gap clip IDs")
    end
end

-- Rebuild in-memory gap clips from media clip positions.
--
-- Called after loading clips from DB or after any mutation that changes
-- clip positions. When `affected_track_ids` is nil: rebuild gaps for all
-- tracks (required on sequence init/load). When provided as a set
-- `{[track_id]=true, ...}`: only strip + recompute gaps on those tracks
-- — gaps on other tracks keep their existing IDs and positions, so edge
-- selections pointing at those tracks' gaps stay valid without migration.
-- recompute operates on tab.cache.clips in-place. Selection migration
-- still touches global data.state.selected_edges (selection is cross-tab).

-- Recompute gap clips on a specific tab's cache in-place — preserves
-- cache.clips table identity so any held aliases stay valid. Operates on
-- tab.cache.{clips,tracks,sequence_frame_rate}; the only data.state
-- touch is migrating stale edge selections (cross-tab singleton).
local function recompute_gap_clips_for_tab(tab, affected_track_ids)
    assert(tab, "recompute_gap_clips_for_tab: tab required")
    local cache = tab.cache
    local clips = cache.clips
    local tracks = cache.tracks
    if not clips or not tracks or #tracks == 0 then return end

    local seq_fr = cache.sequence_frame_rate
    if not seq_fr then
        -- An open tab without a frame rate means load_from_database hasn't
        -- run or the sequence row was corrupt. The lifecycle invariant
        -- (1.2) says every tab returned by strip:open_*_tab has populated
        -- cache. Anything else is a bug — fail loud.
        error(string.format(
            "recompute_gap_clips_for_tab: tab %s has no sequence_frame_rate "
            .. "(load_from_database invariant broken)", tostring(tab.sequence_id)))
    end

    local scoped = type(affected_track_ids) == "table"
    local kept, media_for_scope, old_gap_tracks =
        partition_clips_for_recompute(clips, scoped, affected_track_ids)

    -- In-place rewrite: clear cache.clips, refill with kept, then let
    -- rebuild_gaps_for_tracks table.insert new gaps into the same table.
    -- Preserves identity so held aliases keep pointing at the same array.
    for i = #clips, 1, -1 do table.remove(clips, i) end
    for _, c in ipairs(kept) do table.insert(clips, c) end

    local track_clips = clip_geometry.group_and_sort_media_by_track(media_for_scope)
    local new_gaps_by_track =
        rebuild_gaps_for_tracks(tracks, track_clips, scoped, affected_track_ids, seq_fr, clips)
    migrate_stale_edge_selections(old_gap_tracks, new_gaps_by_track)
    cache.content_length = clip_geometry.compute_content_length(clips)
    tab:invalidate_indexes()
end

-- Whole-displayed-tab recompute. Resolves displayed tab and delegates
-- to recompute_gap_clips_for_tab.
local function recompute_gap_clips(affected_track_ids)
    local strip = strip_holder.get()
    if not strip then return end
    local displayed = strip:get_displayed()
    if not displayed then return end
    recompute_gap_clips_for_tab(displayed, affected_track_ids)
end

local TRACK_HEIGHT_TEMPLATE_KEY = "track_height_template"

local function clamp_track_height(height)
    if type(height) ~= "number" then return nil end
    local clamped = math.floor(height)
    if clamped < 24 then clamped = 24 end
    return clamped
end

-- Read tracks from the displayed tab cache; empty when no tab displayed.
local function displayed_tracks_or_empty()
    local strip = strip_holder.get()
    if not strip then return {} end
    local displayed = strip:get_displayed()
    if not displayed then return {} end
    return displayed.cache.tracks
end

local function build_track_height_map()
    local result = {}
    for _, track in ipairs(displayed_tracks_or_empty()) do
        if track.id and track.id ~= "" then
            result[track.id] = clamp_track_height(track.height or data.dimensions.default_track_height)
        end
    end
    return result
end

local function build_track_height_template()
    local tracks = displayed_tracks_or_empty()
    if #tracks == 0 then return nil end
    local template = { video = {}, audio = {} }
    for _, track in ipairs(tracks) do
        local normalized = clamp_track_height(track.height or data.dimensions.default_track_height)
        if track.track_type == "VIDEO" then
            table.insert(template.video, normalized)
        elseif track.track_type == "AUDIO" then
            table.insert(template.audio, normalized)
        end
    end
    return template
end

local function flush_state_to_db()
    -- View-state encapsulation (FR-005, FR-007): playhead, viewport, scroll,
    -- selection, marks live in data.state but BELONG to the displayed
    -- sequence (the displayed tab), NOT the active edit target. Persistence
    -- writes to displayed_tab_id's DB row. When source tab is displayed,
    -- the active record's row is untouched by viewport/playhead changes
    -- the user makes while viewing source.
    --
    -- No-displayed state (post-core.clear): the strip carries no displayed
    -- tab — there is no DB row to write per-sequence view-state to.
    -- Persistence is gated on the displayed pointer (the strip is the
    -- canonical "is anything displayed?" property of the model). A
    -- selection-mutating command that fires while the timeline is blank
    -- (e.g. DeselectAll after ShowSourceTab's no-master branch) must
    -- silently no-op here, not crash.
    local sequence_id = strip_holder.displayed_sequence_id()
    if not sequence_id or sequence_id == "" then return end

    -- Symmetric to the displayed gate: no project_id → no DB row to
    -- write to (tests that drive core.activate_displayed directly,
    -- without going through timeline_state.init, leave project_id nil).
    -- The active_project check below also catches this, but gating up
    -- front avoids a stale command_manager state read.
    local project_id = data.state.project_id
    if not project_id or project_id == "" then return end

    -- Skip persistence if command_manager is not initialized or undo/redo is in progress.
    -- This prevents recursive command execution during undo/redo operations and allows
    -- tests that don't initialize command_manager to still use timeline_state.
    local active_project = command_manager.get_active_project_id and command_manager.get_active_project_id()
    if not active_project or active_project == "" then
        return
    end
    if command_manager.is_undo_redo_in_progress and command_manager.is_undo_redo_in_progress() then
        return
    end

    -- Skip persistence if the sequence no longer exists in the database.
    -- This can happen after undo of an import - timeline_state has stale cached values
    -- for a deleted sequence. Persisting those would overwrite correct values when
    -- the sequence is recreated by redo.
    local Sequence = require("models.sequence")
    local sequence = Sequence.load(sequence_id)
    if not sequence then
        return
    end

    -- Begin command event context for UI-driven persistence.
    -- All persistence commands below are non-undoable "scriptable" commands,
    -- but they still require an active command event to execute.
    command_manager.begin_command_event("ui")

    -- Use pcall to ensure we always end the command event even if commands fail
    local ok, err = pcall(function()
        -- Persist playhead
    local playhead_cmd = Command.create("SetPlayhead", project_id)
    playhead_cmd:set_parameters({
        project_id = project_id,
        sequence_id = sequence_id,
        playhead_position = data.state.playhead_position,
    })
    command_manager.execute(playhead_cmd)

    -- Persist viewport (scroll offsets handled separately by persist_scroll_offsets)
    local viewport_cmd = Command.create("SetViewport", project_id)
    viewport_cmd:set_parameters({
        project_id = project_id,
        sequence_id = sequence_id,
        viewport_start_time = data.state.viewport_start_time,
        viewport_duration = data.state.viewport_duration,
        video_audio_split_ratio = data.state.video_audio_split_ratio,
    })
    command_manager.execute(viewport_cmd)

    -- Marks: persisted via undoable mark commands, not flush

    -- Serialize and persist selection
    local selected_ids = {}
    for _, clip in ipairs(data.state.selected_clips) do
        table.insert(selected_ids, clip.id)
    end
    local success, json_str = pcall(json.encode, selected_ids)
    local selected_clip_ids_json = success and json_str or "[]"

    local edge_descriptors = {}
    for _, edge in ipairs(data.state.selected_edges) do
        if edge and edge.clip_id and edge.edge_type then
            -- Gap-edge selections persist via the gap's deterministic id
            -- (`gap_<track_id>_<sequence_start>`). On restore, gaps are
            -- recomputed BEFORE selection restore in `load_displayed_sequence`,
            -- so gap_id at restore-time matches gap_id at save-time as long
            -- as the surrounding clips haven't moved. Previously this loop
            -- filtered out gap edges entirely on the "gap clips are in-memory
            -- only" theory, which silently broke roll selections crossing a
            -- gap boundary (TSO 2026-05-20: roll `][` restored as ripple `[`).
            -- Real-clip and gap-clip edges share the same restore path; the
            -- save side should mirror that.
            table.insert(edge_descriptors, {
                clip_id = edge.clip_id,
                edge_type = edge.edge_type,
                trim_type = edge.trim_type
            })
        end
    end
    local success_edges, edges_json = pcall(json.encode, edge_descriptors)
    local selected_edge_infos_json = success_edges and edges_json or "[]"

    local selection_cmd = Command.create("SetSelection", project_id)
    selection_cmd:set_parameters({
        project_id = project_id,
        sequence_id = sequence_id,
        selected_clip_ids_json = selected_clip_ids_json,
        selected_edge_infos_json = selected_edge_infos_json,
    })
    command_manager.execute(selection_cmd)

    if track_state.is_layout_dirty() then
        local height_map = build_track_height_map()

        -- Persist track heights via command (scriptable, non-undoable)
        local heights_cmd = Command.create("SetTrackHeights", project_id)
        heights_cmd:set_parameter("project_id", project_id)
        heights_cmd:set_parameter("sequence_id", sequence_id)
        heights_cmd:set_parameter("track_heights", height_map)
        command_manager.execute(heights_cmd)

        -- Template persistence via command
        local template = build_track_height_template()
        if template then
            local template_cmd = Command.create("SetProjectSetting", project_id)
            template_cmd:set_parameter("project_id", project_id)
            template_cmd:set_parameter("key", TRACK_HEIGHT_TEMPLATE_KEY)
            template_cmd:set_parameter("value", template)
            command_manager.execute(template_cmd)
        end

        track_state.clear_layout_dirty()
    end
    end) -- end pcall

    -- Always end the command event, even if persistence failed
    command_manager.end_command_event()

    -- Re-raise any error that occurred during persistence
    if not ok then
        error(err)
    end
end

local function schedule_state_persist(immediate)
    persist_dirty = true
    if immediate then
        persist_dirty = false
        flush_state_to_db()
        return
    end
    if persist_timer then return end
    local gen = persist_gen
    persist_timer = create_single_shot_timer(PERSIST_DEBOUNCE_MS, function()
        persist_timer = nil
        if not persist_dirty then return end
        if gen ~= project_gen.current() then return end  -- project changed since scheduled
        persist_dirty = false
        flush_state_to_db()
    end)
end

function M.persist_state_to_db(force)
    -- Gate at the public boundary: no displayed tab → nothing to persist
    -- (matches flush_state_to_db's gate; avoids scheduling a debounce timer
    -- whose fire-time would also no-op, and avoids surprising callers from
    -- selection / viewport paths after core.clear).
    if not strip_holder.displayed_sequence_id() then return end
    if force == true then
        schedule_state_persist(true)
    else
        schedule_state_persist(false)
    end
end

-- Thin sync step: the tab IS the model (cache populated by
-- tab:load_from_database when the strip opens it; signal handlers +
-- apply_mutations keep it fresh). This mirrors the per-sequence
-- view-state fields (frame_rate, tc origin, viewport, scroll, playhead)
-- into data.state for the displayed-singleton readers, restores
-- selection (global, not per-tab), and runs viewport-fit.
local function load_displayed_sequence(seq_id)
    assert(seq_id and seq_id ~= "",
        "load_displayed_sequence: seq_id required")

    local strip = strip_holder.get()
    assert(strip, "load_displayed_sequence: no strip set")
    local tab = strip:get_displayed()
    assert(tab and tab.sequence_id == seq_id, string.format(
        "load_displayed_sequence: strip displayed=%s, expected=%s — "
        .. "caller must update the strip pointer BEFORE calling this",
        tab and tab.sequence_id or "nil", tostring(seq_id)))

    -- Do NOT re-hydrate here — the strip's open hooks already called
    -- tab:load_from_database, and signal handlers keep it fresh.
    -- Skipping the redundant load is the tab-switch perf win.
    local sequence = require("models.sequence").load(seq_id)
    assert(sequence, string.format(
        "load_displayed_sequence: failed to load seq_id=%s", tostring(seq_id)))

    -- Mirror per-sequence view-state into data.state; clip/track data
    -- lives only on tab.cache.
    data.state.sequence_frame_rate = tab.cache.sequence_frame_rate
    data.state.sequence_timecode_start_frame = tab.cache.sequence_timecode_start_frame
    data.sequence = sequence

    data.state.playhead_position = tab.cache.playhead_position
    data.state.video_scroll_offset = tab.cache.video_scroll_offset
    data.state.audio_scroll_offset = tab.cache.audio_scroll_offset
    data.state.video_audio_split_ratio = tab.cache.video_audio_split_ratio

    -- Selection restore (cross-cutting; lives on data.state). Resolve clip
    -- objects via clip_state which now reads from the displayed tab cache.
    data.state.selected_clips = {}
    if sequence.selected_clip_ids_json and sequence.selected_clip_ids_json ~= "" then
        local ok, ids = pcall(json.decode, sequence.selected_clip_ids_json)
        if ok and type(ids) == "table" then
            for _, cid in ipairs(ids) do
                local clip = clip_state.get_by_id(cid)
                if clip then table.insert(data.state.selected_clips, clip) end
            end
        end
    end

    data.state.selected_edges = {}
    if sequence.selected_edge_infos_json and sequence.selected_edge_infos_json ~= "" then
        local ok, edges = pcall(json.decode, sequence.selected_edge_infos_json)
        if ok and type(edges) == "table" then
            for _, edge in ipairs(edges) do
                if type(edge) == "table" and edge.clip_id and edge.edge_type then
                    local clip_obj = clip_state.get_by_id(edge.clip_id)
                    if clip_obj then
                        table.insert(data.state.selected_edges, {
                            clip_id = edge.clip_id,
                            edge_type = edge.edge_type,
                            trim_type = edge.trim_type
                        })
                    end
                end
            end
            if #data.state.selected_edges > 0 then data.state.selected_clips = {} end
        end
    end

    data.state.viewport_start_time = tab.cache.viewport_start_time
    data.state.viewport_duration = tab.cache.viewport_duration

    -- Resilience: snap the viewport to fit content when the persisted
    -- viewport would render unusably. Two failure modes covered:
    --   1. No intersection with any media clip — e.g. a master whose
    --      template default viewport (0,300) doesn't reach the file's
    --      TC origin (often millions of frames in for camera-original
    --      media). Without this the source tab shows nothing.
    --   2. Intersection but the viewport is grossly wider than content —
    --      real DBs have ended up with view_duration_frames in the
    --      billions, which technically intersects the content but
    --      renders it as a single pixel. Equally unusable.
    local VIEWPORT_OVERSIZE_RATIO = 100

    local function content_bounds()
        local min_start, max_end
        for _, c in ipairs(tab.cache.clips) do
            if not c.is_gap and c.sequence_start and c.duration then
                local s, e = c.sequence_start, c.sequence_start + c.duration
                if not min_start or s < min_start then min_start = s end
                if not max_end or e > max_end then max_end = e end
            end
        end
        return min_start, max_end
    end

    local function viewport_needs_fit(min_start, max_end)
        local vs = data.state.viewport_start_time
        local vd = data.state.viewport_duration
        if not vs or not vd or vd <= 0 then return true end
        if not min_start or not max_end or max_end <= min_start then return false end
        local ve = vs + vd
        local intersects = (min_start < ve and max_end > vs)
        if not intersects then return true end
        local content_extent = max_end - min_start
        return vd > content_extent * VIEWPORT_OVERSIZE_RATIO
    end

    local min_start, max_end = content_bounds()
    if viewport_needs_fit(min_start, max_end) and min_start and max_end and max_end > min_start then
        assert(type(data.state.sequence_timecode_start_frame) == "number",
            "viewport-fit: sequence_timecode_start_frame not initialised — "
            .. "load_displayed_sequence must run before viewport fit")
        local fit_start, fit_duration = ui_constants.compute_zoom_to_fit(
            min_start, max_end, data.state.sequence_timecode_start_frame)
        data.state.viewport_start_time = fit_start
        data.state.viewport_duration = fit_duration
        tab.cache.viewport_start_time = fit_start
        tab.cache.viewport_duration = fit_duration
    end

    -- Persist track-height template for sequences without saved heights.
    -- tab:load_from_database already applied saved-or-default heights;
    -- this branch backfills the template when the sequence has none.
    if db.load_sequence_track_heights and db.set_sequence_track_heights then
        local saved = db.load_sequence_track_heights(seq_id)
        local has_saved = type(saved) == "table" and next(saved) ~= nil
        if not has_saved then
            db.set_sequence_track_heights(seq_id, build_track_height_map())
        end
    end
end

function M.init(sequence_id, project_id)
    -- Persist pending state before switching to a DIFFERENT sequence.
    -- Skip persist if re-initializing the SAME sequence - our cached values may be stale
    -- (e.g., after undo deleted the sequence and redo recreated it with fresh values).
    local prev_active = data.state.sequence_id
    local is_same_sequence = prev_active == sequence_id
    if not is_same_sequence then
        -- Scroll offsets are persisted by load_sequence BEFORE init (while Qt
        -- scroll areas still have correct content/range for the outgoing sequence)
        if persist_dirty then
            M.persist_state_to_db(true)
        end
    end
    persist_dirty = false

    assert(sequence_id and sequence_id ~= "", "timeline_core_state.init: sequence_id is required")
    persist_gen = project_gen.current()
    data.state.sequence_id = sequence_id  -- active edit target

    load_displayed_sequence(sequence_id)  -- sets displayed_tab_id, loads tracks/clips + view-state

    -- project_id consistency check (sequence model loaded inside load_displayed_sequence)
    local sequence = data.sequence
    if project_id and project_id ~= "" then
        assert(sequence.project_id == project_id, string.format(
            "timeline_core_state.init: provided project_id does not match sequence.project_id (sequence_id=%s, provided=%s, db=%s)",
            tostring(sequence_id), tostring(project_id), tostring(sequence.project_id)
        ))
    end
    data.state.project_id = sequence.project_id

    if prev_active ~= sequence_id then
        Signals.emit("active_sequence_changed", sequence_id, prev_active)
    end
    data.notify_listeners()
    return true
end

--- Swap which sequence the timeline view displays. Persists outgoing
--- displayed view-state (writes to old displayed_tab_id's DB row), loads
--- the incoming sequence's tracks/clips + view-state, and emits displayed_tab_changed
--- so view-layer listeners rebuild widgets. Does NOT touch active edit
--- target (FR-005). Idempotent — no-op when already on `seq_id`.
--- Swap the displayed sequence. `prev_seq_id` MUST be the strip's current
--- displayed sequence_id as observed BEFORE the caller (timeline_state's
--- public wrapper) swaps the strip pointer. Passing it in eliminates
--- core_state's parallel `data.state.displayed_tab_id` tracking — the
--- strip is the sole external store.
function M.activate_displayed(seq_id, prev_seq_id)
    assert(seq_id and seq_id ~= "",
        "timeline_core_state.activate_displayed: seq_id required")
    assert(prev_seq_id == nil
           or (type(prev_seq_id) == "string" and prev_seq_id ~= ""),
        "timeline_core_state.activate_displayed: prev_seq_id must be string or nil")
    if prev_seq_id == seq_id then return false end

    -- Outgoing view-state flush is the WRAPPER's responsibility (it runs
    -- BEFORE the strip pointer is swapped, so persist resolves the
    -- correct row). By the time this fires the strip already points at
    -- seq_id; flushing here would write outgoing data.state values to
    -- the incoming row. Drop any leftover dirty bit — the wrapper either
    -- flushed it or there was nothing to flush.
    persist_dirty = false

    load_displayed_sequence(seq_id)
    Signals.emit("displayed_tab_changed", seq_id, prev_seq_id)
    data.notify_listeners()
    return true
end

--- Enter the no-displayed-tab state: drop the active-sequence reference
--- and all per-sequence data. The project identity (data.state.project_id)
--- is untouched — the editor stays inside the current project; only the
--- timeline becomes blank. Views pull get_sequence_id() == nil and render
--- blank of their own accord (MVC).
---
--- `prev_displayed_seq_id` MUST be the strip's outgoing displayed sequence
--- id (captured by the caller before the strip pointer was cleared), or
--- nil when there was no displayed tab to begin with. Passed in (not
--- queried) because the public wrapper clears the strip pointer first —
--- by the time we run, strip_holder reports nil regardless.
---
--- Idempotent: if `prev_displayed_seq_id == nil`, no transition occurred
--- and the `displayed_tab_cleared` signal is NOT emitted (avoids spurious
--- stop-playback / cancel-seek work on subscribers).
function M.clear(prev_displayed_seq_id)
    assert(prev_displayed_seq_id == nil
        or (type(prev_displayed_seq_id) == "string" and prev_displayed_seq_id ~= ""),
        "timeline_core_state.clear: prev_displayed_seq_id must be a non-empty string or nil")

    -- Outgoing view-state flush is the WRAPPER's responsibility (it runs
    -- BEFORE the strip is cleared, while persist can still resolve the
    -- row). By the time this fires the strip is already cleared and
    -- there is no row to flush to; drop the dirty bit.
    persist_dirty = false

    data.state.sequence_id = nil
    -- Tracks/clips live on tab caches; the strip's clear_displayed (run
    -- before us) already detached the displayed pointer, so reads return
    -- empty automatically.
    data.state.selected_clips = {}
    data.state.selected_edges = {}
    data.state.selected_gaps = {}

    data.state.dragging_playhead = false
    data.state.dragging_clip = nil
    data.state.drag_selecting = false
    data.state.active_edge_drag_state = nil

    data.state.playhead_position = 0
    data.state.is_playing = false

    clip_state.invalidate_indexes()
    data.notify_listeners()

    -- Announce the no-displayed transition AFTER model fields are nilled so
    -- subscribers (playback engine stops the engine that was transporting
    -- the closed sequence; pending viewer-seek timers cancel their stale
    -- targets) see the fully-cleared model when they pull. Skip on the
    -- idempotent path: no transition → no notification.
    if prev_displayed_seq_id then
        Signals.emit("displayed_tab_cleared", prev_displayed_seq_id)
    end
end

--- Full timeline-model reset for a project change. Unlike clear() — which
--- stays inside the current project and only releases the active sequence —
--- this drops project identity too and wipes viewport/scroll/rate state so
--- nothing from the outgoing project bleeds into the new one. Does NOT
--- persist pending state: by the time project_changed fires, the database
--- connection has already been swapped to the new project (project_open
--- calls db.set_path before post_open_init), so a flush here would write
--- outgoing state into the incoming project's DB. Runs at priority 40 —
--- project_gen bumped already at priority 1, so current() here stamps
--- the new generation.
function M.reset_for_project_change()
    persist_dirty = false
    persist_timer = nil
    data.reset_state_preserve_listeners()
    persist_gen = project_gen.current()
    clip_state.invalidate_indexes()
    data.notify_listeners()
end

--- Set the project identity without touching the sequence reference. Used by
--- timeline_panel.create() when opening a project in the no-active-sequence
--- state (no initial tab). Complements init(seq, pid) for the
--- project-only-is-known case.
function M.set_project_id(project_id)
    assert(project_id and project_id ~= "",
        "timeline_core_state.set_project_id: project_id required")
    data.state.project_id = project_id
    persist_gen = project_gen.current()
end

function M.reload_clips(target_sequence_id, opts)
    -- The clip cache reflects the DISPLAYED sequence (FR-005, FR-007 — the
    -- view pulls from displayed_tab_id, edits target active). When edits
    -- on the active sequence call reload_clips(active) and the source tab
    -- is currently displayed, the request is for a different sequence than
    -- what the timeline view shows; we return false (timeline view unchanged). Once the user
    -- switches back to the active record tab, displayed_tab_changed fires
    -- and rebuild_for_displayed_tab reloads at that point.
    local displayed = strip_holder.displayed_sequence_id()
    assert(displayed and displayed ~= "",
        "timeline_core_state.reload_clips: no displayed tab on strip")
    if target_sequence_id and target_sequence_id ~= "" and target_sequence_id ~= displayed then
        if opts and opts.allow_sequence_switch then
            local project_id = data.state.project_id
            assert(project_id and project_id ~= "", "timeline_core_state.reload_clips: missing active project_id")
            return M.init(target_sequence_id, project_id)
        end
        return false
    end

    -- Tab is the model — re-hydrate the displayed tab's cache from DB
    -- (load_from_database recomputes gaps inline).
    local strip = strip_holder.get()
    assert(strip, "reload_clips: no strip set")
    local displayed_tab = strip:get_displayed()
    assert(displayed_tab and displayed_tab.sequence_id == displayed,
        "reload_clips: displayed tab does not match the displayed_sequence_id")
    displayed_tab:load_from_database()
    clip_state.invalidate_indexes()

    -- Refresh selection objects so anyone holding the stale clip pointers
    -- (renderer, inspectable caches) gets the freshly-loaded rows.
    if #data.state.selected_clips > 0 then
        local refreshed = {}
        for _, c in ipairs(data.state.selected_clips) do
            local latest = clip_state.get_by_id(c.id)
            if latest then table.insert(refreshed, latest) end
        end
        data.state.selected_clips = refreshed
    end

    clip_state.inc_version()
    for _, c in ipairs(displayed_tab.cache.clips) do c._version = clip_state.get_version() end

    local adjusted = selection_state.normalize_edge_selection()
    if adjusted then M.persist_state_to_db() end
    data.notify_listeners()
    Signals.emit("timeline_clips_reloaded", displayed)
    return true
end

-- Re-read marks from DB when a mark command executes (or undoes)
Signals.connect("marks_changed", function(sequence_id)
    if data.sequence and data.state.sequence_id == sequence_id then
        local Sequence = require("models.sequence")
        local fresh = Sequence.load(sequence_id)
        assert(fresh, string.format(
            "timeline_core_state: marks_changed: failed to reload active sequence_id=%s",
            tostring(sequence_id)))
        data.sequence.mark_in  = fresh.mark_in
        data.sequence.mark_out = fresh.mark_out
    end
    -- Strip-authoritative (015 #6): the SourceTab branch used to refresh a
    -- parallel data.source_sequence cache. That cache is gone — readers
    -- (ruler, scrollbar, view_renderer) pull through
    -- timeline_state.get_display_mark_in/out → tab_strip:get_displayed() →
    -- Sequence.load. So notification must fire UNCONDITIONALLY: source-tab
    -- mark changes don't touch data.state.sequence_id (the active record)
    -- but the displayed-tab ruler still needs to re-render.
    data.notify_listeners()
end)

-- Source-loaded notification: rerender on load/unload. Strip-authoritative
-- (015 #6) — no longer caches a Sequence row; readers pull fresh via
-- tab_strip:get_source_tab() then Sequence.load (≈21µs per call).
Signals.connect("source_loaded_changed", function(_new_seq_id, _prev_seq_id)
    data.notify_listeners()
end)

-- Spec 022 / 1.4: signal handlers dispatch to all open tabs in the strip,
-- not just the displayed one. Non-displayed tabs' caches must stay
-- current so the user sees correct state when they switch.
local function for_each_tab(fn)
    local strip = strip_holder.get()
    if not strip then return end
    for _, tab in ipairs(strip.tabs) do fn(tab) end
end

-- Sync the in-memory track row when ToggleTrackPreference flips muted /
-- soloed / locked / enabled. ToggleTrackPreference mutates a freshly-
-- loaded Track instance and writes the DB column; without this sync the
-- displayed view's visual state would only flip on next sequence load.
-- Signal value is INTEGER 0/1; cache.tracks stores booleans.
Signals.connect("track_preference_changed", function(track_id, property, new_val)
    assert(type(track_id) == "string" and track_id ~= "",
        "track_preference_changed listener: track_id must be a non-empty string")
    assert(type(property) == "string" and property ~= "",
        "track_preference_changed listener: property must be a non-empty string")
    assert(new_val == 0 or new_val == 1, string.format(
        "track_preference_changed listener: new_val must be 0 or 1; got %s",
        tostring(new_val)))
    local val = (new_val == 1)
    -- Walk every open tab's cache.tracks; notify the displayed view
    -- when its track set was touched.
    local strip = strip_holder.get()
    local displayed_tab = strip and strip:get_displayed() or nil
    local displayed_touched = false
    for_each_tab(function(tab)
        if tab.cache.tracks then
            for _, t in ipairs(tab.cache.tracks) do
                if t.id == track_id then
                    t[property] = val
                    if tab == displayed_tab then displayed_touched = true end
                    break
                end
            end
        end
    end)
    if displayed_touched then data.notify_listeners() end
end)

-- Update playhead when SetPlayhead command fires. SetPlayhead writes
-- per-sequence; mirror to each tab's cache so the playhead is correct
-- when the user switches between tabs, and to data.state when the target
-- IS displayed (the displayed-singleton view-state mirror).
Signals.connect("playhead_changed", function(sequence_id, frame)
    if type(frame) ~= "number" then return end
    for_each_tab(function(tab)
        if tab.sequence_id == sequence_id then
            tab.cache.playhead_position = frame
        end
    end)
    if strip_holder.displayed_sequence_id() == sequence_id then
        data.state.playhead_position = frame
        data.notify_listeners()
    end
end)

-- Reactive media status: when a media file changes status (online/offline/codec),
-- update clips referencing that path on ALL open tabs and trigger re-render.
-- Offline state is media-wide (a media file is offline for every clip across
-- every open sequence), not display-state — so we walk every tab.
Signals.connect("media_status_changed", function(media_path, status)
    local function update_clips_for_media(clips_list)
        if not clips_list then return false end
        local touched = false
        for _, clip in ipairs(clips_list) do
            if clip.media_path == media_path then
                clip.offline = status.offline
                clip.error_code = status.error_code
                touched = true
            end
        end
        return touched
    end

    -- Walk every open tab's cache.clips; track whether the displayed
    -- tab's set was touched (drives version stamp + notify).
    local strip = strip_holder.get()
    local displayed_tab = strip and strip:get_displayed() or nil
    local displayed_changed = false
    for_each_tab(function(tab)
        if update_clips_for_media(tab.cache.clips) and tab == displayed_tab then
            displayed_changed = true
        end
    end)

    if displayed_changed and displayed_tab then
        clip_state.inc_version()
        local v = clip_state.get_version()
        for _, c in ipairs(displayed_tab.cache.clips) do c._version = v end
        data.notify_listeners()
    end
end)

-- Reactive media change: when media records are modified (e.g. relink),
-- reload clips from DB so cached file_path/offline state is refreshed.
Signals.connect("media_changed", function(_changed_media_ids)
    -- The clip cache reflects the DISPLAYED sequence (FR-005, FR-007).
    -- Reload against displayed so the visible view picks up new media paths.
    local displayed = strip_holder.displayed_sequence_id()
    if not displayed or displayed == "" then return end
    M.reload_clips(displayed)
    -- Propagate to playback engine so TMB re-fetches clips with updated media paths
    Signals.emit("content_changed", displayed)
end)

M.recompute_gap_clips = recompute_gap_clips
M.recompute_gap_clips_for_tab = recompute_gap_clips_for_tab

return M
