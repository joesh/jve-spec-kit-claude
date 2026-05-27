#!/usr/bin/env luajit

-- Regression: pressing X (MarkClipExtent) sets both mark_in and mark_out in
-- one user-visible action, but the executor previously dispatched SetMarkIn
-- and SetMarkOut as two independent commands without an undo group. Each
-- mark write landed on the history as its own entry, so one Ctrl-Z only
-- restored mark_out — the user had to undo twice to get back to the
-- pre-X state (Joe 2026-05-14).
--
-- Domain behavior: a single user action produces a single undo step.

require("test_env")

local database        = require("core.database")
local Sequence        = require("models.sequence")
local command_manager = require("core.command_manager")

print("=== test_mark_clip_extent_atomic_undo.lua ===")

local DB = "/tmp/jve/test_mark_clip_extent_atomic_undo.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)

local db = database.get_connection()
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

local seq = Sequence.create("S", "p",
    { fps_numerator = 24, fps_denominator = 1 }, 1920, 1080,
    { kind = "sequence", id = "s", audio_sample_rate = 48000 })
assert(seq:save())
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])
command_manager.init("s", "p")

-- Minimal timeline_state stub: one video clip at [120, 360) with playhead inside.
package.loaded["ui.timeline.timeline_state"] = {
    get_playhead_position = function() return 200 end,
    get_tab_strip = function()
        return require("test_env").make_strip_stub({
            active_sequence_id = "s",
            displayed_clips = { { id = "c1", track_id = "v1", sequence_start = 120, duration = 240 } },
        })
    end,
    get_project_id    = function() return "p" end,
    get_track_by_id   = function() return { track_type = "VIDEO", track_index = 1 } end,
    get_track_index   = function() return 1 end,
    get_selected_clips= function() return {} end,
    get_selected_edges= function() return {} end,
    get_selected_gaps = function() return {} end,
    set_playhead_position = function() end,
    reload_clips      = function() end,
    get_sequence_frame_rate = function() return { fps_numerator = 24, fps_denominator = 1 } end,
    set_selection = function() end,
    get_selection = function() return { clips = {}, edges = {}, gaps = {} } end,
    surface_playhead = function() end,
}

-- Pre-state: no marks.
local s0 = Sequence.load("s")
assert(s0.mark_in == nil and s0.mark_out == nil, "test setup: marks must start clear")

-- Single user action: X.
command_manager.begin_command_event("script")
local r = command_manager.execute("MarkClipExtent",
    { project_id = "p", sequence_id = "s" })
command_manager.end_command_event()
assert(r and (r == true or r.success), "MarkClipExtent failed")

local s1 = Sequence.load("s")
-- Inclusive last frame = 120+240-1 = 359, mark_out stored exclusive = 360.
assert(s1.mark_in  == 120, "test setup: mark_in must be 120; got "  .. tostring(s1.mark_in))
assert(s1.mark_out == 360, "test setup: mark_out must be 360; got " .. tostring(s1.mark_out))

-- ── The contract ──────────────────────────────────────────────────────────
-- One Ctrl-Z restores the pre-X state. With the bug, only one mark would
-- revert and a second undo would still be needed for the other.
local u = command_manager.undo()
assert(u and (u == true or u.success), "undo returned failure: " .. tostring(u and u.error_message))

local s2 = Sequence.load("s")
assert(s2.mark_in == nil and s2.mark_out == nil, string.format(
    "FAIL: a single undo must clear BOTH marks set by one X press. "
    .. "Got mark_in=%s mark_out=%s. This is the symptom of SetMarkIn and "
    .. "SetMarkOut landing as separate undo entries instead of one group.",
    tostring(s2.mark_in), tostring(s2.mark_out)))

print("  single undo restored both marks — OK")
print("\n✅ test_mark_clip_extent_atomic_undo.lua passed")
