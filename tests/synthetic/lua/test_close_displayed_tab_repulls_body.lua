#!/usr/bin/env luajit
--- Closing the displayed source tab must re-pull body content for the
--- new displayed sequence — the strip's displayed pointer falls back
--- to the active record tab, and the body must follow.
---
--- Live symptom (TSO 2026-05-16): clicked × on the source tab. Strip
--- showed only the record tab afterward, but the timeline body kept
--- rendering the master's V1 clip (the closed source's content). The
--- close path mutated the strip but never reloaded data.state.clips
--- for the new displayed sequence — view + model fell out of sync.
---
--- This test drives the state-layer close API end-to-end and asserts
--- data.state.clips reflects the record's content after the source tab
--- is closed.

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_close_displayed_tab_repulls_body.lua ===")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local TEST_DB = "/tmp/jve/test_close_displayed_tab_repulls_body.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);

    -- Record sequence with one real clip.
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec', 'proj', 'Rec', 'sequence', 25, 1, 48000, 1920, 1080,
            0, 0, 0, 300, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('rec_v1', 'rec', 'V1', 'VIDEO', 1, 1);

    -- Media + master sequence with V media_ref (synthesized as virtual clip).
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        width, height, metadata, created_at, modified_at)
    VALUES ('m_master', 'proj', 'A038.mov', '/tmp/A038.mov', 1000, 25, 1,
            48000, 0, 1920, 1080,
            '{"start_tc_value":0,"start_tc_rate":25}',
            %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('master_a038', 'proj', 'A038', 'master', 25, 1, NULL, 1920, 1080,
            0, 0, 0, 1000, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('master_v1', 'master_a038', 'V1', 'VIDEO', 1, 1);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr_master_v', 'proj', 'master_a038', 'master_v1', 'm_master',
            0, 1000, 0, 1000, 1, 1.0, 0, %d, %d);

    -- A real clip on the record timeline — distinct content from the
    -- master's virtual clip so we can tell them apart.
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
        sequence_id, name,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        master_layer_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('rec_clip1', 'proj', 'rec', 'rec_v1', 'master_a038', 'RecClip',
            100, 50, 0, 50, NULL, 'passthrough', 1, 1.0, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now))

-- Initial state: rec is active + displayed.
timeline_state.init("rec", "proj")
assert(timeline_state.get_displayed_tab_id() == "rec",
    "initial: displayed must be rec")

-- Verify rec's body content: 1 real clip.
do
    local clips = timeline_state.get_tab_strip():displayed_clips()
    local real = 0
    for _, c in ipairs(clips) do
        if not c.is_gap then real = real + 1 end
    end
    assert(real == 1, string.format(
        "initial: rec should have 1 real clip, got %d", real))
end
print("  ✓ initial: rec displayed with 1 real clip")

-- Activate source tab (master). Body now holds master's virtual clip.
timeline_state.activate_displayed("master_a038")
assert(timeline_state.get_displayed_tab_id() == "master_a038",
    "after activate: displayed must be master_a038")
do
    local clips = timeline_state.get_tab_strip():displayed_clips()
    local virtual = 0
    for _, c in ipairs(clips) do
        if c.is_master_virtual then virtual = virtual + 1 end
    end
    assert(virtual == 1, string.format(
        "source tab open: body must show 1 master virtual clip, got %d", virtual))
end
print("  ✓ source tab activated: body shows master virtual clip")

-- Close the source tab. The strip's displayed pointer falls back to the
-- active record (rec). The body MUST re-pull rec's clips — otherwise the
-- user sees stale master content under a rec-labelled tab.
timeline_state.close_displayed_tab("master_a038")

assert(timeline_state.get_displayed_tab_id() == "rec", string.format(
    "after close: displayed must fall back to rec, got %s",
    tostring(timeline_state.get_displayed_tab_id())))

do
    local clips = timeline_state.get_tab_strip():displayed_clips()
    local real, virtual = 0, 0
    for _, c in ipairs(clips) do
        if c.is_master_virtual then virtual = virtual + 1
        elseif not c.is_gap then real = real + 1 end
    end
    assert(virtual == 0, string.format(
        "after close: body must NOT show master virtual clips; got %d. "
        .. "Strip says rec but body still has master content — view "
        .. "drifted from model (TSO 2026-05-16 symptom).", virtual))
    assert(real == 1, string.format(
        "after close: body must show rec's 1 real clip, got %d", real))
end
print("  ✓ source tab closed: body re-pulled rec's content")

print("\n✅ test_close_displayed_tab_repulls_body.lua passed")
