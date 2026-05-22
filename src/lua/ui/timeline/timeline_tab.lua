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
        _listeners = {},
        _next_listener_id = 1,
    }
    return setmetatable(tab, TimelineTab)
end

return TimelineTab
