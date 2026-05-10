#!/usr/bin/env luajit

-- Phase 2a of 015 refactor — TimelineTabStrip instance lives in timeline_state.
--
-- Domain: timeline_state exposes a TimelineTabStrip via get_tab_strip().
-- The strip is reset (replaced by a fresh empty one) on project_changed.
-- This is the entry point for Phase 2b consumer migration; without an
-- accessible strip the abstraction is unreachable from the rest of the app.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Signals = require("core.signals")
local timeline_state = require("ui.timeline.timeline_state")
local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")

print("=== test_timeline_state_tab_strip.lua ===")

-- ── DB setup ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_timeline_state_tab_strip.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p1', 'P1', 'resample', %d, %d),
           ('p2', 'P2', 'resample', %d, %d)
]], now, now, now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('seq1', 'p1', 'S1', 'nested', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now))

-- ── 1. strip is exposed and is a real TimelineTabStrip ────────────────────
local strip = timeline_state.get_tab_strip()
assert(type(strip) == "table", "get_tab_strip returns a table")
assert(getmetatable(strip) == TimelineTabStrip,
    "strip is a TimelineTabStrip instance (correct metatable)")
print("✓ strip is exposed via get_tab_strip()")

-- ── 2. strip is usable: can open and switch tabs ──────────────────────────
local tab = strip:open_record_tab("seq1")
strip:switch_active_record(tab)
assert(strip:get_active_record() == tab, "strip pointer ops work")
assert(strip:get_displayed() == tab, "switch_active_record updates displayed")
print("✓ strip is functional through the accessor")

-- ── 3. project_changed resets the strip to a fresh empty one ──────────────
Signals.emit("project_changed", "p2")
local strip_after = timeline_state.get_tab_strip()
assert(strip_after ~= strip,
    "strip is replaced by a fresh instance on project_changed")
assert(#strip_after.tabs == 0, "fresh strip has no tabs")
assert(strip_after:get_displayed() == nil, "fresh strip has no displayed pointer")
assert(strip_after:get_active_record() == nil, "fresh strip has no active pointer")
print("✓ project_changed replaces the strip with a fresh empty one")

-- ── 4. switch_to_record_tab keeps the strip pointers in sync ──────────────
-- Need a real sequence under the post-project_changed strip; insert one.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('seq_p2_a', 'p2', 'A', 'nested', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
           ('seq_p2_b', 'p2', 'B', 'nested', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
           ('seq_p2_src', 'p2', 'S', 'master', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now, now, now, now, now))

timeline_state.init("seq_p2_a", "p2")
timeline_state.switch_to_record_tab("seq_p2_a")
local strip_now = timeline_state.get_tab_strip()
local active = strip_now:get_active_record()
assert(active and active.sequence_id == "seq_p2_a",
    "switch_to_record_tab sets strip active_record_tab to that seq")
assert(strip_now:get_displayed() == active,
    "switch_to_record_tab makes the same tab displayed (FR-004)")

timeline_state.switch_to_record_tab("seq_p2_b")
active = strip_now:get_active_record()
assert(active and active.sequence_id == "seq_p2_b",
    "switching to a different record tab updates active to the new seq")
print("✓ switch_to_record_tab syncs strip active+displayed pointers")

-- ── 5. switch_to_source_tab updates displayed only (FR-005) ───────────────
local active_before = strip_now:get_active_record()
timeline_state.switch_to_source_tab("seq_p2_src")
local source_tab = strip_now:get_source_tab()
assert(source_tab and source_tab.sequence_id == "seq_p2_src",
    "switch_to_source_tab opens source tab for the seq")
assert(strip_now:get_displayed() == source_tab,
    "switch_to_source_tab makes source the displayed tab")
assert(strip_now:get_active_record() == active_before,
    "switch_to_source_tab does NOT touch active_record_tab (FR-005)")
print("✓ switch_to_source_tab syncs strip displayed only (FR-005)")

print("✅ test_timeline_state_tab_strip.lua passed")
