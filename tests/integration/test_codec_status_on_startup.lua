--- Integration test: persisted codec errors must show on first paint.
--
-- Regression: load_persisted ran after clips rendered, so ensure_clip_status
-- found an empty cache → stamped clips online → blue instead of red.
--
-- Run: ./build/bin/JVEEditor --test tests/integration/test_codec_status_on_startup.lua

local ui = require("integration.ui_test_env")

print("=== test_codec_status_on_startup ===")

-- Step 1: Create the test project DB (but don't launch yet)
local project_info = ui.create_test_project({
    project_name = "Codec Startup Test",
    num_sequences = 1,
    sequence_names = {"Main"},
    active_sequence = 1,
})

local database = require("core.database")

-- Step 2: Insert fake BRAW media + clips into the DB (V13 schema)
os.execute("mkdir -p /tmp/jve/codec_test_media")
local fake_paths = {}
local Media = require("models.media")
local Clip = require("models.clip")
local test_env = require("test_env")
local db = database.get_connection()
local project_id = project_info.project.id
local seq = project_info.sequences[1]
local tracks = database.load_tracks(seq.id)
assert(#tracks > 0, "Need at least one track")
local track_id = tracks[1].id

-- Clips start at frame 1000 (well past the default playhead=0). The
-- renderer only decodes clips under the playhead; anything else is not
-- touched at first paint. Keeping the clips off the playhead prevents
-- TMB's decode error (fake BRAW content → BRAW SDK FileNotFound) from
-- calling media_status.update_from_tmb and overwriting the seeded
-- cache entries before the assertions below.
for i = 1, 3 do
    local path = string.format("/tmp/jve/codec_test_media/fake_%d.braw", i)
    local f = io.open(path, "w"); f:write("not real braw"); f:close()
    fake_paths[i] = path

    local med = Media.create({
        id = string.format("media_braw_%d", i),
        project_id = project_id,
        name = string.format("fake_%d.braw", i),
        file_path = path,
        duration_frames = 100,
        frame_rate = 24,
        width = 1920,
        height = 1080,
    })
    assert(med:save(), "media save failed: " .. tostring(db:last_error()))

    local mc_seq_id = test_env.create_test_masterclip_sequence(
        project_id, string.format("braw_%d mc", i), 24, 1, 100, med.id)

    Clip.create({
        id = string.format("clip_braw_%d", i),
        name = string.format("BRAW Clip %d", i),
        project_id = project_id,
        owner_sequence_id = seq.id,
        track_id = track_id,
        sequence_id = mc_seq_id,
        timeline_start_frame = 1000 + (i - 1) * 60,
        duration_frames = 50,
        source_in_frame = 0,
        source_out_frame = 50,
        fps_mismatch_policy = "passthrough",
        enabled = true,
        volume = 1.0,
        playhead_frame = 0,
    })
end

-- Verify inserts worked on this connection
local verify_clips = database.load_clips(seq.id)
print(string.format("  verify: %d clips in seq %s after insert", #verify_clips, seq.id:sub(1,8)))

-- Step 3: Persist codec errors (simulating previous session's bg probe discovery).
-- "DecodeFailed" is a persistent codec error: media_status.load_persisted
-- strips stale "Unsupported" entries on load (codec support can change
-- between builds — see commit f245d26), so we seed with DecodeFailed to
-- keep the seed from being cleared before the first-paint check.
local error_cache = {}
for _, path in ipairs(fake_paths) do
    error_cache[path] = { offline = true, error_code = "DecodeFailed" }
end
database.set_project_setting(project_id, "media_error_cache", error_cache)
print("  setup: 3 BRAW clips + 3 persisted DecodeFailed errors in DB")

-- Flush WAL before re-opening the DB (layout.lua re-inits the DB connection)
db:exec("PRAGMA wal_checkpoint(TRUNCATE)")

-- Step 4: Launch the full UI using the EXISTING DB (not creating a new one)
-- We need to set env vars and require layout.lua manually since ui.launch
-- would call create_test_project again and overwrite our data.
local ffi = require("ffi")
ffi.cdef("int setenv(const char *name, const char *value, int overwrite);")

local saved_home = os.getenv("HOME")
package.cpath = package.cpath .. ';' .. saved_home .. '/.luarocks/lib/lua/5.1/?.so'
package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?.lua'
package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?/init.lua'

local test_home = "/tmp/jve_test_home"
os.execute("mkdir -p " .. test_home .. "/.jve")
ffi.C.setenv("HOME", test_home, 1)
ffi.C.setenv("JVE_PROJECT_PATH", project_info.db_path, 1)

local app = require("ui.layout")
assert(app and app.main_window, "layout.lua must create main_window")

-- Step 5: Check media_status cache state DIRECTLY, before any event
-- pumping. The regression this test guards: load_persisted used to run
-- in a post-startup timer, so ensure_clip_status at first paint found
-- an empty cache → stamped clips online → flashed blue before flipping
-- to red. The fix moves load_persisted into the project_changed handler,
-- which runs synchronously during `require("ui.layout")` above.
--
-- We check the cache directly instead of rendering + inspecting clip
-- objects because start_background_probe is also kicked off in
-- project_changed (on a worker thread) and can deliver partial batches
-- during any ui.pump() call, racing the test. The cache state *at this
-- point* reflects exactly what load_persisted populated — no race.
local media_status = require("core.media.media_status")
for _, path in ipairs(fake_paths) do
    local status = media_status.get(path)
    print(string.format("  cache[%s] = %s",
        path:match("([^/]+)$"), status and
        string.format("{offline=%s, error=%s}",
            tostring(status.offline), tostring(status.error_code)) or "nil"))
end

local failures = 0
for _, path in ipairs(fake_paths) do
    local status = media_status.get(path)
    if not status or not status.offline or status.error_code ~= "DecodeFailed" then
        print(string.format("  FAIL: %s cache status=%s — expected offline/DecodeFailed",
            path:match("([^/]+)$"),
            status and string.format("{offline=%s, error=%s}",
                tostring(status.offline), tostring(status.error_code)) or "nil"))
        failures = failures + 1
    else
        print(string.format("  OK: %s offline=true error_code=DecodeFailed",
            path:match("([^/]+)$")))
    end
end
assert(failures == 0,
    string.format("%d paths missing from status cache — load_persisted did not run before first paint", failures))

-- Cleanup
for _, path in ipairs(fake_paths) do os.remove(path) end

print("✅ test_codec_status_on_startup.lua passed")
