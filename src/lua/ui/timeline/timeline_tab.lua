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

local TimelineTab = {}
TimelineTab.__index = TimelineTab

local VALID_KINDS = { record = true, source = true }

-- Empty-cache constructor. Phase 1.1 (spec 022): per-tab cache mirrors the
-- per-sequence fields that data.state holds today. Selection and drag are
-- NOT included — both remain global on timeline_state (selection is global
-- by design; drag because cross-timeline drags are supported). Phase 1.3
-- re-points clip/track indexes onto this cache; phase 1.4 dispatches
-- signals per-tab. Until those phases land nothing reads from .cache;
-- this is empty plumbing.
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
        -- Per-tab clip indexes (Phase 1.3a-i; spec 022). Mirrors the
        -- module-level indexes in clip_state.lua but owned per-tab so
        -- writes routed by sequence_id (1.3a-ii) hit the right cache.
        -- Rebuilt lazily on first index getter when indexes_dirty=true;
        -- load_from_database marks dirty so the freshly-loaded clips
        -- index themselves on next access.
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

-- Group media clips by track_id and sort each track's list by sequence_start
-- (ties broken by clip id for determinism). Matches the ordering that
-- gap_lifecycle expects and that core_state.recompute_gap_clips applies.
local function group_and_sort_media_by_track(media_clips)
    local by_track = {}
    for _, c in ipairs(media_clips) do
        assert(c.track_id and c.track_id ~= "", string.format(
            "TimelineTab:load_from_database: clip %s missing track_id",
            tostring(c.id)))
        local list = by_track[c.track_id]
        if not list then list = {}; by_track[c.track_id] = list end
        table.insert(list, c)
    end
    for _, list in pairs(by_track) do
        table.sort(list, function(a, b)
            if a.sequence_start == b.sequence_start then return a.id < b.id end
            return a.sequence_start < b.sequence_start
        end)
    end
    return by_track
end

-- Compute derived gap clips for every track and return media+gaps merged.
local function clips_with_derived_gaps(tracks, media_clips, seq_fr)
    local gap_lifecycle = require("core.gap_lifecycle")
    local by_track = group_and_sort_media_by_track(media_clips)
    local merged = {}
    for _, c in ipairs(media_clips) do table.insert(merged, c) end
    for _, t in ipairs(tracks) do
        local sorted = by_track[t.id] or {}
        local gaps = gap_lifecycle.compute_gaps_for_track(t.id, sorted, seq_fr)
        for _, g in ipairs(gaps) do table.insert(merged, g) end
    end
    return merged
end

local function compute_content_length(clips)
    local max_end = 0
    for _, c in ipairs(clips) do
        if type(c.sequence_start) == "number" and type(c.duration) == "number" then
            local e = c.sequence_start + c.duration
            if e > max_end then max_end = e end
        end
    end
    return max_end
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
function TimelineTab:load_from_database()
    local db = require("core.database")
    local seq = Sequence.load(self.sequence_id)
    assert(seq, string.format(
        "TimelineTab:load_from_database: sequence_id=%s not found",
        tostring(self.sequence_id)))
    assert(type(seq.frame_rate) == "table",
        string.format("TimelineTab:load_from_database: seq %s missing frame_rate table",
            tostring(self.sequence_id)))
    assert(seq.frame_rate.fps_numerator and seq.frame_rate.fps_denominator,
        string.format("TimelineTab:load_from_database: seq %s has NULL frame rate",
            tostring(self.sequence_id)))
    assert(type(seq.start_timecode_frame) == "number", string.format(
        "TimelineTab:load_from_database: seq %s missing start_timecode_frame",
        tostring(self.sequence_id)))
    assert(type(seq.playhead_position) == "number", string.format(
        "TimelineTab:load_from_database: seq %s missing playhead_position",
        tostring(self.sequence_id)))
    assert(type(seq.viewport_start_time) == "number", string.format(
        "TimelineTab:load_from_database: seq %s missing viewport_start_time",
        tostring(self.sequence_id)))
    assert(type(seq.viewport_duration) == "number", string.format(
        "TimelineTab:load_from_database: seq %s missing viewport_duration",
        tostring(self.sequence_id)))
    assert(type(seq.video_scroll_offset) == "number", string.format(
        "TimelineTab:load_from_database: seq %s missing video_scroll_offset",
        tostring(self.sequence_id)))
    assert(type(seq.audio_scroll_offset) == "number", string.format(
        "TimelineTab:load_from_database: seq %s missing audio_scroll_offset",
        tostring(self.sequence_id)))
    assert(type(seq.video_audio_split_ratio) == "number", string.format(
        "TimelineTab:load_from_database: seq %s missing video_audio_split_ratio",
        tostring(self.sequence_id)))

    local tracks = db.load_tracks(self.sequence_id)
    apply_persisted_track_heights(tracks, self.sequence_id)

    local media_clips
    if seq:is_master() then
        media_clips = db.load_master_virtual_clips(self.sequence_id)
    else
        media_clips = db.load_clips(self.sequence_id)
    end

    local merged_clips = clips_with_derived_gaps(tracks, media_clips, seq.frame_rate)

    self.cache.tracks = tracks
    self.cache.clips = merged_clips
    self.cache.content_length = compute_content_length(merged_clips)
    self.cache.indexes_dirty = true
    self.cache.sequence_frame_rate = seq.frame_rate
    self.cache.sequence_timecode_start_frame = seq.start_timecode_frame
    self.cache.viewport_start_time = seq.viewport_start_time
    self.cache.viewport_duration = seq.viewport_duration
    self.cache.video_scroll_offset = seq.video_scroll_offset
    self.cache.audio_scroll_offset = seq.audio_scroll_offset
    self.cache.video_audio_split_ratio = seq.video_audio_split_ratio
    self.cache.playhead_position = seq.playhead_position
end

-- Rebuild the per-tab indexes from cache.clips. Ties broken by clip id
-- for determinism. Mirrors clip_state.rebuild_clip_indexes shape so
-- 1.3a-ii can route apply_mutations writes through these without
-- changing the index semantics.
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

--- Mark per-tab indexes dirty. Callers that mutate cache.clips directly
--- (Phase 1.3a-ii apply_mutations will call this after each batch) must
--- invoke this so the next index getter triggers a lazy rebuild.
function TimelineTab:invalidate_indexes()
    self.cache.indexes_dirty = true
end

function TimelineTab:get_clip_by_id(clip_id)
    if clip_id == nil then return nil end
    ensure_indexes(self)
    return self.cache.clip_lookup[clip_id]
end

--- Return the internal sorted clip list for a track (read-only reference,
--- nil when track has no clips). Matches clip_state.get_track_clip_index
--- semantics so 1.3a-ii routing can swap callers without surprise.
function TimelineTab:get_track_clip_index(track_id)
    if track_id == nil then return nil end
    ensure_indexes(self)
    return self.cache.track_clip_index[track_id]
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

return TimelineTab
