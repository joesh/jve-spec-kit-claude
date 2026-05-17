#!/usr/bin/env luajit
--- Closing the source tab when no record tab is open must blank the
--- timeline body — strip is empty, model must follow.
---
--- Live symptom (TSO 2026-05-17): user had only the source tab open
--- (no record tab) showing a master. Clicked × on the source tab. The
--- strip went empty but the body kept rendering the master's V1/A1/A2
--- clips — view diverged from model under an empty strip.
---
--- The close path's "new_displayed is nil" branch was a comment that
--- deferred to the caller (panel layer), but the panel's own
--- "active-closing" gate doesn't fire here (the source tab is never
--- the active sequence per FR-005). So nothing cleared the model —
--- data.state.clips still held the master's virtual clips.
---
--- This test covers the source-only configuration directly via the
--- state-layer close API. No record tab is ever opened.

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_close_source_with_no_rec_blanks_body.lua ===")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local TEST_DB = "/tmp/jve/test_close_source_with_no_rec_blanks_body.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
        width, height, metadata, created_at, modified_at)
    VALUES ('m_master', 'proj', 'A039.mov', '/tmp/A039.mov', 1000, 25, 1,
            48000, 0, 1920, 1080,
            '{"start_tc_value":0,"start_tc_rate":25}', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('master_a039', 'proj', 'A039', 'master', 25, 1, 48000, 1920, 1080,
            0, 0, 0, 1000, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('master_v1', 'master_a039', 'V1', 'VIDEO', 1, 1);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        timeline_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr_master_v', 'proj', 'master_a039', 'master_v1', 'm_master',
            0, 1000, 0, 1000, 1, 1.0, 0, %d, %d);
]], now, now, now, now, now, now, now, now))

-- Source-only configuration: no rec tab. Activate displayed directly
-- onto the master without ever calling timeline_state.init for a record.
local tab_strip = timeline_state.get_tab_strip()
tab_strip:open_source_tab("master_a039")
tab_strip:switch_displayed(tab_strip:get_source_tab())

-- Load the body for the source tab. (init() requires a record seq, so
-- we drive the body load through activate_displayed directly — same as
-- the production path when the user opens a master from the browser.)
local core_state = require("ui.timeline.state.timeline_core_state")
core_state.activate_displayed("master_a039", nil)

assert(timeline_state.get_displayed_tab_id() == "master_a039",
    "fixture: source tab must be the displayed tab")
do
    local clips = timeline_state.get_clips()
    local virtual = 0
    for _, c in ipairs(clips) do
        if c.is_master_virtual then virtual = virtual + 1 end
    end
    assert(virtual == 1, string.format(
        "fixture: body must hold 1 master virtual clip pre-close, got %d",
        virtual))
end
print("  ✓ fixture: source-only tab strip showing master virtual clip")

-- Close the source tab. With NO rec tab to fall back to the strip ends
-- up empty. The body MUST blank — under an empty strip we should NOT
-- still be rendering the closed master's clips.
timeline_state.close_displayed_tab("master_a039")

assert(timeline_state.get_displayed_tab_id() == nil, string.format(
    "after close: displayed must be nil (strip is empty), got %s",
    tostring(timeline_state.get_displayed_tab_id())))

do
    local clips = timeline_state.get_clips()
    assert(#clips == 0, string.format(
        "after close: body must be empty (no displayed sequence), got %d "
        .. "clips. Strip is empty but data.state.clips still holds the "
        .. "closed master's virtual clips — view diverged from model "
        .. "(TSO 2026-05-17).", #clips))
end
print("  ✓ source tab closed with no rec: body blanked")

print("\n✅ test_close_source_with_no_rec_blanks_body.lua passed")
