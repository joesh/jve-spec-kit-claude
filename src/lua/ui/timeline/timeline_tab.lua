--- TimelineTab — one tab in the timeline panel's strip.
--
-- A tab is a thin handle: (id, kind, sequence_id) + listener pub/sub. All
-- displayed state (marks, viewport, playhead, scroll) lives on the
-- sequence row (`sequences` table). Tab getters pull lazily so model
-- mutations propagate without explicit cache sync (MVC pull-not-push,
-- rule 3.0).
--
-- Selection and drag state are NOT per-tab. Both are global on
-- timeline_state. Selection is global by design; drag is global because
-- cross-timeline drags (drag a clip from one tab's view to another's) are
-- supported.
--
-- Two kinds:
--   'record' — a record-side tab, one per open sequence. Edit target.
--   'source' — the singleton source-side tab; its sequence_id mirrors
--              whatever the source monitor has loaded.

local uuid = require("uuid")
local Sequence = require("models.sequence")
local clip_geometry = require("ui.timeline.clip_geometry")

local TimelineTab = {}
TimelineTab.__index = TimelineTab

local VALID_KINDS = { record = true, source = true }

-- Per-tab cache holds the per-sequence fields that the timeline view
-- pulls from. Selection and drag stay global on timeline_state (selection
-- by design; drag because cross-timeline drags are supported). Indexes
-- rebuild lazily on first getter after indexes_dirty=true.
local function fresh_cache()
    return {
        tracks = {},
        clips = {},  -- media + derived gap clips
        content_length = 0,
        sequence_frame_rate = nil,
        sequence_timecode_start_frame = 0,
        viewport_start_time = 0,
        viewport_duration = 0,
        video_scroll_offset = 0,
        audio_scroll_offset = 0,
        video_audio_split_ratio = 0.5,
        playhead_position = 0,
        clip_lookup = {},          -- clip_id → clip
        track_clip_index = {},     -- track_id → sorted clip list
        clip_track_positions = {}, -- clip_id → {list, index}
        indexes_dirty = true,
    }
end

-- Resolve and assert that this tab's sequence exists, returning the loaded
-- Sequence row. Every getter goes through this so consumers see fresh state.
local function load_seq_strict(self, caller)
    local seq = Sequence.load(self.sequence_id)
    assert(seq, string.format(
        "%s: sequence_id=%s not found", caller, self.sequence_id))
    return seq
end

--- Construct a fresh TimelineTab. Generates a new id. State lives on the
--- sequence row; the tab holds only the reference + kind tag.
function TimelineTab.new(kind, sequence_id)
    assert(VALID_KINDS[kind],
        string.format("TimelineTab.new: kind must be 'record' or 'source' (got %s)",
            tostring(kind)))
    assert(type(sequence_id) == "string" and #sequence_id > 0,
        "TimelineTab.new: sequence_id required (non-empty string)")

    -- Validate the sequence exists at construction time so we fail fast on
    -- ghost references rather than at the first getter call.
    local seq = Sequence.load(sequence_id)
    assert(seq, string.format(
        "TimelineTab.new: sequence_id=%s not found", sequence_id))

    local tab = {
        id = uuid.generate(),
        kind = kind,
        sequence_id = sequence_id,
        cache = fresh_cache(),
        _listeners = {},
        _next_listener_id = 1,
    }
    return setmetatable(tab, TimelineTab)
end

--- Marks pulled lazily from the sequence row.
--- Source tab in live-bound mode (spec 019 FR-016d): the visible marks
--- come from the loaded CLIP's source_in/source_out via
--- effective_source's override slot — NOT from the master source
--- sequence's mark_in/mark_out (which stay nil for the master). Same
--- channel the source monitor reads from (SequenceMonitor:get_mark_in).
--- Record tabs and staged-mode source tab fall through to the sequence
--- row's persisted marks.
function TimelineTab:get_marks()
    local seq = load_seq_strict(self, "TimelineTab:get_marks")
    if self.kind == "source" then
        local in_frame, out_frame = require("core.effective_source")
            .get_source_marks_for(seq.id)
        if in_frame ~= nil then
            return { in_frame = in_frame, out_frame = out_frame }
        end
    end
    return { in_frame = seq.mark_in, out_frame = seq.mark_out }
end

--- Re-point this tab at a different sequence. Asserts the new sequence
--- exists. Preserves tab id and listener subscriptions — UI components
--- subscribed for redraws continue to receive notifications across a
--- reload (essential for the SourceTab singleton, which is reloaded on
--- source-monitor changes per spec F1).
function TimelineTab:reload(new_sequence_id)
    assert(type(new_sequence_id) == "string" and #new_sequence_id > 0,
        "TimelineTab:reload: new_sequence_id required (non-empty string)")
    local seq = Sequence.load(new_sequence_id)
    assert(seq, string.format(
        "TimelineTab:reload: sequence_id=%s not found", new_sequence_id))
    self.sequence_id = new_sequence_id
    self:_notify()
end

--- Subscribe to change notifications. Returns a listener id; pass it to
--- remove_listener to unsubscribe.
function TimelineTab:add_listener(fn)
    assert(type(fn) == "function",
        "TimelineTab:add_listener: fn must be a function")
    local id = self._next_listener_id
    self._next_listener_id = id + 1
    self._listeners[id] = fn
    return id
end

function TimelineTab:remove_listener(id)
    self._listeners[id] = nil
end

function TimelineTab:_notify()
    for _, fn in pairs(self._listeners) do fn(self) end
end

--- Serialize to a plain table for project-DB persistence. Per-tab display
--- state (viewport, playhead, scroll, marks) is NOT serialized here — that
--- lives on the sequence row and persists via existing Sequence model code.
function TimelineTab:serialize()
    return {
        id = self.id,
        kind = self.kind,
        sequence_id = self.sequence_id,
    }
end

--- Reconstruct from a serialized table. Asserts every persisted field is
--- present + that the referenced sequence still exists.
function TimelineTab.deserialize(t)
    assert(type(t) == "table", "TimelineTab.deserialize: table required")
    assert(type(t.id) == "string" and #t.id > 0,
        "TimelineTab.deserialize: id required (non-empty string)")
    assert(VALID_KINDS[t.kind],
        string.format("TimelineTab.deserialize: kind must be 'record' or 'source' (got %s)",
            tostring(t.kind)))
    assert(type(t.sequence_id) == "string" and #t.sequence_id > 0,
        "TimelineTab.deserialize: sequence_id required (non-empty string)")
    local seq = Sequence.load(t.sequence_id)
    assert(seq, string.format(
        "TimelineTab.deserialize: sequence_id=%s not found", t.sequence_id))

    local tab = {
        id = t.id,
        kind = t.kind,
        sequence_id = t.sequence_id,
        cache = fresh_cache(),
        _listeners = {},
        _next_listener_id = 1,
    }
    return setmetatable(tab, TimelineTab)
end

-- Compute derived gap clips for every track and return media+gaps merged.
local function clips_with_derived_gaps(tracks, media_clips, seq_fr)
    local gap_lifecycle = require("core.gap_lifecycle")
    local by_track = clip_geometry.group_and_sort_media_by_track(media_clips)
    local merged = {}
    for _, c in ipairs(media_clips) do table.insert(merged, c) end
    for _, t in ipairs(tracks) do
        local sorted = by_track[t.id] or {}
        local gaps = gap_lifecycle.compute_gaps_for_track(t.id, sorted, seq_fr)
        for _, g in ipairs(gaps) do table.insert(merged, g) end
    end
    return merged
end

-- Apply persisted track heights (or fall through to the schema default for
-- tracks without a row in sequence_track_heights). Mutates the loaded
-- track rows in place, matching the shape core_state.load_displayed_sequence
-- materialises today.
local function apply_persisted_track_heights(tracks, sequence_id)
    local db = require("core.database")
    if not db.load_sequence_track_heights then
        local default_h = require("core.ui_constants").TIMELINE.TRACK_HEIGHT
        assert(type(default_h) == "number" and default_h > 0,
            "TimelineTab:load_from_database: ui_constants.TIMELINE.TRACK_HEIGHT missing")
        for _, t in ipairs(tracks) do t.height = default_h end
        return
    end
    local saved = db.load_sequence_track_heights(sequence_id)
    local default_h = require("core.ui_constants").TIMELINE.TRACK_HEIGHT
    assert(type(default_h) == "number" and default_h > 0,
        "TimelineTab:load_from_database: ui_constants.TIMELINE.TRACK_HEIGHT missing")
    for _, t in ipairs(tracks) do
        local h = saved and saved[t.id]
        if h then
            assert(type(h) == "number", string.format(
                "TimelineTab:load_from_database: track %s height must be a number",
                tostring(t.id)))
            local clamped = math.floor(h)
            if clamped < 24 then clamped = 24 end
            t.height = clamped
        else
            t.height = default_h
        end
    end
end

-- Validate every required sequence-row field BEFORE touching self.cache so
-- a missing invariant leaves the cache untouched (rule 1.14: fail loudly,
-- no half-state). Selection restore, viewport-fit, and other view-state
-- decisions remain in core_state.load_displayed_sequence — those interact
-- with the singleton data.state today and will move per-tab in later
-- phases (1.4+) when the cache becomes the authoritative source.
-- Numeric fields required on the sequence row for a load. Frame rate is
-- validated separately (table, not scalar).
local REQUIRED_SEQ_NUMERIC_FIELDS = {
    "start_timecode_frame", "playhead_position",
    "viewport_start_time", "viewport_duration",
    "video_scroll_offset", "audio_scroll_offset",
    "video_audio_split_ratio",
}

-- Sequence-row fields that copy 1:1 into the tab cache under the same name.
-- start_timecode_frame is the odd one out — it lands at
-- cache.sequence_timecode_start_frame and is set explicitly below.
local SEQ_TO_CACHE_PASSTHROUGH = {
    "playhead_position",
    "viewport_start_time", "viewport_duration",
    "video_scroll_offset", "audio_scroll_offset", "video_audio_split_ratio",
}

-- Per FR-load: every field listed must be present and numeric on the
-- sequence row before we touch self.cache. Asserts at the boundary (1.14)
-- so a corrupt sequence row crashes loudly here instead of producing
-- half-state downstream.
local function assert_sequence_row_loadable(seq, sequence_id)
    assert(type(seq.frame_rate) == "table", string.format(
        "TimelineTab:load_from_database: seq %s missing frame_rate table",
        tostring(sequence_id)))
    assert(seq.frame_rate.fps_numerator and seq.frame_rate.fps_denominator,
        string.format("TimelineTab:load_from_database: seq %s has NULL frame rate",
            tostring(sequence_id)))
    for _, field in ipairs(REQUIRED_SEQ_NUMERIC_FIELDS) do
        assert(type(seq[field]) == "number", string.format(
            "TimelineTab:load_from_database: seq %s missing %s",
            tostring(sequence_id), field))
    end
end

local function load_media_clips(db, seq)
    if seq:is_master() then
        return db.load_master_virtual_clips(seq.id)
    end
    return db.load_clips(seq.id)
end

function TimelineTab:load_from_database()
    local db = require("core.database")
    local seq = Sequence.load(self.sequence_id)
    assert(seq, string.format(
        "TimelineTab:load_from_database: sequence_id=%s not found",
        tostring(self.sequence_id)))
    assert_sequence_row_loadable(seq, self.sequence_id)

    local tracks = db.load_tracks(self.sequence_id)
    apply_persisted_track_heights(tracks, self.sequence_id)

    local media_clips = load_media_clips(db, seq)
    local merged_clips = clips_with_derived_gaps(tracks, media_clips, seq.frame_rate)

    local cache = self.cache
    cache.tracks = tracks
    cache.clips = merged_clips
    cache.content_length = clip_geometry.compute_content_length(merged_clips)
    cache.indexes_dirty = true
    cache.sequence_frame_rate = seq.frame_rate
    cache.sequence_timecode_start_frame = seq.start_timecode_frame
    for _, field in ipairs(SEQ_TO_CACHE_PASSTHROUGH) do
        cache[field] = seq[field]
    end
end

-- Rebuild per-tab indexes from cache.clips. Ties broken by clip id
-- for determinism.
local function rebuild_indexes(cache)
    local lookup, track_index, positions = {}, {}, {}
    for _, clip in ipairs(cache.clips) do
        if clip.id then
            lookup[clip.id] = clip
            if clip.track_id then
                local list = track_index[clip.track_id]
                if not list then list = {}; track_index[clip.track_id] = list end
                table.insert(list, clip)
            end
        end
    end
    for _, list in pairs(track_index) do
        table.sort(list, function(a, b)
            assert(type(a.sequence_start) == "number", string.format(
                "TimelineTab: clip %s missing sequence_start", tostring(a.id)))
            assert(type(b.sequence_start) == "number", string.format(
                "TimelineTab: clip %s missing sequence_start", tostring(b.id)))
            if a.sequence_start == b.sequence_start then
                return a.id < b.id
            end
            return a.sequence_start < b.sequence_start
        end)
        for i, clip in ipairs(list) do
            positions[clip.id] = { list = list, index = i }
        end
    end
    cache.clip_lookup = lookup
    cache.track_clip_index = track_index
    cache.clip_track_positions = positions
    cache.indexes_dirty = false
end

local function ensure_indexes(self)
    if self.cache.indexes_dirty then rebuild_indexes(self.cache) end
end

--- Mark per-tab indexes dirty so the next getter rebuilds. Callers that
--- mutate cache.clips directly must invoke this.
function TimelineTab:invalidate_indexes()
    self.cache.indexes_dirty = true
end

function TimelineTab:get_clip_by_id(clip_id)
    if clip_id == nil then return nil end
    ensure_indexes(self)
    return self.cache.clip_lookup[clip_id]
end

--- Internal sorted clip list for a track (read-only reference, nil when
--- track has no clips). Matches clip_state.get_track_clip_index semantics.
function TimelineTab:get_track_clip_index(track_id)
    if track_id == nil then return nil end
    ensure_indexes(self)
    return self.cache.track_clip_index[track_id]
end

local function recompute_content_length(cache)
    cache.content_length = clip_geometry.compute_content_length(cache.clips)
end

-- Apply a bulk_shift bucket to a single track's sorted clip list in cache.
-- Output invariant pinned by clip_state's original assert: a non-zero
-- shift MUST find at least one clip at or past start_frame. Zero rows
-- means either a producer bug (emitted against dead track/stale
-- position) or cache divergence — both crash with context (NSF).
local function apply_bulk_shift_to_cache(cache, shift)
    assert(type(shift) == "table",
        "TimelineTab:apply_mutations: bulk_shift entry must be a table")
    assert(shift.track_id and shift.track_id ~= "",
        "TimelineTab:apply_mutations: bulk_shift missing track_id")
    assert(type(shift.shift_frames) == "number",
        "TimelineTab:apply_mutations: bulk_shift missing numeric shift_frames")
    assert(type(shift.start_frame) == "number",
        "TimelineTab:apply_mutations: bulk_shift missing numeric start_frame")
    if shift.shift_frames == 0 then return false end
    local list = cache.track_clip_index[shift.track_id] or {}
    local shifted = 0
    for _, clip in ipairs(list) do
        if type(clip.sequence_start) == "number"
            and clip.sequence_start >= shift.start_frame then
            clip.sequence_start = clip.sequence_start + shift.shift_frames
            shifted = shifted + 1
        end
    end
    assert(shifted > 0, string.format(
        "TimelineTab:apply_mutations: bulk_shift for track %s at start_frame %d "
        .. "with delta %d affected zero clips (track has %d clips in tab cache)",
        tostring(shift.track_id), shift.start_frame, shift.shift_frames, #list))
    return true
end

-- Mutation update_*_value → clip field, asserted numeric. Next time
-- an integer field is added to a mutation payload it's a one-line
-- table entry, not another if-block.
local NUMERIC_UPDATE_FIELDS = {
    { src = "start_value",       dst = "sequence_start" },
    { src = "duration_value",    dst = "duration" },
    { src = "source_in_value",   dst = "source_in" },
    { src = "source_out_value",  dst = "source_out" },
}

local function apply_numeric_updates(clip, update)
    local changed = false
    for _, f in ipairs(NUMERIC_UPDATE_FIELDS) do
        local v = update[f.src]
        if v and v ~= clip[f.dst] then
            assert(type(v) == "number", string.format(
                "TimelineTab:apply_mutations: %s must be integer", f.src))
            clip[f.dst] = v
            changed = true
        end
    end
    return changed
end

local function apply_update_to_cache(cache, update)
    local clip_id = update.clip_id or update.id
    if not clip_id then return false end
    local clip = cache.clip_lookup[clip_id]
    if not clip then return false end

    local changed = false
    if update.track_id and update.track_id ~= clip.track_id then
        clip.track_id = update.track_id; changed = true
    end
    if update.frame_rate then
        assert(update.frame_rate.fps_numerator and update.frame_rate.fps_denominator,
            string.format("TimelineTab:apply_mutations: malformed frame_rate for clip %s",
                tostring(clip.id)))
        clip.frame_rate = update.frame_rate
    end
    if apply_numeric_updates(clip, update) then changed = true end
    if update.enabled ~= nil and update.enabled ~= clip.enabled then
        clip.enabled = update.enabled and true or false; changed = true
    end
    if update.name ~= nil and update.name ~= clip.name then
        clip.name = update.name
        if update.name ~= "" then clip.label = update.name end
        changed = true
    end
    return changed
end

--- Apply a mutations bucket to this tab's cache (cache.clips + indexes).
--- Operates on cache ONLY — no signal emit, no persistence callback, no
--- selection update (the orchestrator at timeline_state.apply_mutations
--- handles those cross-cutting concerns). Order:
--- updates → inserts → bulk_shifts → placements → deletes.
function TimelineTab:apply_mutations(mutations)
    if type(mutations) ~= "table" then return false end
    local changed = false
    local cache = self.cache

    -- Updates must run against fresh indexes so clip_lookup is populated.
    ensure_indexes(self)
    if mutations.updates then
        for _, update in ipairs(mutations.updates) do
            if apply_update_to_cache(cache, update) then changed = true end
        end
    end

    local function apply_insert_list(list)
        if not list then return end
        for _, clip in ipairs(list) do
            if clip_geometry.normalize_clip_integers(clip) then
                table.insert(cache.clips, clip)
                changed = true
            end
        end
    end

    apply_insert_list(mutations.inserts)
    if changed then self:invalidate_indexes(); ensure_indexes(self) end

    if mutations.bulk_shifts then
        ensure_indexes(self)
        for _, shift in ipairs(mutations.bulk_shifts) do
            if apply_bulk_shift_to_cache(cache, shift) then changed = true end
        end
    end

    apply_insert_list(mutations.placements)

    if mutations.deletes then
        for _, entry in ipairs(mutations.deletes) do
            local clip_id = type(entry) == "table" and entry.clip_id or entry
            for i = #cache.clips, 1, -1 do
                if cache.clips[i].id == clip_id then
                    table.remove(cache.clips, i)
                    changed = true
                end
            end
        end
    end

    if changed then
        self:invalidate_indexes()
        recompute_content_length(cache)
    end
    return changed
end

function TimelineTab:locate_neighbor(clip, offset)
    if not (clip and clip.id) then return nil end
    assert(type(offset) == "number",
        "TimelineTab:locate_neighbor: offset must be a number")
    ensure_indexes(self)
    local info = self.cache.clip_track_positions[clip.id]
    if not info then return nil end
    local i = info.index + offset
    if i < 1 or i > #info.list then return nil end
    return info.list[i]
end

-- Per-tab mutation snapshot for undo-group rollback. Each tab carries its
-- own stack so begin/commit/rollback target the tab the active edit-target
-- pointed to at begin time. Snapshots ONLY this tab's clip cache; the
-- global selection snapshot is handled at the clip_state facade so the
-- cross-tab concern stays out of the per-tab module (audit A1).

local function ensure_snapshot_stack(self)
    if not self._mutation_snapshot_stack then
        self._mutation_snapshot_stack = {}
    end
    return self._mutation_snapshot_stack
end

function TimelineTab:has_active_mutation_snapshot()
    return self._mutation_snapshot_stack ~= nil and #self._mutation_snapshot_stack > 0
end

function TimelineTab:begin_mutation_transaction()
    local stack = ensure_snapshot_stack(self)
    -- Shallow-clone each clip table — mutations modify fields in-place.
    local clips_copy = {}
    for i, clip in ipairs(self.cache.clips) do
        local copy = {}
        for k, v in pairs(clip) do copy[k] = v end
        clips_copy[i] = copy
    end
    table.insert(stack, { clips = clips_copy })
end

function TimelineTab:commit_mutation_transaction()
    local stack = self._mutation_snapshot_stack
    assert(stack and #stack > 0,
        "TimelineTab:commit_mutation_transaction: no matching begin (stack empty)")
    table.remove(stack)
end

--- Restore cache.clips from the top of the stack. Returns the restored
--- clip list so the caller (clip_state facade) can re-bind selection
--- objects against the freshly-restored clip tables.
function TimelineTab:rollback_mutation_transaction()
    local stack = self._mutation_snapshot_stack
    assert(stack and #stack > 0,
        "TimelineTab:rollback_mutation_transaction: no matching begin (stack empty)")
    local snapshot = table.remove(stack)

    -- Restore cache.clips in place (preserves table identity so any
    -- held aliases keep pointing at the same array).
    local clips = self.cache.clips
    for i = #clips, 1, -1 do table.remove(clips, i) end
    for _, c in ipairs(snapshot.clips) do table.insert(clips, c) end

    self:invalidate_indexes()
    return snapshot.clips
end

return TimelineTab
