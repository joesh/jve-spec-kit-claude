-- Integration: ShowSourceTab + ToggleSourceRecordTab with an empty
-- source viewer must blank the timeline body — never auto-seed a
-- random project master from the DB. (TSO 2026-05-17 retired that
-- "fabricated user intent" path.)
--
-- Replaces the stub-based test of the same name. Runs under
-- JVEEditor --test with real SequenceMonitor + real source_viewer;
-- the auto-seed regression is caught by observing that the source
-- monitor's sequence_id stays nil through both commands.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_show_source_tab_empty_blanks_body.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")

-- ---------------------------------------------------------------------
-- DB: rec sequence with one real clip + a "bait" master that an
-- auto-seed regression would pick up.
-- ---------------------------------------------------------------------
local DB = "/tmp/jve/test_show_source_tab_empty_blanks_body_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":25,"den":1}}',
              %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
      VALUES ('rec', 'proj', 'Rec', 'sequence', 25, 1, 48000, 1920, 1080,
              0, 0, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('rec_v1', 'rec', 'V1', 'VIDEO', 1, 1);

    -- Bait master: present in the DB so an auto-seed regression would
    -- find SOMETHING to load. The test fails if the source monitor
    -- ends up holding this id.
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        width, height, metadata, created_at, modified_at)
      VALUES ('m_random', 'proj', 'RandomClip.mov', '/tmp/random.mov', 100,
              25, 1, 48000, 0, 1920, 1080,
              '{"start_tc_value":0,"start_tc_rate":25}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
      VALUES ('master_random', 'proj', 'RandomClip', 'master', 25, 1, NULL,
              1920, 1080, 0, 0, 0, 100, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('rand_v1', 'master_random', 'V1', 'VIDEO', 1, 1);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
      VALUES ('mr_rand', 'proj', 'master_random', 'rand_v1', 'm_random',
              0, 100, 0, 100, 1, 1.0, 0, %d, %d);

    INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
        sequence_id, name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, master_layer_track_id,
        fps_mismatch_policy, enabled, volume, playhead_frame,
        created_at, modified_at)
      VALUES ('rec_clip1', 'proj', 'rec', 'rec_v1', 'master_random',
              'RecClip', 10, 30, 0, 30, NULL, 'passthrough', 1, 1.0, 0,
              %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now)))

-- Real monitors. source_mon.sequence_id stays nil throughout (the
-- "empty source viewer" precondition).
local mons = ienv.setup_monitor_panels({ kinds = "both" })
local source_mon = mons.source
assert(source_mon.sequence_id == nil,
    "fixture: source monitor starts empty (no master loaded)")

-- ---------------------------------------------------------------------
-- Fixture helper: rec is the active+displayed tab with its single clip
-- visible; source monitor empty.
-- ---------------------------------------------------------------------
local function reset_to_rec_displayed()
    source_mon.sequence_id = nil
    timeline_state.reset()
    timeline_state.init("rec", "proj")
    command_manager.init("rec", "proj")
    assert(timeline_state.get_displayed_tab_id() == "rec",
        "fixture: rec must be displayed before invoking command")
    local real = 0
    for _, c in ipairs(timeline_state.get_clips()) do
        if not c.is_gap then real = real + 1 end
    end
    assert(real == 1, string.format(
        "fixture: rec must show 1 real clip pre-command, got %d", real))
end

local function assert_blank_after(label)
    -- Auto-seed regression: source monitor must still be empty.
    assert(source_mon.sequence_id == nil, string.format(
        "%s: must NOT auto-seed a random master into source_monitor; "
        .. "got sequence_id=%s", label, tostring(source_mon.sequence_id)))
    -- Timeline body blanked (same state as close-last-tab).
    local clips = timeline_state.get_clips()
    assert(#clips == 0, string.format(
        "%s: timeline must be blank after empty-source command; got %d clips",
        label, #clips))
    assert(timeline_state.get_displayed_tab_id() == nil, string.format(
        "%s: displayed_tab_id must be nil; got %s",
        label, tostring(timeline_state.get_displayed_tab_id())))
end

-- ── ShowSourceTab with empty source ────────────────────────────────────
print("-- ShowSourceTab with empty source --")
reset_to_rec_displayed()
local r1 = command_manager.execute("ShowSourceTab", {})
assert(r1 and r1.success,
    "ShowSourceTab should succeed: " .. tostring(r1 and r1.error_message))
assert_blank_after("ShowSourceTab")
print("  PASS body blanked, no random master seeded")

-- ── ToggleSourceRecordTab with empty source ────────────────────────────
print("-- ToggleSourceRecordTab with empty source --")
reset_to_rec_displayed()
local r2 = command_manager.execute("ToggleSourceRecordTab", {})
assert(r2 and r2.success,
    "ToggleSourceRecordTab should succeed: " .. tostring(r2 and r2.error_message))
assert_blank_after("ToggleSourceRecordTab")
print("  PASS body blanked, consistent with ShowSourceTab")

print("\nPASS test_show_source_tab_empty_blanks_body.lua")
