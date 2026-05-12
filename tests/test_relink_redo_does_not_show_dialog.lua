#!/usr/bin/env luajit
--- TDD: redo of a relink must replay the relink itself, not the dialog.
--
-- Repro: ShowRelinkDialog (undoable=false) opens the modal, user picks
-- files, dispatches RelinkClips (undoable). On undo+redo, the redo target
-- must be RelinkClips. Re-invoking the dialog on redo would force the
-- user back through the modal flow for an already-decided action.
require("test_env")

_G.qt_create_single_shot_timer = function() end
_G.qt_monotonic_s = _G.qt_monotonic_s or function() return os.clock() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.ui_state"] = {
    get_main_window = function() return nil end,
}

print("=== test_relink_redo_does_not_show_dialog.lua ===")

local database = require("core.database")
local command_manager = require("core.command_manager")
local uuid = require("uuid")

local TEST_DB = "/tmp/jve/test_relink_redo_does_not_show_dialog.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-redo-dialog"
local seq_id = uuid.generate()
local track_id = uuid.generate()
local media_id = "media-orig"
local clip_id_1 = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'Redo Dialog Project', 'resample', %d, %d, '{}');

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('%s', '%s', 'Seq', 'sequence', 25, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('%s', '%s', 'A026.mov', '/offline/A026.mov', 1000, 25, 1,
        1920, 1080, 0, 'prores', %d, %d, '{"start_tc_value":0,"start_tc_rate":25}');
]], project_id, now, now,
    seq_id, project_id, now, now,
    track_id, seq_id,
    media_id, project_id, now, now))

local _Sequence = require("models.sequence")
local master_seq_id = _Sequence.ensure_master(media_id, project_id)

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, playhead_frame, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume)
    VALUES ('%s', '%s', 'Clip1', '%s', '%s', '%s', 0, 100, 100, 200, 1, 0, %d, %d, NULL, NULL, 'resample', 1.0);
]], clip_id_1, project_id, track_id, master_seq_id, seq_id, now, now))

command_manager.init(seq_id, project_id)

-- Pretend a sequence is currently selected so timeline_state has a project.
local timeline_state = require("ui.timeline.timeline_state")
timeline_state.init(seq_id, project_id)

-- Mock the dialog module so show() returns a synthesized successful relink
-- result without opening any Qt window. Counts invocations so we can assert
-- the dialog is shown exactly once across execute + undo + redo.
local dialog_show_count = 0
package.loaded["ui.media_relink_dialog"] = {
    show = function(media_list, _parent, opts)
        dialog_show_count = dialog_show_count + 1
        assert(#media_list >= 1, "mock dialog: media_list must be non-empty")
        local relinked = {
            {
                media_id = media_id,
                old_path = "/offline/A026.mov",
                new_path = "/found/A026.mov",
                kind = "exact",
            },
        }
        opts.on_apply({
            relink = { relinked = relinked, failed = {} },
            folder_priority = { "/found" },
        })
        return {
            relink = { relinked = relinked, failed = {} },
            folder_priority = { "/found" },
        }
    end,
}

-- Stub out planner so we don't depend on probe-cache state etc.
package.loaded["core.relink_planner"] = {
    build_plan = function(_db, _relinked, _failed, _folder_priority, _project_id)
        return {
            clip_relink_map = {
                [clip_id_1] = { new_source_in = 75, new_source_out = 175 },
            },
            media_path_changes = { [media_id] = "/found/A026.mov" },
            media_tc_updates = {},
            new_media_records = {},
            media_offline_notes = {},
            salvaged_count = 0,
        }
    end,
}

local Clip = require("models.clip")

print("\n--- Step 1: Execute ShowRelinkDialog (dialog opens, applies) ---")
local exec_result = command_manager.execute("ShowRelinkDialog", { project_id = project_id })
assert(exec_result.success, "ShowRelinkDialog failed: " .. tostring(exec_result.error_message))
assert(dialog_show_count == 1, string.format("expected 1 dialog show on execute, got %d", dialog_show_count))
do
    local c = Clip.load(clip_id_1)
    assert(c.source_in == 75 and c.source_out == 175,
        string.format("execute should have applied relink, got source_in=%d source_out=%d", c.source_in, c.source_out))
end
print("  ✓ relink applied; dialog shown 1×")

print("\n--- Step 2: Undo ---")
local undo_result = command_manager.undo()
assert(undo_result.success, "undo failed: " .. tostring(undo_result.error_message))
do
    local c = Clip.load(clip_id_1)
    assert(c.source_in == 100 and c.source_out == 200,
        string.format("undo should restore source range, got source_in=%d source_out=%d", c.source_in, c.source_out))
end
assert(dialog_show_count == 1, string.format("undo must not show dialog, count=%d", dialog_show_count))
print("  ✓ undo restored; dialog still 1×")

print("\n--- Step 3: Redo (must NOT reopen the dialog) ---")
local redo_result = command_manager.redo()
assert(redo_result.success, "redo failed: " .. tostring(redo_result.error_message))
assert(dialog_show_count == 1,
    string.format("BUG: redo reopened the dialog (dialog_show_count=%d, expected 1)", dialog_show_count))
do
    local c = Clip.load(clip_id_1)
    assert(c.source_in == 75 and c.source_out == 175,
        string.format("redo should reapply relink, got source_in=%d source_out=%d", c.source_in, c.source_out))
end
print("  ✓ redo replayed RelinkClips without reopening dialog")

print("\n✅ test_relink_redo_does_not_show_dialog.lua passed")
