#!/usr/bin/env luajit
-- Regression Test: Overwrite Command Rational Crash
-- Reproduces "compare number with table" in clip_mutator during Overwrite

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Testing Overwrite Rational Crash ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_overwrite_crash.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Insert Project/Sequence
local now = os.time()
db:exec(string.format([[ 
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('project', 'Test', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[ 
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[ 
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Register Overwrite Command
require('core.command_registry') -- luacheck: ignore 411
local overwrite_cmd = require('core.commands.overwrite')
-- Pass dummy tables, then register with manager
local ret = overwrite_cmd.register({}, {}, db, command_manager.set_last_error)
command_manager.register_executor("Overwrite", ret.executor, ret.undoer)
command_manager.register_executor("UndoOverwrite", ret.executor, ret.undoer) -- UndoOverwrite usually maps to same logic if handled internally or separate?
-- Overwrite.lua defines command_executors["UndoOverwrite"] = command_undoers["Overwrite"]
-- So ret.undoer is the undo function.
-- But command_manager.execute_undo calls the UNDOER associated with the command type "Overwrite".
-- So register_executor("Overwrite", exec, undo) is enough.
-- BUT if explicit "UndoOverwrite" command is used...
-- The command_manager uses: `undoer = registry.get_undoer(cmd.type)`.
-- So valid.


-- Create Media
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/media_1.mov",
    name = "Media 1",
    duration_frames = 240, -- 10s @ 24fps
    fps_numerator = 24,
    fps_denominator = 1
})
media:save(db)
-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_1")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media_1", "project")

-- Create masterclip sequence for this media (required for Overwrite)
local source_sequence_id = test_env.create_test_masterclip_sequence(
    "project", "Media 1 Master", 24, 1, 240, "media_1")

-- Create Existing Clip (0-100 frames)
local clip_existing = Clip.create({
        name = "Existing",
        project_id = "project",
        track_id = "track_v1",
        owner_sequence_id = "sequence",
        sequence_id = MC_TEST,
        sequence_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
assert(clip_existing ~= nil, "Failed to create clip_existing")
print("Created existing clip at 0-100 frames")

-- Execute Overwrite (Overlap 50-150)
-- This triggers clip_mutator to resolve occlusion (trim existing clip)
local cmd = Command.create("Overwrite", "project")
cmd:set_parameter("source_sequence_id", source_sequence_id)
cmd:set_parameter("target_video_track_id", "track_v1")
cmd:set_parameter("sequence_id", "sequence")
-- Rationals
cmd:set_parameter("sequence_start_frame", 50)

print("Executing Overwrite...")
local result = command_manager.execute(cmd)

if result.success then
    print("✅ Overwrite succeeded")
else
    print("❌ Overwrite failed: " .. tostring(result.error_message))
    os.exit(1) -- Fail
end

print("Test Passed")
os.exit(0)
