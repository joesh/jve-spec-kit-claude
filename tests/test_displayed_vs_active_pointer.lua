#!/usr/bin/env luajit

-- T016 (015) — FR-005: displayed_tab_id and active_sequence_id are INDEPENDENT.
--
-- Domain: the timeline panel maintains two separate pointers:
--   active_sequence_id — the Record sequence that edit commands target; NEVER
--     changes on a SourceTab click.
--   displayed_tab_id   — the tab whose content the body renders; changes on
--     every tab switch.
--
-- Scenarios verified:
--   (a) After loading a Record sequence, both pointers equal that sequence.
--   (b) Switching to Source tab changes ONLY displayed_tab_id.
--       displayed_tab_changed emitted; active_sequence_changed NOT emitted.
--   (c) Same-tab click is a no-op: no signal emitted.
--   (d) Switch back to SAME Record tab: only displayed_tab_changed fires
--       (active_sequence_id was already that sequence — no "change").
--   (e) Switch between two DIFFERENT Record sequences: both signals fire.
--   (f) While Source tab is displayed, get_sequence_id() and
--       get_active_sequence_id() both return the Record sequence — proves
--       that edit commands target the correct sequence.
--   (g) Assert guards on nil/empty args.
--
-- Expected FAIL today: switch_to_source_tab / switch_to_record_tab /
-- get_active_sequence_id / get_displayed_tab_id do not exist.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")
-- switch_to_source_tab now binds the source engine eagerly (no silent
-- pcall fallback). Tests exercising tab switches need the qt stub.
require("helpers.test_017_setup").install_qt_stub()

local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Signals         = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_displayed_vs_active_pointer.lua ===")

-- ── DB setup ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_displayed_vs_active_ptr.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
-- Project
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))
-- Record sequence 1
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec1', 'proj', 'Timeline 1', 'sequence',
        24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now))
-- Record sequence 2 (for scenario e: switch between two record sequences)
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec2', 'proj', 'Timeline 2', 'sequence',
        24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now))
-- Source (master) sequence
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('src_seq', 'proj', 'master_clip_A', 'master',
        24, 1, NULL, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now))

command_manager.init("rec1", "proj")

-- ── Signal observation ────────────────────────────────────────────────────
local displayed_log = {}
local active_log    = {}
Signals.connect("displayed_tab_changed", function(new_id, prev_id)
    table.insert(displayed_log, {new=new_id, prev=prev_id})
end)
Signals.connect("active_sequence_changed", function(new_id, prev_id)
    table.insert(active_log, {new=new_id, prev=prev_id})
end)

-- ── Verify new API exists ─────────────────────────────────────────────────
assert(type(timeline_state.get_active_sequence_id) == "function",
    "FAIL: timeline_state.get_active_sequence_id missing — T034 not implemented")
assert(type(timeline_state.get_displayed_tab_id) == "function",
    "FAIL: timeline_state.get_displayed_tab_id missing — T034 not implemented")
assert(type(timeline_state.switch_to_source_tab) == "function",
    "FAIL: timeline_state.switch_to_source_tab missing — T034 not implemented")
assert(type(timeline_state.switch_to_record_tab) == "function",
    "FAIL: timeline_state.switch_to_record_tab missing — T034 not implemented")

-- ── (a) After loading a Record sequence, both pointers equal rec1 ─────────
print("-- (a) init with Record sequence --")
timeline_state.init("rec1", "proj")
assert(timeline_state.get_active_sequence_id() == "rec1", string.format(
    "FAIL: active_sequence_id=%s, expected rec1",
    tostring(timeline_state.get_active_sequence_id())))
assert(timeline_state.get_displayed_tab_id() == "rec1", string.format(
    "FAIL: displayed_tab_id=%s, expected rec1",
    tostring(timeline_state.get_displayed_tab_id())))
assert(timeline_state.get_sequence_id() == "rec1",
    "FAIL: get_sequence_id() backward-compat alias must still work")
print("  active=rec1, displayed=rec1 — OK")

-- ── (b) Switch to Source tab: only displayed_tab_id changes ───────────────
print("-- (b) switch_to_source_tab --")
local nd0, na0 = #displayed_log, #active_log

timeline_state.switch_to_source_tab("src_seq")

assert(timeline_state.get_displayed_tab_id() == "src_seq", string.format(
    "FAIL: displayed_tab_id=%s after source switch, expected src_seq",
    tostring(timeline_state.get_displayed_tab_id())))
assert(timeline_state.get_active_sequence_id() == "rec1", string.format(
    "FAIL: active_sequence_id=%s after source switch — must stay rec1 (FR-005)",
    tostring(timeline_state.get_active_sequence_id())))
assert(#displayed_log == nd0 + 1,
    "FAIL: displayed_tab_changed must fire on source-tab switch")
assert(#active_log == na0,
    "FAIL: active_sequence_changed must NOT fire on source-tab switch (FR-005)")

local ev = displayed_log[#displayed_log]
assert(ev.new == "src_seq" and ev.prev == "rec1", string.format(
    "FAIL: displayed_tab_changed payload — new=%s prev=%s",
    tostring(ev.new), tostring(ev.prev)))
print("  displayed=src_seq, active=rec1, displayed_tab_changed only — OK")

-- ── (c) Same-tab click is a no-op ─────────────────────────────────────────
print("-- (c) no-op same-tab click --")
local nd1, na1 = #displayed_log, #active_log

timeline_state.switch_to_source_tab("src_seq")

assert(#displayed_log == nd1, "FAIL: displayed_tab_changed must NOT fire on no-op")
assert(#active_log == na1,    "FAIL: active_sequence_changed must NOT fire on no-op")
print("  no signal emitted on no-op — OK")

-- ── (d) Switch back to SAME Record tab: only displayed_tab_changed fires ───
--  active_sequence_id was already rec1 — no "change" in the active sequence.
print("-- (d) switch back to same Record tab --")
local nd2, na2 = #displayed_log, #active_log

timeline_state.switch_to_record_tab("rec1")

assert(timeline_state.get_displayed_tab_id() == "rec1", string.format(
    "FAIL: displayed_tab_id=%s after record switch, expected rec1",
    tostring(timeline_state.get_displayed_tab_id())))
assert(timeline_state.get_active_sequence_id() == "rec1", string.format(
    "FAIL: active_sequence_id=%s after record switch, expected rec1",
    tostring(timeline_state.get_active_sequence_id())))
assert(#displayed_log == nd2 + 1,
    "FAIL: displayed_tab_changed must fire (tab moved from src to rec)")
assert(#active_log == na2,
    "FAIL: active_sequence_changed must NOT fire — active seq was already rec1")

local dv = displayed_log[#displayed_log]
assert(dv.new == "rec1" and dv.prev == "src_seq", string.format(
    "FAIL: displayed_tab_changed payload — new=%s prev=%s",
    tostring(dv.new), tostring(dv.prev)))
print("  displayed_tab_changed fired, active_sequence_changed silent — OK")

-- ── (e) Switch between two DIFFERENT Record sequences: both signals fire ───
print("-- (e) switch between two Record sequences --")
-- Currently on rec1. Switch to rec2.
local nd3, na3 = #displayed_log, #active_log

timeline_state.switch_to_record_tab("rec2")

assert(timeline_state.get_displayed_tab_id() == "rec2",
    "FAIL: displayed_tab_id must be rec2 after switching to rec2")
assert(timeline_state.get_active_sequence_id() == "rec2",
    "FAIL: active_sequence_id must be rec2 after switching to rec2")
assert(#displayed_log == nd3 + 1,
    "FAIL: displayed_tab_changed must fire on Record-to-Record switch")
assert(#active_log == na3 + 1,
    "FAIL: active_sequence_changed must fire when active sequence changes")

local dev2 = displayed_log[#displayed_log]
assert(dev2.new == "rec2" and dev2.prev == "rec1", string.format(
    "FAIL: displayed_tab_changed payload — new=%s prev=%s",
    tostring(dev2.new), tostring(dev2.prev)))
local aev2 = active_log[#active_log]
assert(aev2.new == "rec2" and aev2.prev == "rec1", string.format(
    "FAIL: active_sequence_changed payload — new=%s prev=%s",
    tostring(aev2.new), tostring(aev2.prev)))
print("  both signals fired with correct payloads — OK")

-- ── (f) Edit routing: active_sequence_id is Record while Source tab shown ─
print("-- (f) edit routing while Source tab displayed --")
-- Re-init to rec1 so we have a clean active state.
timeline_state.init("rec1", "proj")
timeline_state.switch_to_source_tab("src_seq")

assert(timeline_state.get_displayed_tab_id() == "src_seq",
    "FAIL: precondition — source tab should be displayed")
assert(timeline_state.get_sequence_id() == "rec1",
    "FAIL: get_sequence_id() must return Record seq while Source tab is displayed")
assert(timeline_state.get_active_sequence_id() == "rec1",
    "FAIL: get_active_sequence_id() must return Record seq while Source tab is displayed")
print("  get_sequence_id()=rec1 while displayed=src_seq — OK")

-- ── (g) Assert guards on nil / empty args ─────────────────────────────────
print("-- (g) assert guards --")
local ok1 = pcall(timeline_state.switch_to_source_tab, nil)
assert(not ok1, "FAIL: switch_to_source_tab(nil) must assert")
local ok2 = pcall(timeline_state.switch_to_source_tab, "")
assert(not ok2, "FAIL: switch_to_source_tab('') must assert")
local ok3 = pcall(timeline_state.switch_to_record_tab, nil)
assert(not ok3, "FAIL: switch_to_record_tab(nil) must assert")
local ok4 = pcall(timeline_state.switch_to_record_tab, "")
assert(not ok4, "FAIL: switch_to_record_tab('') must assert")
print("  nil/empty args assert — OK")

print("\n✅ test_displayed_vs_active_pointer.lua passed")
