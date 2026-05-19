-- 018 NSF: until Phase 3.6 makes owner_delta_to_source return (frame,subframe),
-- SplitClip cannot split through a sub-sample boundary. A clip with non-zero
-- source_in_subframe or source_out_subframe MUST refuse to split — silently
-- pass-through inheritance would corrupt audio at the cut point.
--
-- Currently expected to FAIL until split_clip.lua asserts subframe==0.

require("test_env")
local database = require("core.database")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")

local DB = "/tmp/jve/test_018_split_refuses_nonzero_subframe.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'passthrough',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES ('m', 'p', 'master', 'master', 24, 1, NULL, 1920, 1080, %d, %d),
           ('e', 'p', 'edit',   'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
           ('e-a1', 'e', 'A1', 'AUDIO', 1);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
    VALUES ('med', 'p', 'a.wav', '/tmp/a.wav', 96000, 48000, 1, 1, %d, %d);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr', 'p', 'm', 'm-a1', 'med', 0, 96000, 0, 96000, 48000,
            1, 1.0, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)))

-- Audio clip on edit.A1, 100 frames at 24/1, with NON-ZERO subframes
-- (a real sample-precise edit would land here). Source frames are master.fps;
-- subframe is in canonical ticks (master_clock_hz * fps_den / fps_num = 8000
-- ticks/frame). source_in_subframe=2000 (= 12 samples at 48k inside the frame).
assert(db:exec(string.format([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
        name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('c', 'p', 'e', 'e-a1', 'm', 'audio',
            0, 100, 0, 100, 2000, 4000,
            NULL, NULL, 'passthrough',
            1, 1.0, 0, %d, %d);
]], now, now)))

command_manager.init('e', 'p')

-- Sanity: clip exists with subframes.
local c = Clip.load("c")
assert(c.source_in == 0 and c.source_out == 100, "test setup: source range")

-- Attempt to split at frame 50. command_manager catches executor asserts
-- and returns success=false with error_message — both shapes are acceptable
-- refusals as long as the message names subframe / Phase 3.6 and the clip
-- is not actually split.
local result_or_err
local ok = pcall(function()
    result_or_err = command_manager.execute("SplitClip", {
        project_id  = "p",
        sequence_id = "e",
        clip_id     = "c",
        split_frame = 50,
    })
end)

local refused, msg
if not ok then
    refused, msg = true, tostring(result_or_err)
elseif type(result_or_err) == "table" and result_or_err.success == false then
    refused, msg = true, tostring(result_or_err.error_message or "")
else
    refused, msg = false, "command returned success=true"
end

assert(refused, "SplitClip must REFUSE non-zero-subframe input until Phase 3.6")
assert(msg:find("subframe") or msg:find("Phase 3.6"),
    "refusal message must mention subframe / Phase 3.6; got: " .. msg)

-- And invariant: the clip is unchanged (still single clip [0, 100)).
local after = Clip.load("c")
assert(after.duration == 100 and after.source_in == 0 and after.source_out == 100,
    "refused SplitClip must leave the clip untouched")
local s = db:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = 'e'")
assert(s:exec() and s:next())
local n = s:value(0); s:finalize()
assert(n == 1, "no new clip rows must appear after refused SplitClip; got " .. tostring(n))

print("✅ test_018_split_refuses_nonzero_subframe.lua passed")
