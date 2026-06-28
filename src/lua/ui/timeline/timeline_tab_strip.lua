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
local assert_and_continue = require("core.assert_and_continue")

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
        -- Singleton. Idempotent like open_record_tab: only reload+rehydrate
        -- when the master actually CHANGES. Re-hydrating an unchanged tab
        -- re-reads the persisted (often unusable) viewport over in-memory
        -- view-state already applied this open — notably the content-fit
        -- load_displayed_sequence computes for a master at a non-zero TC
        -- origin. activate_displayed runs that fit then emits
        -- displayed_tab_changed, whose rebuild re-enters here for the SAME
        -- sequence; an unconditional rehydrate would wipe the fit and leave
        -- the source view parked on empty space before the content.
        if self.source_tab.sequence_id ~= sequence_id then
            -- Reload in place so listener subscriptions survive (UI
            -- components rely on continuity per F1 reload semantics).
            self.source_tab:reload(sequence_id)
            self.source_tab:load_from_database()
            self:_notify()
        end
        return self.source_tab
    end

    local tab = TimelineTab.new("source", sequence_id)
    tab:load_from_database()
    table.insert(self.tabs, 1, tab)  -- always first per spec F1
    self.source_tab = tab
    self:_notify()
    return tab
end

--- Ensure the source tab exists and is EMPTY (no master loaded,
--- sequence_id=nil) — the source side the user sees when the source monitor
--- holds nothing. Singleton like open_source_tab, but this both opens AND
--- reconciles: if a stale source tab still carries a loaded master it is reset
--- to the blank body, because callers only reach here when the source side is
--- known empty. Inserted first per spec F1. Does NOT touch the displayed/active
--- pointers — the caller (timeline_state.show_empty_source_tab) drives
--- switch_displayed.
-- @return TimelineTab the source tab (empty)
function TimelineTabStrip:ensure_empty_source_tab()
    if self.source_tab then
        -- The caller is asserting the source side is empty (the source
        -- monitor holds nothing). Reconcile a stale loaded source tab back
        -- to the blank body so "show the empty source tab" always yields an
        -- empty one. No-op when it is already empty.
        if not self.source_tab:is_empty_source() then
            self.source_tab:make_empty()
            self:_notify()
        end
        return self.source_tab
    end
    local tab = TimelineTab.new_empty_source()
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
--- callers may iterate/sort safely. Empty list when no tab displayed; the
--- underlying TimelineTab:get_track_clip_index returns `{}` for known-empty
--- tracks and asserts for unknown track_id (M3 contract).
function TimelineTabStrip:clips_for_track(track_id)
    local displayed = self.displayed_tab
    if not displayed then return {} end
    local copy = {}
    for _, c in ipairs(displayed:get_track_clip_index(track_id)) do
        table.insert(copy, c)
    end
    return copy
end

--- Raw per-track clip index (sorted clip list, table reference — do NOT mutate).
--- Returns nil when no tab is displayed; otherwise delegates to
--- TimelineTab:get_track_clip_index (which returns `{}` for known-empty
--- tracks and asserts for unknown track_id).
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

--- Reconcile a track rename into the cached track list. A rename writes the
--- DB and emits track_name_changed, but each tab's cache.tracks is a snapshot
--- taken at tab-open time — so the header view, which rebuilds from the cache,
--- would keep showing the old name until the tab is reopened. This updates the
--- cached name in place wherever the track lives (a track belongs to exactly
--- one open tab's cache). new_name is the stored value: a string, or nil when
--- the override was cleared (the derived label then returns).
--- @return boolean true if the track was found in some tab's cache.
function TimelineTabStrip:refresh_track_name(track_id, new_name)
    assert(type(track_id) == "string" and track_id ~= "",
        "TimelineTabStrip:refresh_track_name: track_id required (non-empty string)")
    assert(new_name == nil or type(new_name) == "string",
        "TimelineTabStrip:refresh_track_name: new_name must be a string or nil")
    for _, tab in ipairs(self.tabs) do
        for _, track in ipairs(tab.cache.tracks) do
            if track.id == track_id then
                track.name = new_name
                return true
            end
        end
    end
    return false
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

--- Build a serialized strip blob from a list of record sequence ids + the
--- active one — the import/restore seam. Importers know only "these
--- sequences are open, this one is active"; this turns that into the strip's
--- canonical serialize() blob (record tabs only — imports never carry a
--- source tab; the active sequence is both displayed and active). Pure data,
--- no DB or Qt, so command/importer layers can call it headless.
function TimelineTabStrip.build_record_only_blob(open_ids, active_id)
    assert(type(open_ids) == "table",
        "TimelineTabStrip.build_record_only_blob: open_ids list required")
    local uuid = require("uuid")
    local tabs = {}
    local active_tab_id = nil
    for _, seq_id in ipairs(open_ids) do
        assert(type(seq_id) == "string" and seq_id ~= "",
            "TimelineTabStrip.build_record_only_blob: open_ids entries must be non-empty strings")
        local tab_id = uuid.generate()
        tabs[#tabs + 1] = { id = tab_id, kind = "record", sequence_id = seq_id }
        if active_id and seq_id == active_id then active_tab_id = tab_id end
    end
    return {
        tabs = tabs,
        displayed_tab_id = active_tab_id,
        active_record_tab_id = active_tab_id,
    }
end

--- Decode a serialized strip blob into the fields restore needs to replay it,
--- keeping strip-format knowledge (tab kinds, the empty-source convention of an
--- absent sequence_id) inside this module rather than leaking it into the
--- layout composition root. Pure data, no DB or Qt. Returns:
---   record_ids     — record sequence ids in saved order
---   source_seq     — the loaded source master id, or nil
---   source_is_empty — true when the blob carried the empty source tab
---   displayed_kind — "source"/"record" of the displayed tab, or nil
---   displayed_seq  — the displayed tab's sequence_id (nil for the empty source)
--- The caller owns the cross-layer replay (it spans state/panel/source_viewer);
--- this only turns bytes into intent.
function TimelineTabStrip.decode_blob(blob)
    assert(type(blob) == "table" and type(blob.tabs) == "table",
        "TimelineTabStrip.decode_blob: blob with a tabs list required")
    local decoded = {
        record_ids = {}, source_seq = nil, source_is_empty = false,
        displayed_kind = nil, displayed_seq = nil,
    }
    for _, t in ipairs(blob.tabs) do
        if t.kind == "source" then
            if t.sequence_id and t.sequence_id ~= "" then
                decoded.source_seq = t.sequence_id
            else
                decoded.source_is_empty = true
            end
        elseif t.kind == "record" and t.sequence_id and t.sequence_id ~= "" then
            decoded.record_ids[#decoded.record_ids + 1] = t.sequence_id
        end
        if blob.displayed_tab_id and t.id == blob.displayed_tab_id then
            decoded.displayed_kind = t.kind
            decoded.displayed_seq = t.sequence_id
        end
    end
    return decoded
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
    local Sequence = require("models.sequence")

    for _, serialized_tab in ipairs(t.tabs) do
        local tab = TimelineTab.deserialize(serialized_tab)
        -- Match the open_*_tab path: constructor builds empty containers,
        -- caller hydrates the cache from the DB. Without this the tab
        -- arrives with nil per-sequence fields and the first reader (ruler,
        -- viewport, renderer) asserts. The empty source tab has no sequence
        -- to load — it stays the fresh empty containers (blank body).
        if not tab:is_empty_source() then
            -- A persisted tab can point at a sequence that's been deleted
            -- out of band — e.g. DeleteMasterClip historically didn't emit
            -- sequence_list_changed, so the source tab was saved with a
            -- dead id and load_from_database asserted on relaunch. Pre-check
            -- with assert_and_continue: surface loud + trace, then drop the tab so
            -- the project still opens.
            if not assert_and_continue(Sequence.load(tab.sequence_id),
                "TimelineTabStrip.deserialize: tab %s references missing sequence %s — "
                .. "dropping tab and continuing",
                tostring(tab.id), tostring(tab.sequence_id)) then
                goto skip_tab
            end
            tab:load_from_database()
        end
        table.insert(strip.tabs, tab)
        if tab.kind == "source" then
            assert(strip.source_tab == nil,
                "TimelineTabStrip.deserialize: multiple source tabs in serialized state (invariant broken)")
            strip.source_tab = tab
        end
        ::skip_tab::
    end

    -- Resolve pointers by id. Persisted state SHOULD reference real tabs,
    -- but we may have dropped one above via assert_and_continue recovery — in that
    -- case fall through to nil so the strip still opens.
    if t.displayed_tab_id then
        for _, tab in ipairs(strip.tabs) do
            if tab.id == t.displayed_tab_id then
                strip.displayed_tab = tab
                break
            end
        end
        assert_and_continue(strip.displayed_tab,
            "TimelineTabStrip.deserialize: displayed_tab_id=%s does not match any "
            .. "remaining tab (likely dropped by sequence-missing recovery above)",
            tostring(t.displayed_tab_id))
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
