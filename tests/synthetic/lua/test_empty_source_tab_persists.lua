#!/usr/bin/env luajit
--- The empty source tab survives quit/restart (persistence invariant).
---
--- Domain contract: pressing the source/record toggle with nothing loaded
--- shows a blank-body Source tab. Like every tab, it must come back after a
--- quit — so timeline_state must persist it as part of the timeline_tab_strip
--- blob (the single source of truth for restore), with no sequence to point
--- at (sequence_id absent). On the next launch the strip deserializes it
--- sequence-less.
---
--- Exercises the WRITE + read-back path end-to-end against a real DB:
---   1. show_empty_source_tab() persists a strip blob whose displayed tab is
---      a source-kind tab with NO sequence_id.
---   2. The blob round-trips back through the strip deserialize as the empty
---      source tab (kind=source, sequence_id=nil) and stays the displayed tab.

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_empty_source_tab_persists.lua ===")

local database        = require("core.database")
local timeline_state  = require("ui.timeline.timeline_state")
local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")

local DB = "/tmp/jve/test_empty_source_tab_persists.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))
local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d)
]], now, now))
conn:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES ('rec', 'p', 'Rec', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 300, %d, %d)
]], now, now))

timeline_state.reset()
timeline_state.init("rec", "p")

-- ── Step 1: show the empty source tab; the strip persists it ──
timeline_state.show_empty_source_tab()

assert(timeline_state.get_displayed_tab_kind() == "source",
    "after show_empty_source_tab, the displayed side must be source")
assert(timeline_state.get_displayed_tab_id() == nil,
    "the empty source tab has no sequence, so the displayed sequence id is nil")

local blob = database.get_project_setting("p", "timeline_tab_strip")
assert(type(blob) == "table" and type(blob.tabs) == "table",
    "show_empty_source_tab must persist the timeline_tab_strip blob")

-- Find the displayed tab in the blob; it must be the empty source tab.
assert(blob.displayed_tab_id, "blob must record which tab is displayed")
local displayed
for _, t in ipairs(blob.tabs) do
    if t.id == blob.displayed_tab_id then displayed = t end
end
assert(displayed, "blob displayed_tab_id matches no tab")
assert(displayed.kind == "source",
    "displayed tab must be a source tab; got " .. tostring(displayed.kind))
assert(displayed.sequence_id == nil or displayed.sequence_id == "",
    "the empty source tab must persist with NO sequence_id; got "
    .. tostring(displayed.sequence_id))
print("  ✓ show_empty_source_tab persists a sequence-less source tab as displayed")

-- The record tab the user left behind must still be in the blob (the source
-- tab only changes the displayed pointer, FR-005 — the active record stays).
local has_record = false
for _, t in ipairs(blob.tabs) do
    if t.kind == "record" and t.sequence_id == "rec" then has_record = true end
end
assert(has_record, "the record tab must remain in the strip when the empty "
    .. "source tab is displayed (active record is untouched)")
print("  ✓ the active record tab is preserved alongside the empty source tab")

-- ── Step 2: the blob round-trips back into the strip on restore ──
local strip = TimelineTabStrip.deserialize(blob)
local restored = strip:get_displayed()
assert(restored, "restored strip must have a displayed tab")
assert(restored:is_empty_source(),
    "the restored displayed tab must be the empty source tab (kind=source, "
    .. "sequence_id=nil)")
assert(strip:get_source_tab() == restored,
    "the empty source tab must be the strip's singleton source tab")
print("  ✓ blob deserializes back into the empty source tab as displayed")

print("\n✅ test_empty_source_tab_persists.lua passed")
