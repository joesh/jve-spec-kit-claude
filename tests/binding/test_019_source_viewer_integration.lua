--- 019 integration test — full user-flow through the live-bound
--- source-viewer feature.
---
--- NOT a smoke test by the strict definition (see
--- feedback_smoke_tests_real_keypress_only.md): this dispatches commands
--- via `command_manager.execute_interactive(...)` rather than driving
--- through real OS key events. Doing the latter requires the external
--- test-runner architecture in spec 020 Phase 1 (FR-101) — when that
--- lands, the file is renamed back to _smoke and rewritten to use
--- foregrounded JVE + CGEventPost from outside the process.
---
--- What it covers: every 019 codepath end-to-end as one continuous
--- journey (no per-scenario teardown) — signal payload, mode transition,
--- command dispatch, monitor bind, selection_hub publish,
--- effective_source override channel. Catches wiring regressions even
--- when focused unit tests stay green. Boundaries and error cases live
--- in the focused tests (test_source_viewer_load_clip,
--- test_effective_source, test_clear_marks_disabled_in_live_bound,
--- test_overwrite_trim_edge, test_timeline_double_click_dispatches_open_clip).

require('test_env')
local ui = require("integration.ui_test_env")

print("=== test_019_source_viewer_integration ===")

local DB = "/tmp/jve/test_019_source_viewer_integration.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "019 Smoke",
})

local database       = require("core.database")
local Track          = require("models.track")
local source_viewer  = require("ui.source_viewer")
local edit_mode      = require("core.edit_mode")
local panel_manager  = require("ui.panel_manager")
local effective_src  = require("core.effective_source")
local Clip           = require("models.clip")

-- The template's Sequence 1 IS the user's record timeline. Find its V1.
local rec_seq_id = info.sequences[1].id
local rec_v1_id  = assert(Track.find_at(rec_seq_id, "VIDEO", 1),
    "template Sequence 1 missing V1 track")

-- Add a master sequence + media + media_ref + a clip on rec/V1 that
-- references msa. These rows model "user imported a master and dropped
-- it onto the record". The clip has source_in=100, source_out=300 so
-- trim deltas in scenarios 5-6 are arithmetically observable.
local TC_ORIGIN_24FPS = 1324752  -- 15:19:58:00 @ 24fps — camera-original
local db = database.get_connection()
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('msa', '%s', 'A012', 'master', 24, 1, NULL, 1920, 1080,
            0, 0, 300, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('av1', 'msa', 'V1', 'VIDEO', 1, 1),
           ('aa1', 'msa', 'A1', 'AUDIO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        width, height, created_at, modified_at)
    VALUES ('ma', '%s', 'A012', '/tmp/A012.mov', 1200, 24, 1, 48000, 2,
            1920, 1080, %d, %d);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames, audio_sample_rate,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mra_v', '%s', 'msa', 'av1', 'ma', 0, 1200, %d, 1200,
            NULL, 1, 1.0, 0, %d, %d);

    INSERT INTO clips (id, project_id, owner_sequence_id, sequence_id,
        track_id, source_in_frame, source_out_frame, sequence_start_frame,
        duration_frames, fps_mismatch_policy, name, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('c1', '%s', '%s', 'msa', '%s', 100, 300, 0, 200,
            'resample', 'AlphaClip', 1, 1.0, 0, %d, %d);
]], info.project.id, now, now,
    info.project.id, now, now,
    info.project.id, TC_ORIGIN_24FPS, now, now,
    info.project.id, rec_seq_id, rec_v1_id, now, now)))

ui.pump(200)

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

print("\n-- 5. SetMarkAndTrimIfClip 'in' (the I-key @source_monitor path) → OverwriteTrimEdge in live-bound --")
src_monitor.engine:seek(130)
ui.pump(50)

require("core.command_manager").execute_interactive("SetMarkAndTrimIfClip", {
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

print("")
if #failures == 0 then
    print("✅ test_019_source_viewer_integration passed")
else
    error(string.format("test_019_source_viewer_integration: %d broken behavior(s): %s",
        #failures, table.concat(failures, "; ")))
end
