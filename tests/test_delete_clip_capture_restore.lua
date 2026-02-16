#!/usr/bin/env luajit

-- Regression: capture_clip_state must carry owner_sequence_id/project_id so restore works and undo payloads can be built.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";../tests/?.lua"

require("test_env")

local database = require("core.database")
local command_helper = require("core.command_helper")
local Clip = require("models.clip")

local DB_PATH = "/tmp/jve/test_delete_clip_capture_restore.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
db:exec(require("import_schema"))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, created_at, modified_at)
    VALUES ('media_test', 'default_project', 'Test Media', 'synthetic://test',
        1000, 30, 1, 1920, 1080, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'default_sequence', 'default_project', 'Default Sequence', 'timeline',
        30, 1, 48000,
        1920, 1080,
        0, 300, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'mc_seq', 'default_project', 'Test Master', 'masterclip',
        30, 1, 48000,
        1920, 1080,
        0, 300, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );
    INSERT INTO tracks (
        id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan
    )
    VALUES (
        'track_v1', 'default_sequence', 'V1', 'VIDEO', 1,
        1, 0, 0, 0, 1.0, 0.0
    );
    INSERT INTO clips (
        id, project_id, clip_kind, master_clip_id, owner_sequence_id,
        track_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline,
        created_at, modified_at
    )
    VALUES (
        'clip_state_test', 'default_project', 'timeline', 'mc_seq', 'default_sequence',
        'track_v1', 'media_test', 'Test Clip',
        0, 30, 0, 30,
        30, 1, 1, 0,
        strftime('%s','now'), strftime('%s','now')
    );
]])

local clip = Clip.load_optional("clip_state_test", db)
assert(clip, "Clip should exist for capture/restore test")

local state = command_helper.capture_clip_state(clip)
assert(state.project_id == "default_project", "capture must include project_id")
assert(state.owner_sequence_id == "default_sequence", "capture must include owner_sequence_id")
assert(state.clip_kind == "timeline", "capture must include clip_kind")

-- Remove the clip to force restore path to recreate it with captured metadata
db:exec("DELETE FROM clips WHERE id = 'clip_state_test'")
local clip_after_delete = Clip.load_optional("clip_state_test", db)
assert(not clip_after_delete, "Clip should be deleted before restore")

local restored = command_helper.restore_clip_state(state)
assert(restored, "restore_clip_state should recreate missing clip with captured metadata")
assert(restored.project_id == "default_project", "restored clip must carry project_id")
assert(restored.owner_sequence_id == "default_sequence", "restored clip must carry owner_sequence_id")

-- Reload from DB to ensure persistence
local reloaded = Clip.load_optional("clip_state_test", db)
assert(reloaded, "clip should be persisted to DB during restore")
assert(reloaded.owner_sequence_id == "default_sequence", "reloaded clip must carry owner_sequence_id")

print("✅ capture_clip_state retains project/sequence metadata for restore")
