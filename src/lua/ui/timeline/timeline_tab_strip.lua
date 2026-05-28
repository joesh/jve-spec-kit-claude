--- TimelineTabStrip — holder for TimelineTabs displayed in the timeline panel.
--
-- Per spec 015 architectural foundation: two pointers select tabs.
--   DisplayedTab     — the tab whose content the timeline view renders. Exactly one.
--   ActiveRecordTab  — the Record tab targeted by edits. Never the SourceTab.
--
-- Per spec F1: SourceTab is a singleton; when open it is always the FIRST
-- tab in the strip. Open/closed state persists across sessions (Phase 2 wires
-- to DB; this module exposes serialize/deserialize).
--
-- Switching the displayed tab is a pointer rebind. Consumers read fields off
-- the displayed tab directly — no display-aware accessor wrappers exist.

local TimelineTab = require("ui.timeline.timeline_tab")

local TimelineTabStrip = {}
TimelineTabStrip.__index = TimelineTabStrip

function TimelineTabStrip.new()
    local strip = {
        tabs = {},                -- ordered list (SourceTab first when present)
        displayed_tab = nil,      -- ref into tabs (or nil when empty)
        active_record_tab = nil,  -- ref into tabs (must be kind='record')
        source_tab = nil,         -- ref or nil — singleton
        _listeners = {},
        _next_listener_id = 1,
    }
    return setmetatable(strip, TimelineTabStrip)
end

local function index_of(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return nil
end

--- Open a record tab for the given sequence. If a tab for this sequence
--- already exists, returns the existing one (no duplicate).
-- @return TimelineTab
function TimelineTabStrip:open_record_tab(sequence_id)
    assert(type(sequence_id) == "string" and #sequence_id > 0,
        "TimelineTabStrip:open_record_tab: sequence_id required (non-empty string)")

    -- Idempotent: if a record tab exists for this sequence, return it.
    for _, t in ipairs(self.tabs) do
        if t.kind == "record" and t.sequence_id == sequence_id then
            return t
        end
    end

    local tab = TimelineTab.new("record", sequence_id)
    tab:load_from_database()
    table.insert(self.tabs, tab)
    -- First record tab auto-becomes active + displayed so consumers
    -- (ruler, scrollbar, renderer) have a tab to pull from at startup.
    -- Callers that want explicit control still drive switch_active_record /
    -- switch_displayed afterwards (idempotent).
    if not self.active_record_tab then
        self.active_record_tab = tab
    end
    if not self.displayed_tab then
        self.displayed_tab = tab
    end
    self:_notify()
    return tab
end

--- Close a record tab. Asserts the tab is in the strip and is a record tab.
--- If the closed tab was displayed/active, pointers fall back to a remaining
--- record tab (or to the source tab as displayed if no records remain).
function TimelineTabStrip:close_record_tab(tab)
    assert(type(tab) == "table" and tab.kind == "record",
        "TimelineTabStrip:close_record_tab: must pass a record tab")
    local idx = index_of(self.tabs, tab)
    assert(idx, string.format(
        "TimelineTabStrip:close_record_tab: tab id=%s not in strip", tostring(tab.id)))

    table.remove(self.tabs, idx)

    if self.active_record_tab == tab then
        self.active_record_tab = self:_first_record_tab()
    end
    if self.displayed_tab == tab then
        -- Prefer next active record; fall back to source tab if no records remain.
        self.displayed_tab = self.active_record_tab or self.source_tab
    end

    self:_notify()
end

--- Open (or update) the singleton SourceTab. If already open, the existing
--- tab's sequence_id is replaced (per spec F1 singleton behavior). The
--- SourceTab is always inserted/kept as the FIRST tab in the strip.
-- @return TimelineTab the source tab
function TimelineTabStrip:open_source_tab(sequence_id)
    assert(type(sequence_id) == "string" and #sequence_id > 0,
        "TimelineTabStrip:open_source_tab: sequence_id required (non-empty string)")

    if self.source_tab then
        -- Singleton: reload in place so listener subscriptions survive
        -- (UI components rely on continuity per F1 reload semantics).
        self.source_tab:reload(sequence_id)
        self.source_tab:load_from_database()
        self:_notify()
        return self.source_tab
    end

    local tab = TimelineTab.new("source", sequence_id)
    tab:load_from_database()
    table.insert(self.tabs, 1, tab)  -- always first per spec F1
    self.source_tab = tab
    self:_notify()
    return tab
end

--- Close the SourceTab. Underlying source-monitor state is unaffected
--- (managed elsewhere). If the closed tab was displayed, displayed pointer
--- moves to the active record tab.
function TimelineTabStrip:close_source_tab()
    assert(self.source_tab, "TimelineTabStrip:close_source_tab: no source tab open")

    local idx = index_of(self.tabs, self.source_tab)
    assert(idx, "TimelineTabStrip:close_source_tab: source_tab not in tabs (invariant broken)")
    table.remove(self.tabs, idx)
    local was_displayed = (self.displayed_tab == self.source_tab)
    self.source_tab = nil
    if was_displayed then
        self.displayed_tab = self.active_record_tab
    end
    self:_notify()
end

--- Switch the displayed-tab pointer only. Active-record pointer is unchanged.
--- Per spec FR-005: clicking the SourceTab updates only the displayed pointer.
function TimelineTabStrip:switch_displayed(tab)
    assert(type(tab) == "table",
        "TimelineTabStrip:switch_displayed: tab required")
    local idx = index_of(self.tabs, tab)
    assert(idx, string.format(
        "TimelineTabStrip:switch_displayed: tab id=%s not in strip", tostring(tab.id)))
    self.displayed_tab = tab
    self:_notify()
end

--- Drop the displayed pointer entirely (timeline goes blank). Used by
--- `timeline_state.clear()` when the project's active sequence reference
--- is being released without tearing down the whole strip. Other tabs
--- remain open; only the displayed pointer is nilled.
function TimelineTabStrip:clear_displayed()
    self.displayed_tab = nil
    self:_notify()
end

--- Drop the active-record pointer. Callers that clear timeline state must
--- clear this too — get_active_sequence_id delegates here, so a stale
--- pointer leaks the prior sequence id and views fail to render blank.
function TimelineTabStrip:clear_active_record()
    self.active_record_tab = nil
    self:_notify()
end

--- Switch the active record tab. Per spec FR-004: clicking a Record tab
--- updates BOTH pointers (displayed becomes that tab AND active becomes that
--- sequence). The argument MUST be a record tab — switching active to source
--- is never legal (the SourceTab is never the active sequence per FR-003).
function TimelineTabStrip:switch_active_record(record_tab)
    assert(type(record_tab) == "table" and record_tab.kind == "record",
        "TimelineTabStrip:switch_active_record: must pass a record tab")
    local idx = index_of(self.tabs, record_tab)
    assert(idx, string.format(
        "TimelineTabStrip:switch_active_record: tab id=%s not in strip", tostring(record_tab.id)))
    self.active_record_tab = record_tab
    self.displayed_tab = record_tab
    self:_notify()
end

function TimelineTabStrip:get_displayed()
    return self.displayed_tab
end

function TimelineTabStrip:get_active_record()
    return self.active_record_tab
end

-- Ergonomic accessors: each pulls from the correct tab (active record
-- for the edit target, displayed for the rendered view). Returns nil/{}
-- when the relevant pointer is unset — a valid blank-panel state, not
-- a missing invariant.

--- sequence_id of the active record tab (edit target — FR-005), or nil.
function TimelineTabStrip:active_sequence_id()
    local active = self.active_record_tab
    return active and active.sequence_id or nil
end

--- Live clip list of the displayed tab (media + derived gaps). Returns
--- the cache's own table by reference — callers must not mutate it.
--- Empty list when no tab is displayed.
--- Asserts inside a `forbid_bulk_clip_read` scope (renderer base pass
--- must go through track_clip_index, not bulk-scan all clips).
function TimelineTabStrip:displayed_clips()
    assert(not self._bulk_clip_read_forbidden,
        "TimelineTabStrip:displayed_clips forbidden in this scope — "
        .. "use track_clip_index(track_id) for per-track iteration")
    local displayed = self.displayed_tab
    if not displayed then return {} end
    return displayed.cache.clips
end

--- Run fn() with displayed_clips() guarded against bulk reads. Used by
--- the renderer base pass to enforce per-track iteration (rule 1.14
--- fail-fast). Unwinds the flag on both success and error.
function TimelineTabStrip:forbid_bulk_clip_read(fn)
    assert(not self._bulk_clip_read_forbidden,
        "TimelineTabStrip:forbid_bulk_clip_read: already inside a "
        .. "forbid scope (nested calls would re-clear the flag on exit)")
    self._bulk_clip_read_forbidden = true
    local ok, err = pcall(fn)
    self._bulk_clip_read_forbidden = false
    if not ok then error(err, 2) end
end

--- Live track list of the displayed tab. Empty list when no tab is displayed.
function TimelineTabStrip:displayed_tracks()
    local displayed = self.displayed_tab
    if not displayed then return {} end
    return displayed.cache.tracks
end

--- Clip lookup on the displayed tab. Returns nil if no tab displayed or
--- clip not present.
function TimelineTabStrip:clip_by_id(clip_id)
    local displayed = self.displayed_tab
    if not displayed then return nil end
    return displayed:get_clip_by_id(clip_id)
end

--- Per-track clip list (sorted) for the displayed tab. Returns a COPY so
--- callers may iterate/sort safely. Empty list when no tab displayed or
--- track has no clips.
function TimelineTabStrip:clips_for_track(track_id)
    local displayed = self.displayed_tab
    if not displayed then return {} end
    local list = displayed:get_track_clip_index(track_id)
    if not list then return {} end
    local copy = {}
    for _, c in ipairs(list) do table.insert(copy, c) end
    return copy
end

--- Raw per-track clip index (sorted clip list, table reference — do NOT mutate).
--- Returns nil when no tab displayed or track is unknown.
function TimelineTabStrip:track_clip_index(track_id)
    local displayed = self.displayed_tab
    if not displayed then return nil end
    return displayed:get_track_clip_index(track_id)
end

--- Clips on the displayed tab that span the given timeline position. When
--- candidate_clips is supplied, filter only those (callers pre-narrow the
--- search set, e.g. to a selection). Empty list when no tab is displayed.
function TimelineTabStrip:clips_at_time(time_value, candidate_clips)
    if candidate_clips == nil then
        local displayed = self.displayed_tab
        if not displayed then return {} end
        candidate_clips = displayed.cache.clips
    end
    local clips = require("ui.timeline.state.clip_state")
    return clips.get_at_time(time_value, candidate_clips)
end

function TimelineTabStrip:get_source_tab()
    return self.source_tab
end

--- Find the record tab matching the given sequence_id, or nil if none.
--- Source-side lookup goes through get_source_tab() instead — the source
--- tab is a singleton with mutable sequence_id (reload semantics).
function TimelineTabStrip:find_record_tab_by_sequence_id(sequence_id)
    assert(type(sequence_id) == "string" and #sequence_id > 0,
        "TimelineTabStrip:find_record_tab_by_sequence_id: sequence_id required (non-empty string)")
    for _, t in ipairs(self.tabs) do
        if t.kind == "record" and t.sequence_id == sequence_id then return t end
    end
    return nil
end

function TimelineTabStrip:_first_record_tab()
    for _, t in ipairs(self.tabs) do
        if t.kind == "record" then return t end
    end
    return nil
end

function TimelineTabStrip:add_listener(fn)
    assert(type(fn) == "function",
        "TimelineTabStrip:add_listener: fn must be a function")
    local id = self._next_listener_id
    self._next_listener_id = id + 1
    self._listeners[id] = fn
    return id
end

function TimelineTabStrip:remove_listener(id)
    self._listeners[id] = nil
end

function TimelineTabStrip:_notify()
    for _, fn in pairs(self._listeners) do fn(self) end
end

--- Serialize to a plain table for project-DB persistence (Phase 2 wires).
function TimelineTabStrip:serialize()
    local serialized_tabs = {}
    for i, t in ipairs(self.tabs) do
        serialized_tabs[i] = t:serialize()
    end
    return {
        tabs = serialized_tabs,
        displayed_tab_id = self.displayed_tab and self.displayed_tab.id or nil,
        active_record_tab_id = self.active_record_tab and self.active_record_tab.id or nil,
    }
end

--- Reconstruct a TimelineTabStrip from a serialized table.
function TimelineTabStrip.deserialize(t)
    assert(type(t) == "table", "TimelineTabStrip.deserialize: table required")
    assert(type(t.tabs) == "table", "TimelineTabStrip.deserialize: tabs list required")

    local strip = TimelineTabStrip.new()

    for _, serialized_tab in ipairs(t.tabs) do
        local tab = TimelineTab.deserialize(serialized_tab)
        -- Match the open_*_tab path: constructor builds empty containers,
        -- caller hydrates the cache from the DB. Without this the tab
        -- arrives with nil per-sequence fields and the first reader (ruler,
        -- viewport, renderer) asserts.
        tab:load_from_database()
        table.insert(strip.tabs, tab)
        if tab.kind == "source" then
            assert(strip.source_tab == nil,
                "TimelineTabStrip.deserialize: multiple source tabs in serialized state (invariant broken)")
            strip.source_tab = tab
        end
    end

    -- Resolve pointers by id (assert-on-miss; persisted state must reference real tabs).
    if t.displayed_tab_id then
        for _, tab in ipairs(strip.tabs) do
            if tab.id == t.displayed_tab_id then
                strip.displayed_tab = tab
                break
            end
        end
        assert(strip.displayed_tab, string.format(
            "TimelineTabStrip.deserialize: displayed_tab_id=%s does not match any tab",
            t.displayed_tab_id))
    end
    if t.active_record_tab_id then
        for _, tab in ipairs(strip.tabs) do
            if tab.id == t.active_record_tab_id and tab.kind == "record" then
                strip.active_record_tab = tab
                break
            end
        end
        assert(strip.active_record_tab, string.format(
            "TimelineTabStrip.deserialize: active_record_tab_id=%s does not match any record tab",
            t.active_record_tab_id))
    end

    return strip
end

return TimelineTabStrip
