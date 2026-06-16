#!/usr/bin/env luajit
--- Displayed tab kind (source vs record) survives quit/reopen.
---
--- Domain contract: if the user quits with the Source tab visible, the
--- next launch of the same project opens with the Source tab visible —
--- not the record tab. The whole tab strip (tab list + which side is
--- displayed) persists as ONE serialized blob (timeline_tab_strip), the
--- single source of truth for restore. The displayed side is read back as
--- the kind of the tab the blob's displayed pointer names.
---
--- This test exercises the WRITE side end-to-end against a real DB:
---   1. switch_to_source_tab(...) → blob's displayed tab kind == "source"
---   2. switch_to_record_tab(...) → blob's displayed tab kind == "record"

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_displayed_tab_kind_persists.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local DB = "/tmp/jve/test_displayed_tab_kind_persists.db"
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
conn:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES ('mst', 'p', 'M',   'master',   24, 1, NULL,  1920, 1080,
        0, 0, 300, %d, %d)
]], now, now))
-- Sanity: confirm the rows are loadable BEFORE invoking the switch path.
do
    local Sequence = require("models.sequence")
    assert(Sequence.load("rec"), "fixture: rec must load")
    assert(Sequence.load("mst"), "fixture: mst must load")
end

timeline_state.reset()
timeline_state.init("rec", "p")

-- Read the displayed side back from the persisted strip blob: the kind of
-- the tab the blob's displayed pointer names.
local function persisted_displayed_kind()
    local blob = database.get_project_setting("p", "timeline_tab_strip")
    assert(type(blob) == "table",
        "timeline_tab_strip blob must persist after a tab switch")
    assert(blob.displayed_tab_id,
        "blob must record which tab is displayed")
    for _, t in ipairs(blob.tabs) do
        if t.id == blob.displayed_tab_id then return t.kind end
    end
    error("blob displayed_tab_id matches no tab in the strip")
end

-- ── Case 1: switching to source tab persists displayed side = source ──
timeline_state.switch_to_source_tab("mst")
assert(persisted_displayed_kind() == "source", string.format(
    "switch_to_source_tab must persist the displayed side as source; got %s",
    tostring(persisted_displayed_kind())))
print("  ✓ switch_to_source_tab persists displayed side = source")

-- ── Case 2: switching back to record overwrites to record ──
timeline_state.switch_to_record_tab("rec")
assert(persisted_displayed_kind() == "record", string.format(
    "switch_to_record_tab must persist the displayed side as record; got %s",
    tostring(persisted_displayed_kind())))
print("  ✓ switch_to_record_tab persists displayed side = record")

print("\n✅ test_displayed_tab_kind_persists.lua passed")
