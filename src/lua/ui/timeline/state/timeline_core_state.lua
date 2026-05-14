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

-- Group media clips by track_id and sort each track's list by timeline_start
-- (ties broken by clip id for determinism).
local function build_sorted_track_media(media_clips)
    local track_clips = {}
    for _, clip in ipairs(media_clips) do
        local list = track_clips[clip.track_id]
        if not list then
            list = {}
            track_clips[clip.track_id] = list
        end
        table.insert(list, clip)
    end
    for _, list in pairs(track_clips) do
        table.sort(list, function(a, b)
            if a.timeline_start == b.timeline_start then
                return a.id < b.id
            end
            return a.timeline_start < b.timeline_start
        end)
    end
    return track_clips
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
                    local best_dist = math.abs(best_gap.timeline_start - old_start)
                    for _, g in ipairs(new_gaps) do
                        local dist = math.abs(g.timeline_start - old_start)
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
local function recompute_gap_clips(affected_track_ids)
    local clips = data.state.clips
    local tracks = data.state.tracks
    if not clips or not tracks or #tracks == 0 then return end

    local seq_fr = data.state.sequence_frame_rate
    -- sequence_frame_rate may not be set during early init before sequence load.
    -- Only assert when we have an active sequence — otherwise silent skip is correct.
    if not seq_fr then
        assert(not data.state.sequence_id or data.state.sequence_id == "",
            "recompute_gap_clips: sequence_frame_rate is nil but sequence_id is set")
        return
    end

    local scoped = type(affected_track_ids) == "table"
    local kept, media_for_scope, old_gap_tracks =
        partition_clips_for_recompute(clips, scoped, affected_track_ids)
    -- Assign the kept set first; rebuild_gaps_for_tracks then table.inserts
    -- gap rows into the same table in place, so we refresh the cached
    -- content_length AFTER both have run.
    data.state.clips = kept

    local track_clips = build_sorted_track_media(media_for_scope)
    local new_gaps_by_track =
        rebuild_gaps_for_tracks(tracks, track_clips, scoped, affected_track_ids, seq_fr, kept)
    migrate_stale_edge_selections(old_gap_tracks, new_gaps_by_track)
    data.update_content_length()
end

local TRACK_HEIGHT_TEMPLATE_KEY = "track_height_template"

local function clamp_track_height(height)
    if type(height) ~= "number" then return nil end
    local clamped = math.floor(height)
    if clamped < 24 then clamped = 24 end
    return clamped
end

local function build_track_height_map()
    local result = {}
    for _, track in ipairs(data.state.tracks) do
        if track.id and track.id ~= "" then
            result[track.id] = clamp_track_height(track.height or data.dimensions.default_track_height)
        end
    end
    return result
end

local function build_track_height_template()
    if not data.state.tracks or #data.state.tracks == 0 then return nil end
    local template = { video = {}, audio = {} }
    for _, track in ipairs(data.state.tracks) do
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
    local sequence_id = strip_holder.displayed_sequence_id()
    assert(sequence_id and sequence_id ~= "",
        "timeline_core_state.flush_state_to_db: no displayed tab on strip")

    local project_id = data.state.project_id
    assert(project_id and project_id ~= "", "timeline_core_state.flush_state_to_db: missing project_id")

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
            -- Skip gap clip edges — gap clips are in-memory only, not persisted
            if type(edge.clip_id) == "string" and edge.clip_id:find("^gap_") then
                goto continue_edge_persist
            end
            table.insert(edge_descriptors, {
                clip_id = edge.clip_id,
                edge_type = edge.edge_type,
                trim_type = edge.trim_type
            })
            ::continue_edge_persist::
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
    if force == true then
        schedule_state_persist(true)
    else
        schedule_state_persist(false)
    end
end

--- Load tracks, clips, and view-state for `seq_id` into data.state and set
--- displayed_tab_id = seq_id. Reads tracks, clips, and the per-sequence
--- view fields (playhead, viewport, scroll, selection, marks, track
--- heights, frame_rate). Does NOT touch data.state.sequence_id (the
--- active edit target) or data.state.project_id — those are set only
--- by M.init and managed separately from the displayed pointer (FR-005).
local function load_displayed_sequence(seq_id)
    assert(seq_id and seq_id ~= "",
        "load_displayed_sequence: seq_id required")
    -- Strip-authoritative (015 #6): the strip is the canonical store for
    -- "which tab is displayed". Caller (timeline_state) has already
    -- updated the strip pointer; we just load the sequence's view-state
    -- into data.state below.

    local Sequence = require("models.sequence")
    local sequence = Sequence.load(seq_id)
    assert(sequence, string.format(
        "load_displayed_sequence: failed to load seq_id=%s", tostring(seq_id)))

    -- Validate every required field BEFORE any state mutation so a failed
    -- invariant doesn't leave data.state half-rewritten (rule 1.14).
    assert(sequence.project_id and sequence.project_id ~= "",
        string.format("load_displayed_sequence: sequence missing project_id (seq_id=%s)", tostring(seq_id)))
    assert(type(sequence.frame_rate) == "table",
        string.format("load_displayed_sequence: sequence %s missing frame_rate table", tostring(seq_id)))
    assert(sequence.frame_rate.fps_numerator and sequence.frame_rate.fps_denominator,
        string.format("FATAL: Sequence %s has NULL frame rate in database", tostring(seq_id)))
    assert(type(sequence.start_timecode_frame) == "number", string.format(
        "load_displayed_sequence: sequence %s missing start_timecode_frame "
        .. "(schema declares NOT NULL DEFAULT 0; Sequence.load asserts non-null — "
        .. "if this fires, a caller bypassed both invariants)", tostring(seq_id)))

    data.state.tracks = db.load_tracks(seq_id)
    -- Body content source depends on sequence kind:
    --   nested → real clips rows
    --   master → synthesized virtual clips from media_refs (FR-007 source-tab content)
    if sequence:is_master() then
        data.set_clips(db.load_master_virtual_clips(seq_id))
    else
        data.set_clips(db.load_clips(seq_id))
    end
    clip_state.invalidate_indexes()

    data.state.sequence_frame_rate = sequence.frame_rate
    data.state.sequence_timecode_start_frame = sequence.start_timecode_frame
    data.sequence = sequence

    recompute_gap_clips()
    clip_state.invalidate_indexes()

    data.state.playhead_position = sequence.playhead_position
    data.state.video_scroll_offset = sequence.video_scroll_offset or 0
    data.state.audio_scroll_offset = sequence.audio_scroll_offset or 0
    data.state.video_audio_split_ratio = sequence.video_audio_split_ratio or 0.5

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

    data.state.viewport_start_time = sequence.viewport_start_time
    data.state.viewport_duration = sequence.viewport_duration

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
    local VIEWPORT_OVERSIZE_RATIO = 100   -- vd > content_extent * 100 ⇒ snap to fit

    local function content_bounds()
        local min_start, max_end
        for _, c in ipairs(data.state.clips) do
            if not c.is_gap and c.timeline_start and c.duration then
                local s, e = c.timeline_start, c.timeline_start + c.duration
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
        -- Do NOT touch the playhead — viewport-fit is purely a view
        -- adjustment. Moving the playhead on every activation snaps
        -- the user away from where they were last parked.
    end

    for _, track in ipairs(data.state.tracks) do
        track.height = data.dimensions.default_track_height
    end
    if db.load_sequence_track_heights then
        local saved = db.load_sequence_track_heights(seq_id)
        local has_saved = type(saved) == "table" and next(saved) ~= nil
        if has_saved then
            for _, track in ipairs(data.state.tracks) do
                local h = saved[track.id]
                if h then track.height = clamp_track_height(h) end
            end
        elseif db.set_sequence_track_heights then
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

    -- Flush outgoing displayed view-state BEFORE swap so persistence
    -- writes to the OLD displayed sequence's row.
    if persist_dirty and prev_seq_id then
        M.persist_state_to_db(true)
    end
    persist_dirty = false

    load_displayed_sequence(seq_id)
    Signals.emit("displayed_tab_changed", seq_id, prev_seq_id)
    data.notify_listeners()
    return true
end

--- Enter the no-active-sequence state: drop the active-sequence reference
--- and all per-sequence data. The project identity (data.state.project_id)
--- is untouched — the editor stays inside the current project; only the
--- timeline becomes blank. Views pull get_sequence_id() == nil and render
--- blank of their own accord (MVC). Idempotent.
function M.clear()
    -- Persist pending per-sequence state BEFORE tearing it down so unsaved
    -- viewport/scroll/selection aren't lost on the round-trip.
    if persist_dirty then
        M.persist_state_to_db(true)
        persist_dirty = false
    end

    data.state.sequence_id = nil
    data.state.tracks = {}
    data.set_clips({})

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

    -- recompute_gap_clips will table.insert gaps into this list and
    -- refresh content_length itself; raw assignment is fine here since
    -- the cache is brought into sync by the recompute call below.
    data.state.clips = db.load_clips(displayed)
    recompute_gap_clips()
    clip_state.invalidate_indexes()

    -- Refresh selection objects so anyone holding the stale clip pointers
    -- (renderer, inspectable caches) gets the freshly-loaded rows. We
    -- intentionally do NOT re-fire the on_selection_changed callback —
    -- the Inspector already re-pulls via the content_changed signal
    -- (see ui/inspector/change_listeners.lua), and an extra selection
    -- emit during a mutation-driven reload was empirically (TSO
    -- 2026-04-21) breaking downstream because earlier code nil'd the
    -- callback here, silencing every subsequent user selection click.
    if #data.state.selected_clips > 0 then
        local refreshed = {}
        for _, c in ipairs(data.state.selected_clips) do
            local latest = clip_state.get_by_id(c.id)
            if latest then table.insert(refreshed, latest) end
        end
        data.state.selected_clips = refreshed
    end

    clip_state.inc_version()
    for _, c in ipairs(data.state.clips) do c._version = clip_state.get_version() end

    local adjusted = selection_state.normalize_edge_selection()
    if adjusted then M.persist_state_to_db() end
    data.notify_listeners()
    Signals.emit("timeline_clips_reloaded", displayed)
    return true
end

-- Re-read marks from DB when a mark command executes (or undoes)
Signals.connect("marks_changed", function(sequence_id)
    local changed = false
    if data.sequence and data.state.sequence_id == sequence_id then
        local Sequence = require("models.sequence")
        local fresh = Sequence.load(sequence_id)
        assert(fresh, string.format(
            "timeline_core_state: marks_changed: failed to reload active sequence_id=%s",
            tostring(sequence_id)))
        data.sequence.mark_in  = fresh.mark_in
        data.sequence.mark_out = fresh.mark_out
        changed = true
    end
    -- Strip-authoritative (015 #6): the SourceTab branch used to refresh a
    -- parallel data.source_sequence cache. That cache is gone — readers
    -- now go through tab_strip:get_source_tab() and Sequence.load. So we
    -- only need to notify here when the marks_changed event corresponds
    -- to the source tab, so view-layer listeners re-render the ruler.
    -- Notification is unconditional; cheap pull-on-redraw absorbs it.
    if changed then data.notify_listeners() end
end)

-- Source-loaded notification: rerender on load/unload. Strip-authoritative
-- (015 #6) — no longer caches a Sequence row; readers pull fresh via
-- tab_strip:get_source_tab() then Sequence.load (≈21µs per call).
Signals.connect("source_loaded_changed", function(_new_seq_id, _prev_seq_id)
    data.notify_listeners()
end)

-- Sync the in-memory track row when ToggleTrackPreference flips muted /
-- soloed / locked / enabled. ToggleTrackPreference mutates a freshly-
-- loaded Track instance and writes the DB column; the renderer reads
-- from data.state.tracks (populated by load_displayed_sequence) and
-- without this sync the visual hash overlay / future per-row state
-- would only flip on next sequence load. Signal value is INTEGER 0/1
-- per toggle_track_preference; data.state.tracks stores booleans.
Signals.connect("track_preference_changed", function(track_id, property, new_val)
    assert(type(track_id) == "string" and track_id ~= "",
        "track_preference_changed listener: track_id must be a non-empty string")
    assert(type(property) == "string" and property ~= "",
        "track_preference_changed listener: property must be a non-empty string")
    assert(new_val == 0 or new_val == 1, string.format(
        "track_preference_changed listener: new_val must be 0 or 1; got %s",
        tostring(new_val)))
    if not data.state.tracks then return end
    for _, t in ipairs(data.state.tracks) do
        if t.id == track_id then
            t[property] = (new_val == 1)
            data.notify_listeners()
            return
        end
    end
end)

-- Update playhead when SetPlayhead command fires.
-- The cached data.state.playhead_position is the DISPLAYED sequence's playhead
-- (the one the timeline view's ruler renders). SetPlayhead writes per-sequence, and
-- the active and displayed sequences may differ when the source tab is open.
Signals.connect("playhead_changed", function(sequence_id, frame)
    if strip_holder.displayed_sequence_id() == sequence_id and type(frame) == "number" then
        data.state.playhead_position = frame
        data.notify_listeners()
    end
end)

-- Reactive media status: when a media file changes status (online/offline/codec),
-- update all clips referencing that path and trigger re-render.
Signals.connect("media_status_changed", function(media_path, status)
    if not data.state.clips then return end
    local changed = false
    for _, clip in ipairs(data.state.clips) do
        if clip.media_path == media_path then
            clip.offline = status.offline
            clip.error_code = status.error_code
            changed = true
        end
    end
    if changed then
        clip_state.inc_version()
        for _, c in ipairs(data.state.clips) do c._version = clip_state.get_version() end
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

return M
