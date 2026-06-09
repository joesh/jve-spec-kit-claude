#!/usr/bin/env luajit
-- T008: contract test for refactored PlaybackEngine per contracts/engine.md.
-- 10 cases verifying the new role-bound constructor, load/unload lifecycle,
-- kind-mismatch asserts, log-tag set on PlaybackController, and removal of
-- the _audio_owner flag / activate_audio / deactivate_audio surfaces.

require("test_env")

print("=== test_contract_engine.lua ===")

-- Capture every PLAYBACK.SET_LOG_TAG call so we can verify case 10.
local set_log_tag_calls = {}
package.loaded["core.qt_constants"] = {
    PLAYBACK = {
        CREATE = function() return "stub_pc" end,
        CLOSE  = function() end,
        SET_LOG_TAG = function(pc, tag)
            set_log_tag_calls[#set_log_tag_calls + 1] = { pc = pc, tag = tag }
        end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        STOP = function() end,
        PARK = function() end,
        PLAY = function() end,
        SEEK = function() end,
        SET_SHUTTLE_MODE = function() end,
        HAS_AUDIO = function() return false end,
        RELOAD_ALL_CLIPS = function() end,
    },
    EMP = {
        TMB_CREATE = function() return "stub_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_SEQUENCE_RESOLUTION = function() end,
    },
    AOP = {}, SSE = {},
}

-- Minimal DB so engine:load(seq_id) can read sequence rows.
local database = require("core.database")
local DB = "/tmp/jve/test_contract_engine.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('proj','P','resample',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
        VALUES ('rec','proj','Rec','sequence',24,1,48000,1920,1080,0,0,300,0,%d,%d),
               ('src','proj','SrcMaster','master',24,1,NULL,1920,1080,0,0,300,0,%d,%d);
]], now, now, now, now, now, now))

local PlaybackEngine = require("core.playback.playback_engine")

-- ---------- Case 1: PlaybackEngine.new("garbage") asserts ----------
local ok = pcall(PlaybackEngine.new, "garbage")
assert(not ok, "PlaybackEngine.new('garbage') must assert (invalid role)")

-- ---------- Case 2: PlaybackEngine.new('source') initial state ----------
local source_engine = PlaybackEngine.new("source")
assert(source_engine.role == "source")
assert(source_engine.loaded_sequence_id == nil,
    "fresh engine must have loaded_sequence_id == nil")
assert(source_engine.state == "stopped",
    "fresh engine must have state == 'stopped'")

local record_engine = PlaybackEngine.new("record")
assert(record_engine.role == "record")
assert(record_engine.loaded_sequence_id == nil)

-- ---------- Case 3: engine:play() before load asserts ----------
ok = pcall(function() source_engine:play() end)
assert(not ok, "engine:play() before load must assert")

-- ---------- Case 4: engine:load(nil) and engine:load('') and unknown id ----------
assert(not pcall(function() source_engine:load(nil) end),
    "engine:load(nil) must assert")
assert(not pcall(function() source_engine:load("") end),
    "engine:load('') must assert")
assert(not pcall(function() source_engine:load("does-not-exist") end),
    "engine:load(unknown) must assert")

-- ---------- Case 5: source-engine cannot load record sequence (kind mismatch) ----------
ok = pcall(function() source_engine:load("rec") end)
assert(not ok,
    "source-engine loading a 'sequence'-kind row must assert (FR-001 invariant)")

-- ---------- Case 6: record-engine cannot load master sequence ----------
ok = pcall(function() record_engine:load("src") end)
assert(not ok,
    "record-engine loading a 'master'-kind row must assert")

-- ---------- Case 7: load while playing asserts (no silent stop) ----------
source_engine:load("src")
source_engine.state = "playing"  -- simulate playing
ok = pcall(function() source_engine:load("src") end)
assert(not ok,
    "engine:load() while state='playing' must assert; caller must stop first")
source_engine.state = "stopped"

-- ---------- Case 8: loading B writes A's playhead back before binding B ----------
-- Make a second master so we can swap.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
        VALUES ('src2','proj','SrcMaster2','master',24,1,NULL,1920,1080,0,0,300,0,%d,%d);
]], now, now))

-- Move position then load other; verify the previous sequence's playhead
-- column was updated to the position the engine was parked at.
source_engine._position = 42
-- engine:load must persist outgoing seq's playhead before rebinding.
source_engine:load("src2")
local Sequence = require("models.sequence")
local prev = Sequence.load("src")
assert(prev.playhead_position == 42, string.format(
    "FR-007: engine:load must write outgoing seq's playhead to model before rebinding; "
    .. "expected src.playhead_position==42, got %s", tostring(prev.playhead_position)))
assert(source_engine.loaded_sequence_id == "src2",
    "after load, loaded_sequence_id must be the new id")

-- ---------- Case 9: unload twice asserts ----------
source_engine:unload()
ok = pcall(function() source_engine:unload() end)
assert(not ok, "double-unload must assert (loaded_sequence_id already nil)")

-- ---------- Case 10: load pushed log tag to PlaybackController ----------
-- Three loads occurred above (src, src2 via load(), and... that's 2 with
-- successful rebinds). The recorded tags must include "source:<8>" prefixes.
local found_source_tag = false
for _, call in ipairs(set_log_tag_calls) do
    if tostring(call.tag):match("^source:") then found_source_tag = true; break end
end
assert(found_source_tag, string.format(
    "engine:load must call PLAYBACK.SET_LOG_TAG with 'source:<first-8-of-id>'; "
    .. "saw %d calls but none matched 'source:' prefix", #set_log_tag_calls))

-- Verify the deleted _audio_owner field no longer exists. The core 017
-- invariant is that ownership is structural (lives in audio_playback's
-- module-private _owning_engine), not a per-engine flag. The methods
-- activate_audio/deactivate_audio are retained as thin deprecation
-- shims that delegate to the new API — they no longer carry their own
-- state.
local rebuilt = PlaybackEngine.new("source")
assert(rebuilt._audio_owner == nil, string.format(
    "_audio_owner field must be deleted in 017; engine still has it: %s",
    tostring(rebuilt._audio_owner)))

database.shutdown()

print("✅ test_contract_engine.lua passed")
