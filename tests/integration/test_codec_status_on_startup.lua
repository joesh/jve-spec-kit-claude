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

-- Step 2: Insert fake BRAW media + clips into the DB
os.execute("mkdir -p /tmp/jve/codec_test_media")
local fake_paths = {}
local now = os.time()
local db = database.get_connection()
local project_id = project_info.project.id
local seq = project_info.sequences[1]
local tracks = database.load_tracks(seq.id)
assert(#tracks > 0, "Need at least one track")
local track_id = tracks[1].id

for i = 1, 3 do
    local path = string.format("/tmp/jve/codec_test_media/fake_%d.braw", i)
    local f = io.open(path, "w"); f:write("not real braw"); f:close()
    fake_paths[i] = path

    local mid = string.format("media_braw_%d", i)
    local sql1 = string.format([[
        INSERT INTO media (id, project_id, name, file_path,
            duration_frames, fps_numerator, fps_denominator,
            created_at, modified_at)
        VALUES ('%s', '%s', 'fake_%d.braw', '%s', 100, 24, 1, %d, %d)
    ]], mid, project_id, i, path, now, now)
    assert(db:exec(sql1), "media INSERT failed: " .. tostring(db:last_error()))

    local clip_id = string.format("clip_braw_%d", i)
    local sql2 = string.format([[
        INSERT INTO clips (id, project_id, clip_kind, name, track_id,
            media_id, owner_sequence_id,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, offline,
            created_at, modified_at)
        VALUES ('%s', '%s', 'timeline', 'BRAW Clip %d', '%s',
            '%s', '%s', %d, 50, 0, 50, 24, 1, 1, 0, %d, %d)
    ]], clip_id, project_id, i, track_id, mid, seq.id, (i - 1) * 60, now, now)
    assert(db:exec(sql2), "clip INSERT failed: " .. tostring(db:last_error()))
end

-- Verify inserts worked on this connection
local verify_clips = database.load_clips(seq.id)
print(string.format("  verify: %d clips in seq %s after insert", #verify_clips, seq.id:sub(1,8)))

-- Step 3: Persist codec errors (simulating previous session's bg probe discovery)
local error_cache = {}
for _, path in ipairs(fake_paths) do
    error_cache[path] = { offline = true, error_code = "Unsupported" }
end
database.set_project_setting(project_id, "media_error_cache", error_cache)
print("  setup: 3 BRAW clips + 3 persisted Unsupported errors in DB")

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

-- Pump just enough for layout to render but NOT for the 50ms timer to fire.
-- The bug: load_persisted runs in the 50ms timer, so clips render blue first.
-- With the fix: load_persisted runs in open_and_init_project (before render).
ui.pump(10)

-- Step 5: Check clip state
local tl_state = require("ui.timeline.state.timeline_core_state")
local clip_state = require("ui.timeline.state.clip_state")
local active_seq = tl_state.get_sequence_id and tl_state.get_sequence_id() or "?"
print(string.format("  active sequence: %s (expected: %s)", active_seq, seq.id))
local all_db_clips = database.load_clips(seq.id)
print(string.format("  DB clips for seq: %d", #all_db_clips))
local clips = clip_state.get_all()
print(string.format("  clip_state.get_all: %d clips", #clips))
for i, c in ipairs(clips) do
    if i <= 5 then
        print(string.format("    [%d] id=%s name=%s media_path=%s offline=%s",
            i, tostring(c.id):sub(1,12), tostring(c.name),
            tostring(c.media_path), tostring(c.offline)))
    end
end

local braw_clips = {}
for _, clip in ipairs(clips) do
    local mp = clip.media_path or ""
    for _, path in ipairs(fake_paths) do
        if mp == path then
            braw_clips[#braw_clips + 1] = clip
            break
        end
    end
end

print(string.format("  found %d BRAW clips matching fake paths", #braw_clips))
assert(#braw_clips == 3, string.format("Expected 3 BRAW clips, got %d", #braw_clips))

-- THE KEY ASSERTION: clips must be offline/Unsupported on first paint
local failures = 0
for _, clip in ipairs(braw_clips) do
    if not clip.offline or clip.error_code ~= "Unsupported" then
        print(string.format("  FAIL: %s offline=%s error=%s — expected offline/Unsupported",
            clip.name, tostring(clip.offline), tostring(clip.error_code)))
        failures = failures + 1
    else
        print(string.format("  OK: %s offline=true error_code=Unsupported", clip.name))
    end
end
assert(failures == 0,
    string.format("%d clips show wrong status — persisted codec errors not applied before first paint", failures))

-- Cleanup
for _, path in ipairs(fake_paths) do os.remove(path) end

print("✅ test_codec_status_on_startup.lua passed")
