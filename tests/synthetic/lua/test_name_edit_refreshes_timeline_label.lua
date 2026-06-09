#!/usr/bin/env luajit
-- Regression: editing clip.name via SetClipProperty must refresh the
-- label the timeline renderer uses.
--
-- TSO 2026-04-21 15:44:53 showed SetClipProperty(name='asd') executing
-- cleanly — DB updated, __timeline_mutations fired, clip_state patched
-- clip.name — but the timeline label on the clip didn't change.
--
-- Root cause: clip.label is a pre-computed derived-state cache set at
-- DB-load time in database.lua:384-391 (clip.name → media_name →
-- filename). The renderer at timeline_view_renderer.lua:805 reads
-- `clip.label or clip.name or clip.id` — clip.label takes precedence.
-- When clip.name mutates, clip.label stays stale → old label renders.
--
-- Domain behavior (not implementation):
--   After SetClipProperty(name=X), the display label the renderer
--   would produce for that clip is X, not the pre-edit value.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

print("=== Name edit must refresh the timeline's display label ===")

local db_path = "/tmp/jve/test_name_edit_refreshes_timeline_label.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

db:exec(require('import_schema'))
db:exec([[
    CREATE TABLE IF NOT EXISTS properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT,
        default_value TEXT
    );
]])

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p1', 'Label Refresh', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'p1', 'Seq1', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- V13 placeholder master sequence + media_ref + media for clips below.
db:exec([[
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'p1', 'placeholder', '_placeholder', 1000, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'p1', 'placeholder_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'p1', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, 0, 0);
]])

do
    local stmt = db:prepare([[
INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    (?, 'p1', 'seq1', 't1', '_v13_placeholder_master', ?, 0, 120, 0, 120, 1, ?, ?, NULL, NULL, 'resample', 1.0, 0);
    ]])
    stmt:bind_value(1, "c1")
    stmt:bind_value(2, "Original")
    stmt:bind_value(3, now)
    stmt:bind_value(4, now)
    assert(stmt:exec(), "clip insert failed: " .. tostring(db:last_error()))
    stmt:finalize()
end

timeline_state.init("seq1", "p1")
command_manager.init("seq1", "p1")

-- The timeline renderer picks the displayable label via this exact
-- precedence rule (timeline_view_renderer.lua:805). Reproducing it
-- as a pure function so this test doesn't need Qt.
local function render_label(clip)
    return clip.label or clip.name or clip.id or ""
end

local function get_cached_clip()
    for _, c in ipairs(timeline_state.get_tab_strip():displayed_clips()) do
        if c.id == "c1" then return c end
    end
    return nil
end

-- Baseline: with clip.name = "Original", the rendered label is
-- "Original" (label is pre-computed from name at load time).
local clip = get_cached_clip()
assert(clip, "setup: c1 missing from cache")
assert(render_label(clip) == "Original", string.format(
    "baseline: expected render label 'Original', got %q",
    tostring(render_label(clip))))

-- Edit the name.
local cmd = Command.create("SetClipProperty", "p1")
cmd:set_parameter("clip_id", "c1")
cmd:set_parameter("sequence_id", "seq1")
cmd:set_parameter("property_name", "name")
cmd:set_parameter("value", "xxx")
cmd:set_parameter("property_type", "STRING")
assert(command_manager.execute(cmd).success, "SetClipProperty execute failed")

-- ----------------------------------------------------------------------
-- The test: what the renderer would draw now must be the NEW name.
-- Before the fix: clip.label stayed "Original", so render_label =
-- "Original" even though clip.name = "xxx".
-- ----------------------------------------------------------------------
clip = get_cached_clip()
assert(clip.name == "xxx", string.format(
    "sanity: clip.name should be 'xxx' after mutation, got %q",
    tostring(clip.name)))
assert(render_label(clip) == "xxx", string.format(
    "rendered label stale: got %q, expected 'xxx'. clip.label is a " ..
    "derived cache — mutations to clip.name must invalidate or " ..
    "update clip.label so the renderer's `clip.label or clip.name` " ..
    "precedence yields the new value.",
    tostring(render_label(clip))))

-- Undo round-trip: renderer must revert to the original label too.
assert(command_manager.undo().success, "undo failed")
clip = get_cached_clip()
assert(render_label(clip) == "Original", string.format(
    "after undo: expected 'Original', got %q",
    tostring(render_label(clip))))

print("✅ test_name_edit_refreshes_timeline_label.lua passed")
