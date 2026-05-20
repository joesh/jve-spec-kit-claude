--- 019 smoke test: full user-flow through the live-bound source-viewer feature.
--
-- Runs inside `./build/bin/JVEEditor --test` against the real Qt + UI stack
-- with a real project DB. Drives every 019 codepath end-to-end as one
-- continuous user journey (no per-scenario db tear-down) so any wiring
-- regression — signal payload, mode transition, command dispatch, monitor
-- bind, selection_hub publish, effective_source override channel — shows
-- up here even if the focused unit tests are green.
--
-- Smoke, not exhaustive — boundaries and error cases are covered by the
-- focused tests (test_source_viewer_load_clip, test_effective_source,
-- test_clear_marks_disabled_in_live_bound, test_overwrite_trim_edge,
-- test_timeline_double_click_dispatches_open_clip). This pins the through-line.

local saved_home = os.getenv("HOME") or ""
local ffi = require("ffi")
ffi.cdef[[ int setenv(const char *name, const char *value, int overwrite); ]]
ffi.C.setenv("HOME", "/tmp/jve_test_home", 1)
os.execute("mkdir -p /tmp/jve_test_home/.jve")

print("=== test_019_source_viewer_smoke ===")

-- ── Seed DB ──────────────────────────────────────────────────────────────────

local DB = "/tmp/jve/test_019_smoke.jvp"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")

local database = require("core.database")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local TC_ORIGIN_24FPS = 1324752  -- 15:19:58:00 @ 24fps — camera-original

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('proj', '019 Smoke', 'resample', %d, %d,
            '{"last_open_sequence_id":"rec","open_sequence_ids":["rec"],"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}');

    -- Master sequence "msa" + record sequence "rec".
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES
      ('rec', 'proj', 'Record', 'sequence', 24, 1, 48000, 1920, 1080, 50, 0, 1500, %d, %d),
      ('msa', 'proj', 'A012',   'master',   24, 1, NULL,  1920, 1080, 0,  0,  300,  %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rv1', 'rec', 'V1', 'VIDEO', 1, 1),
      ('ra1', 'rec', 'A1', 'AUDIO', 1, 1),
      ('av1', 'msa', 'V1', 'VIDEO', 1, 1),
      ('aa1', 'msa', 'A1', 'AUDIO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        width, height, created_at, modified_at)
    VALUES ('ma', 'proj', 'A012', '/tmp/A012.mov', 1200, 24, 1, 48000, 2, 1920, 1080, %d, %d);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames, audio_sample_rate,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      ('mra_v', 'proj', 'msa', 'av1', 'ma', 0, 1200, %d, 1200, NULL, 1, 1.0, 0, %d, %d);

    -- A real clip on the record timeline, source_in non-zero so trim
    -- moves are observably distinct from "clip at start of source".
    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, fps_mismatch_policy, name, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('c1', 'proj', 'rec', 'msa', 'rv1', 100, 300, 0, 200,
            'resample', 'AlphaClip', 1, 1.0, 0, %d, %d);
]],
    now, now,                                  -- projects
    now, now, now, now,                        -- 2 sequences
    now, now,                                  -- 1 media
    TC_ORIGIN_24FPS, now, now,                 -- mra_v
    now, now))                                 -- c1

database.shutdown()

-- ── Launch the full UI ───────────────────────────────────────────────────────

ffi.C.setenv("JVE_PROJECT_PATH", DB, 1)
-- Use the REAL home (captured before HOME was clobbered to the test dir)
-- so .luarocks modules like `lxp` are reachable.
package.cpath = package.cpath .. ';' .. saved_home .. '/.luarocks/lib/lua/5.1/?.so'
package.path  = package.path  .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?.lua'
package.path  = package.path  .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?/init.lua'

local app = require("ui.layout")
assert(app and app.main_window, "layout.lua did not return main_window")

local ui = require("integration.ui_test_env")
ui.pump(300)

local source_viewer  = require("ui.source_viewer")
local edit_mode      = require("core.edit_mode")
local panel_manager  = require("ui.panel_manager")
local effective_src  = require("core.effective_source")
local Clip           = require("models.clip")

-- Failure-collecting checks: see EVERY broken assertion in one run.
local failures = {}
local function check(label, ok, detail)
    if ok then
        print(string.format("  ✓ %s", label))
    else
        print(string.format("  ✗ %s — %s", label, detail or ""))
        table.insert(failures, label)
    end
end

-- ── Scenario 1: neutral start ────────────────────────────────────────────────

print("\n-- 1. source viewer starts in neutral mode --")
check("mode == neutral at boot",
    source_viewer.get_mode() == "neutral",
    "got " .. tostring(source_viewer.get_mode()))

-- ── Scenario 2: staged-mode load_master_clip ─────────────────────────────────

print("\n-- 2. load_master_clip(msa) → staged_sequence --")
source_viewer.load_master_clip("msa", { skip_focus = true })
ui.pump(200)

check("mode == staged_sequence",
    source_viewer.get_mode() == "staged_sequence",
    "got " .. tostring(source_viewer.get_mode()))

local src_monitor = panel_manager.get_sequence_monitor("source_monitor")
check("source_monitor bound to msa",
    src_monitor.sequence_id == "msa",
    "got " .. tostring(src_monitor.sequence_id))

local eff_seq = effective_src.get()
check("effective_source.get() == 'msa' after staged load",
    eff_seq == "msa",
    "got " .. tostring(eff_seq))

-- ── Scenario 3: live-bound mode via load_clip ────────────────────────────────

print("\n-- 3. load_clip(c1) → live_bound_clip --")
source_viewer.load_clip("c1", { skip_focus = true })
ui.pump(200)

check("mode == live_bound_clip",
    source_viewer.get_mode() == "live_bound_clip",
    "got " .. tostring(source_viewer.get_mode()))

check("source_monitor bound to clip's SOURCE sequence (msa)",
    src_monitor.sequence_id == "msa",
    "got " .. tostring(src_monitor.sequence_id))

-- effective_source returns the triple in live-bound mode.
local seq3, in3, out3 = effective_src.get()
check("effective_source.get() returns (msa, 100, 300) — the clip's source range",
    seq3 == "msa" and in3 == 100 and out3 == 300,
    string.format("got (%s, %s, %s)", tostring(seq3), tostring(in3), tostring(out3)))

-- ── Scenario 4: trim-mode toggle (non-undoable) ──────────────────────────────

print("\n-- 4. ToggleTrimMode flips edit_mode --")
local mode_before = edit_mode.get_trim_mode()
check("default trim mode is overwrite",
    mode_before == "overwrite",
    "got " .. tostring(mode_before))

require("core.command_manager").execute_interactive("ToggleTrimMode", {})
ui.pump(50)
check("trim mode flipped to ripple",
    edit_mode.get_trim_mode() == "ripple",
    "got " .. tostring(edit_mode.get_trim_mode()))

require("core.command_manager").execute_interactive("ToggleTrimMode", {})
ui.pump(50)
check("trim mode toggled back to overwrite",
    edit_mode.get_trim_mode() == "overwrite",
    "got " .. tostring(edit_mode.get_trim_mode()))

-- ── Scenario 5: I-key dispatch in live-bound mode → OverwriteTrimEdge fires ──
--   Default trim mode is overwrite; with playhead parked at 130 (set on the
--   source monitor's engine first), pressing I should shrink the head by 30
--   frames (delta = 130 - 100). Dispatch via the SAME route the keymap takes:
--   SetMark command (NOT a direct handle_mark_key call) — that's the path
--   the buggy 2026-05-20 master shipped with SetMark mutating the sequence
--   row instead of trimming the clip.

print("\n-- 5. SetMark 'in' (the I-key keymap path) → OverwriteTrimEdge in live-bound --")
src_monitor.engine:seek(130)
ui.pump(50)

require("core.command_manager").execute_interactive("SetMark", {
    _positional = { "in" },
})
ui.pump(100)

local c1_after = Clip.load("c1")
check("clip.source_in advanced to 130 (was 100, delta=+30)",
    c1_after.source_in == 130,
    "got " .. tostring(c1_after.source_in))
check("clip.source_out unchanged at 300",
    c1_after.source_out == 300,
    "got " .. tostring(c1_after.source_out))
check("clip.duration shrunk to 170 (was 200)",
    c1_after.duration == 170,
    "got " .. tostring(c1_after.duration))

-- ── Scenario 6: live-bound retrim updates effective_source override ──────────

local seq6, in6, out6 = effective_src.get()
check("effective_source override updated to new (130, 300) post-trim",
    seq6 == "msa" and in6 == 130 and out6 == 300,
    string.format("got (%s, %s, %s)", tostring(seq6), tostring(in6), tostring(out6)))

-- ── Scenario 7: unload returns to neutral ────────────────────────────────────

print("\n-- 7. unload → neutral --")
source_viewer.unload()
ui.pump(100)
check("mode == neutral after unload",
    source_viewer.get_mode() == "neutral",
    "got " .. tostring(source_viewer.get_mode()))
check("effective_source.get() == nil after unload",
    effective_src.get() == nil,
    "got " .. tostring(effective_src.get()))

-- ── Report ───────────────────────────────────────────────────────────────────

print("")
if #failures == 0 then
    print("✅ test_019_source_viewer_smoke passed")
else
    print(string.format("❌ test_019_source_viewer_smoke FAILED — %d broken behavior(s):", #failures))
    for _, label in ipairs(failures) do
        print("    - " .. label)
    end
    os.exit(1)
end
