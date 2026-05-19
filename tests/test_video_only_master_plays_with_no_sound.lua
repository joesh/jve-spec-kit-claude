#!/usr/bin/env luajit
-- T025 / FR-013a: video-only master (audio_sample_rate=NULL) plays
-- silently — the handover protocol still runs (audio device acquired
-- in silent-output mode), but no audio samples are produced.

require("test_env")
print("=== test_video_only_master_plays_with_no_sound.lua ===")

local setup = require("helpers.test_017_setup")
setup.install_qt_stub()
local h = setup.fresh_project_db("test_017_t025.db")
-- Add a video-only master (NULL audio_sample_rate).
local now = os.time()
h.database.get_connection():exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
        VALUES ('vo','p','VideoOnly','master',24,1,NULL,1920,1080,0,0,300,0,%d,%d);
]], now, now))

local transport = require("core.playback.transport")
transport.init("p")
local src = transport.engine_for_role("source")

-- Load video-only master — must NOT assert.
local ok, err = pcall(function() src:load("vo") end)
assert(ok, "FR-013a: loading a video-only master must succeed; err=" .. tostring(err))

-- Play — handover still runs, just configures silent output.
ok, err = pcall(function() src:play() end)
assert(ok, "FR-013a: playing a video-only master must succeed; err=" .. tostring(err))

local audio_playback = require("core.media.audio_playback")
assert(audio_playback.is_owner(src),
    "FR-013a: video-only master engine must still take audio ownership (silent path)")

print("✅ test_video_only_master_plays_with_no_sound.lua passed")
