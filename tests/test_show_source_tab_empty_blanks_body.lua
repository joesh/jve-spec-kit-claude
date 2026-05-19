#!/usr/bin/env luajit
--- ShowSourceTab + ToggleSourceRecordTab with an empty source viewer
--- must blank the timeline body — not seed a random project master.
---
--- Domain contract: when the source monitor has no master loaded, the
--- user has chosen nothing. Picking masters[1] from the DB is fabrication
--- ("random clip" per the live report). The visible result must be an
--- empty timeline, same blank state the user gets after closing the
--- last tab.
---
--- Live symptom (TSO 2026-05-17, image 16): launched app with no source
--- loaded. Window → Source Tab opened the tab with "1080p25 Tail.mov"
--- (the first master in the DB). Toggle Source/Record Tab was a silent
--- no-op. Both should produce the empty-timeline state instead.

require("test_env")

_G.qt_create_single_shot_timer = function() end

-- Stub panel_manager.get_sequence_monitor so ShowSourceTab's resolver
-- works without Qt. The fake source_monitor reports no loaded master.
local fake_source_monitor = {
    get_loaded_master_seq_id = function() return nil end,
}
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
    get_sequence_monitor = function(name)
        if name == "source_monitor" then return fake_source_monitor end
        return nil
    end,
}

-- Stub source_viewer.load_master_clip so the (to-be-removed) auto-seed
-- path can be detected as a test failure if it's still being taken.
local seed_called_with = nil
package.loaded["ui.source_viewer"] = {
    load_master_clip = function(clip_id)
        seed_called_with = clip_id
    end,
}

-- Stub transport.engine_for_role for the toggle command's source-engine
-- lookup (also reports nothing loaded).
package.loaded["core.playback.transport"] = {
    _project_id = "proj",
    is_bootstrapped = function() return true end,
    bound_project_id = function() return "proj" end,
    engine_for_role = function(role)
        if role == "source" then
            return { loaded_sequence_id = nil }
        end
        return { loaded_sequence_id = nil }
    end,
}

print("=== test_show_source_tab_empty_blanks_body.lua ===")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")

local TEST_DB = "/tmp/jve/test_show_source_tab_empty_blanks_body.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);

    -- A record sequence with one clip (so we can verify the body
    -- transitions from "showing rec content" to "blank" after the command).
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec', 'proj', 'Rec', 'sequence', 25, 1, 48000, 1920, 1080,
            0, 0, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('rec_v1', 'rec', 'V1', 'VIDEO', 1, 1);

    -- A project master in the DB. This is the "random clip" the buggy
    -- auto-seed would pick. The presence of this row is the test's
    -- bait: a passing test must NOT consume it.
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

    -- A real clip on rec to show the "before" state.
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
        sequence_id, name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        master_layer_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('rec_clip1', 'proj', 'rec', 'rec_v1', 'master_random', 'RecClip',
            10, 30, 0, 30, NULL, 'passthrough', 1, 1.0, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now))

-- Test setup helper: rec is active+displayed, source monitor empty.
local function reset_to_rec_displayed()
    seed_called_with = nil
    timeline_state.reset()
    timeline_state.init("rec", "proj")
    command_manager.init("rec", "proj")
    assert(timeline_state.get_displayed_tab_id() == "rec",
        "fixture: rec must be displayed before invoking command")
    local before = timeline_state.get_clips()
    local real = 0
    for _, c in ipairs(before) do
        if not c.is_gap then real = real + 1 end
    end
    assert(real == 1, string.format(
        "fixture: rec must show 1 real clip pre-command, got %d", real))
end

local function assert_blank_after(label)
    assert(seed_called_with == nil, string.format(
        "%s: must NOT auto-seed a random master; got load_master_clip(%s)",
        label, tostring(seed_called_with)))
    local clips = timeline_state.get_clips()
    assert(#clips == 0, string.format(
        "%s: body must be blank after command (empty source → empty timeline, "
        .. "same as close-last-tab); got %d clips",
        label, #clips))
    assert(timeline_state.get_displayed_tab_id() == nil, string.format(
        "%s: displayed tab pointer must be nil (no displayed sequence); got %s",
        label, tostring(timeline_state.get_displayed_tab_id())))
end

-- ── Test 1: ShowSourceTab with empty source ──
print("\n-- ShowSourceTab with empty source viewer --")
reset_to_rec_displayed()
local r1 = command_manager.execute("ShowSourceTab", {})
assert(r1 and r1.success,
    "ShowSourceTab should succeed: " .. tostring(r1 and r1.error_message))
assert_blank_after("ShowSourceTab")
print("  ✓ body blanked; no random master seeded")

-- ── Test 2: ToggleSourceRecordTab with empty source ──
print("\n-- ToggleSourceRecordTab with empty source viewer --")
reset_to_rec_displayed()
local r2 = command_manager.execute("ToggleSourceRecordTab", {})
assert(r2 and r2.success, "ToggleSourceRecordTab should succeed: "
    .. tostring(r2 and r2.error_message))
assert_blank_after("ToggleSourceRecordTab")
print("  ✓ body blanked; consistent with ShowSourceTab")

print("\n✅ test_show_source_tab_empty_blanks_body.lua passed")
