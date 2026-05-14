#!/usr/bin/env luajit

-- Every track-header button must be mappable to a keyboard shortcut, which
-- means every header action must go through command_manager.execute (the
-- keymap dispatcher's only entry point). The audio "W" waveform-display
-- toggle previously called track_state.set_waveform_enabled directly,
-- bypassing commands and the keymap layer (Joe 2026-05-14).
--
-- Domain behavior: executing ToggleTrackWaveformDisplay flips the on-screen
-- waveform-display flag for one audio track; calling it again restores the
-- original state. Non-undoable (UI state, not project data).

require("test_env")

print("=== test_toggle_track_waveform_display_command.lua ===")

local database        = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_toggle_track_waveform_display.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)

local db = database.get_connection()
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES
      ('a1', 's', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1),
      ('v1', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0, 'off', 1);
]], now, now, now, now))

command_manager.init("s", "p")
local track_state = require("ui.timeline.state.track_state")

-- ── Default: audio waveform-display is ON ─────────────────────────────────
assert(track_state.get_waveform_enabled("a1") == true,
    "test setup: audio waveform should default ON")

-- ── Toggle OFF ────────────────────────────────────────────────────────────
local r1 = command_manager.execute("ToggleTrackWaveformDisplay",
    { track_id = "a1", project_id = "p" })
assert(r1 and (r1 == true or r1.success), "ToggleTrackWaveformDisplay (off) failed: "
    .. tostring(r1 and r1.error_message))
assert(track_state.get_waveform_enabled("a1") == false,
    "FAIL: waveform should be OFF after first toggle")
print("  toggle 1 flipped to OFF — OK")

-- ── Toggle ON again ───────────────────────────────────────────────────────
local r2 = command_manager.execute("ToggleTrackWaveformDisplay",
    { track_id = "a1", project_id = "p" })
assert(r2 and (r2 == true or r2.success))
assert(track_state.get_waveform_enabled("a1") == true,
    "FAIL: waveform should return to ON after second toggle")
print("  toggle 2 flipped back to ON — OK")

-- ── Explicit value form ───────────────────────────────────────────────────
command_manager.execute("ToggleTrackWaveformDisplay",
    { track_id = "a1", project_id = "p", value = false })
assert(track_state.get_waveform_enabled("a1") == false,
    "FAIL: explicit value=false must set OFF regardless of prior state")
print("  explicit value param overrides toggle — OK")

-- ── Video tracks reject the command (only audio has the toggle) ──────────
local ok, err = pcall(function()
    command_manager.execute("ToggleTrackWaveformDisplay",
        { track_id = "v1", project_id = "p" })
end)
-- Either the call returns failure or asserts inside; both surface the bug.
if ok then
    -- If no Lua error, then either the command itself returned failure (acceptable)
    -- OR it silently mutated nothing (acceptable since video tracks have no flag,
    -- but in that case waveform must still be reported as false for video).
    assert(track_state.get_waveform_enabled("v1") == false,
        "FAIL: video tracks must never expose a waveform-display toggle as ON")
else
    assert(err, "pcall returned !ok with no error")
end
print("  video track guard holds — OK")

print("\n✅ test_toggle_track_waveform_display_command.lua passed")
