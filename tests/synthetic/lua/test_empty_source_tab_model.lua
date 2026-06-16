#!/usr/bin/env luajit

-- Empty Source tab — the source side of the timeline can be DISPLAYED while
-- the source monitor holds nothing loaded. Domain: pressing the source/record
-- toggle with no master loaded shows a Source tab with a blank body (not a
-- blanked timeline that looks like the record sequence lost its content).
--
-- The empty source tab is a real, first-class tab: kind="source",
-- sequence_id=nil. It is the SAME singleton slot the loaded source tab uses —
-- loading a master into the source monitor upgrades the empty tab in place.
--
-- Because tab identity + membership now persist as the strip's serialized
-- blob (single source of truth), the empty source tab must round-trip through
-- serialize/deserialize so quit/restart restores it like any other tab.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local TimelineTab = require("ui.timeline.timeline_tab")
local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")

print("=== test_empty_source_tab_model.lua ===")

-- ── DB setup: one record sequence + one master (for the upgrade case) ──────
local DB = "/tmp/jve/test_empty_source_tab_model.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec1', 'proj', 'Rec 1', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
           ('src',  'proj', 'Src',   'master',   24, 1, NULL,  1920, 1080, 0, 0, 300, %d, %d)
]], now, now, now, now))

-- ── 1. TimelineTab.new_empty_source — a sequence-less source tab ───────────
local empty = TimelineTab.new_empty_source()
assert(empty.kind == "source", "empty source tab is kind=source")
assert(empty.sequence_id == nil, "empty source tab has no sequence_id")
-- A reader asking for marks on an empty source must get nils, not an assert
-- (no sequence row to read marks from). The body is blank, there are no marks.
local marks = empty:get_marks()
assert(marks.in_frame == nil and marks.out_frame == nil,
    "empty source tab has no marks (nil in/out), must not assert")
-- Iterating the (empty) cache must be safe — blank-panel semantics.
assert(type(empty.cache.clips) == "table" and #empty.cache.clips == 0,
    "empty source tab cache iterates empty")
print("✓ TimelineTab.new_empty_source: seq-less, nil marks, empty cache")

-- ── 2. serialize omits sequence_id; deserialize reconstructs empty source ──
local blob = empty:serialize()
assert(blob.kind == "source", "serialized kind preserved")
assert(blob.sequence_id == nil, "serialized empty source has no sequence_id")
local round = TimelineTab.deserialize(blob)
assert(round.kind == "source" and round.sequence_id == nil,
    "deserialize reconstructs the empty source tab (no Sequence.load)")
print("✓ empty source tab round-trips through tab serialize/deserialize")

-- ── 3. strip:open_empty_source_tab — singleton, first, displayed-only ──────
local strip = TimelineTabStrip.new()
local rec = strip:open_record_tab("rec1")     -- auto active+displayed
local es = strip:open_empty_source_tab()
assert(strip:get_source_tab() == es, "empty source tab IS the source singleton")
assert(strip.tabs[1] == es, "source tab is first (F1 singleton placement)")
assert(es.sequence_id == nil, "still sequence-less in the strip")
-- Opening the source side must NOT yank the active record (FR-005).
assert(strip:get_active_record() == rec, "active record unchanged by opening source")
-- Showing the empty source side: displayed→source, active still the record.
strip:switch_displayed(es)
assert(strip:get_displayed() == es, "empty source can be displayed")
assert(strip:get_active_record() == rec, "active record still the record tab")
print("✓ strip:open_empty_source_tab singleton + displayed-only switch")

-- ── 4. opening a real master upgrades the empty source tab IN PLACE ────────
-- (loading the source monitor while the empty tab is shown — same singleton).
local upgraded = strip:open_source_tab("src")
assert(upgraded == es, "open_source_tab reuses the empty source singleton (in-place)")
assert(es.sequence_id == "src", "empty source tab upgraded to the loaded master")
assert(strip:get_source_tab() == es, "still the singleton, now loaded")
print("✓ loading a master upgrades the empty source tab in place")

-- ── 5. strip round-trip with the empty source tab DISPLAYED ────────────────
strip = TimelineTabStrip.new()
local rec_b = strip:open_record_tab("rec1")
local es2 = strip:open_empty_source_tab()
strip:switch_active_record(rec_b)   -- active+displayed = rec_b
strip:switch_displayed(es2)         -- displayed = empty source, active = rec_b

local s_blob = strip:serialize()
local restored = TimelineTabStrip.deserialize(s_blob)
assert(#restored.tabs == 2, "tab count preserved (record + empty source)")
assert(restored.tabs[1].kind == "source" and restored.tabs[1].sequence_id == nil,
    "empty source tab restored, still first, still sequence-less")
assert(restored:get_source_tab() ~= nil, "source singleton tracked after deserialize")
assert(restored:get_displayed().id == es2.id, "displayed=empty-source restored by id")
assert(restored:get_active_record().id == rec_b.id, "active record restored by id")
-- The restored record tab still hydrates its cache from the DB; the empty
-- source tab must NOT (it has no sequence to load) and must not assert.
for _, t in ipairs(restored.tabs) do
    if t.kind == "record" then
        assert(type(t.cache.sequence_frame_rate) == "table",
            "record tab cache hydrated on deserialize")
    else
        assert(t.sequence_id == nil and t.cache.sequence_frame_rate == nil,
            "empty source tab stays unloaded (no Sequence.load on deserialize)")
    end
end
print("✓ strip round-trip with empty source tab displayed")

print("✅ test_empty_source_tab_model.lua passed")
