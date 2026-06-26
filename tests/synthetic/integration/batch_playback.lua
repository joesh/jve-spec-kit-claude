--- Batch: TMB/playback integration tests (single JVEEditor process).
local runner = require("synthetic.integration.batch_runner")
local dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")

local _, failed = runner.run("playback", runner.resolve_paths(dir, {
    "test_tmb_pending_frame.lua",
    "test_tmb_audio_source_offset.lua",
    "test_tmb_same_file_two_tracks.lua",
    "test_tmb_effective_tracks_eligibility.lua",
    "test_playback_seek_delivers_frame.lua",
    "test_seek_gap_clears_frame.lua",
    "test_playback_av_sync.lua",
    -- test_playback_av_sync_offset has FFI cdefs that conflict in batch mode

    "test_playback_controller_nsf_bounds.lua",
    "test_playback_controller_preconditions.lua",
    "test_playback_controller_vsync.lua",
    "test_playback_gap_clears_and_recovers.lua",
    "test_playback_real_timeline_gap.lua",
    "test_tmb_real_timeline.lua",
}))

assert(failed == 0, string.format("batch_playback: %d test(s) failed", failed))
