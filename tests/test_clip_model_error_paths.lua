require("test_env")

local database = require("core.database")
local Rational = require("core.rational")
local Clip = require("models.clip")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== Clip Model Error Paths Tests (T12) ===")

-- Set up database
local db_path = "/tmp/jve/test_clip_model_error_paths.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()

db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq1', 'timeline', 24, 1, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'shot.mov', '/tmp/shot.mov', 1000,
        24, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now))

-- ============================================================
-- create(): missing required fields
-- ============================================================
print("\n--- create: missing required fields ---")
do
    expect_error("create missing fps_numerator", function()
        Clip.create("Test", "med1", {
            fps_denominator = 1,
            timeline_start = Rational.new(0, 24),
            duration = Rational.new(100, 24),
        })
    end, "fps_numerator is required")

    expect_error("create missing fps_denominator", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24,
            timeline_start = Rational.new(0, 24),
            duration = Rational.new(100, 24),
        })
    end, "fps_denominator is required")

    expect_error("create missing timeline_start", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24, fps_denominator = 1,
            duration = Rational.new(100, 24),
        })
    end, "timeline_start is required")

    expect_error("create missing duration", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24, fps_denominator = 1,
            timeline_start = Rational.new(0, 24),
        })
    end, "duration is required")
end

-- ============================================================
-- create(): non-Rational timeline_start / duration
-- ============================================================
print("\n--- create: non-Rational fields ---")
do
    expect_error("create timeline_start as number", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24, fps_denominator = 1,
            timeline_start = 0,
            duration = Rational.new(100, 24),
        })
    end, "timeline_start must be a Rational")

    expect_error("create duration as string", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24, fps_denominator = 1,
            timeline_start = Rational.new(0, 24),
            duration = "100",
        })
    end, "duration must be a Rational")
end

-- ============================================================
-- create(): legacy field names rejected
-- ============================================================
print("\n--- create: legacy field names ---")
do
    expect_error("create legacy start_value", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24, fps_denominator = 1,
            timeline_start = Rational.new(0, 24),
            duration = Rational.new(100, 24),
            start_value = 0,
        })
    end, "Legacy field names")

    expect_error("create legacy duration_value", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24, fps_denominator = 1,
            timeline_start = Rational.new(0, 24),
            duration = Rational.new(100, 24),
            duration_value = 100,
        })
    end, "Legacy field names")

    expect_error("create legacy source_in_value", function()
        Clip.create("Test", "med1", {
            fps_numerator = 24, fps_denominator = 1,
            timeline_start = Rational.new(0, 24),
            duration = Rational.new(100, 24),
            source_in_value = 0,
        })
    end, "Legacy field names")
end

-- ============================================================
-- create(): valid minimal + defaults
-- ============================================================
print("\n--- create: valid with defaults ---")
do
    local clip = Clip.create("My Clip", "med1", {
        fps_numerator = 24, fps_denominator = 1,
        timeline_start = Rational.new(0, 24),
        duration = Rational.new(100, 24),
    })
    check("create returns clip", clip ~= nil)
    check("create name", clip.name == "My Clip")
    check("create media_id", clip.media_id == "med1")
    check("create id generated", clip.id ~= nil and clip.id ~= "")
    check("create clip_kind default", clip.clip_kind == "timeline")
    check("create enabled default true", clip.enabled == true)
    check("create offline default false", clip.offline == false)
    check("create timeline_start frames", clip.timeline_start.frames == 0)
    check("create duration frames", clip.duration.frames == 100)
    check("create source_in default 0", clip.source_in.frames == 0)
    check("create source_out defaults to duration", clip.source_out.frames == 100)
    check("create rate", clip.rate.fps_numerator == 24)
end

-- ============================================================
-- create(): empty name → auto-generated
-- ============================================================
print("\n--- create: empty name ---")
do
    local clip = Clip.create("", "med1", {
        fps_numerator = 24, fps_denominator = 1,
        timeline_start = Rational.new(0, 24),
        duration = Rational.new(50, 24),
    })
    check("empty name auto-generated", clip.name:find("Clip ") == 1)

    local clip2 = Clip.create(nil, "med1", {
        fps_numerator = 24, fps_denominator = 1,
        timeline_start = Rational.new(0, 24),
        duration = Rational.new(50, 24),
    })
    check("nil name auto-generated", clip2.name:find("Clip ") == 1)
end

-- ============================================================
-- create(): all optional fields
-- ============================================================
print("\n--- create: all optional fields ---")
do
    local clip = Clip.create("Full", "med1", {
        id = "custom-id",
        project_id = "proj1",
        fps_numerator = 30, fps_denominator = 1,
        clip_kind = "master",
        track_id = "trk1",
        owner_sequence_id = "seq1",
        parent_clip_id = "parent1",
        source_sequence_id = "src_seq",
        timeline_start = Rational.new(10, 30),
        duration = Rational.new(200, 30),
        source_in = Rational.new(5, 30),
        source_out = Rational.new(205, 30),
        enabled = false,
        offline = true,
    })
    check("custom id", clip.id == "custom-id")
    check("custom project_id", clip.project_id == "proj1")
    check("custom clip_kind", clip.clip_kind == "master")
    check("custom track_id", clip.track_id == "trk1")
    check("custom source_in", clip.source_in.frames == 5)
    check("custom source_out", clip.source_out.frames == 205)
    check("custom enabled false", clip.enabled == false)
    check("custom offline true", clip.offline == true)
end

-- ============================================================
-- save() + load() round-trip
-- ============================================================
print("\n--- save + load round-trip ---")
do
    local clip = Clip.create("Save Test", "med1", {
        id = "clip-save-1",
        project_id = "proj1",
        fps_numerator = 24, fps_denominator = 1,
        track_id = "trk1",
        owner_sequence_id = "seq1",
        timeline_start = Rational.new(10, 24),
        duration = Rational.new(50, 24),
        source_in = Rational.new(0, 24),
        source_out = Rational.new(50, 24),
    })

    local ok = clip:save()
    check("save returns true", ok == true)

    local loaded = Clip.load("clip-save-1")
    check("load returns clip", loaded ~= nil)
    check("loaded name", loaded.name == "Save Test")
    check("loaded timeline_start", loaded.timeline_start.frames == 10)
    check("loaded duration", loaded.duration.frames == 50)
    check("loaded source_in", loaded.source_in.frames == 0)
    check("loaded source_out", loaded.source_out.frames == 50)
    check("loaded rate", loaded.rate.fps_numerator == 24)
    check("loaded enabled", loaded.enabled == true)
    check("loaded offline", loaded.offline == false)
    check("loaded has methods", type(loaded.save) == "function")
end

-- ============================================================
-- save(): UPDATE path
-- ============================================================
print("\n--- save: update path ---")
do
    local clip = Clip.load("clip-save-1")
    clip.timeline_start = Rational.new(20, 24)
    clip.duration = Rational.new(80, 24)
    local ok = clip:save()
    check("update save returns true", ok == true)

    local reloaded = Clip.load("clip-save-1")
    check("updated timeline_start", reloaded.timeline_start.frames == 20)
    check("updated duration", reloaded.duration.frames == 80)
end

-- ============================================================
-- save(): non-Rational fields → error
-- ============================================================
print("\n--- save: non-Rational fields ---")
do
    local clip = Clip.load("clip-save-1")
    clip.timeline_start = 42
    expect_error("save non-Rational timeline_start", function()
        clip:save()
    end, "timeline_start is not Rational")

    local clip2 = Clip.load("clip-save-1")
    clip2.duration = "bad"
    expect_error("save non-Rational duration", function()
        clip2:save()
    end, "duration is not Rational")
end

-- ============================================================
-- save(): invalid clip ID
-- ============================================================
print("\n--- save: invalid clip ID ---")
do
    local clip = Clip.create("No ID", "med1", {
        fps_numerator = 24, fps_denominator = 1,
        timeline_start = Rational.new(0, 24),
        duration = Rational.new(10, 24),
    })
    clip.id = ""
    expect_error("save empty id asserts", function()
        clip:save()
    end, "clip id is required")

    clip.id = nil
    expect_error("save nil id asserts", function()
        clip:save()
    end, "clip id is required")
end

-- ============================================================
-- load(): error paths
-- ============================================================
print("\n--- load: error paths ---")
do
    expect_error("load nil clip_id", function()
        Clip.load(nil)
    end, "Invalid clip_id")

    expect_error("load empty clip_id", function()
        Clip.load("")
    end, "Invalid clip_id")

    expect_error("load nonexistent clip", function()
        Clip.load("nonexistent-clip-id")
    end, "Clip not found")
end

-- ============================================================
-- load_optional(): graceful nil
-- ============================================================
print("\n--- load_optional ---")
do
    check("load_optional nil id", Clip.load_optional(nil) == nil)
    check("load_optional empty id", Clip.load_optional("") == nil)
    check("load_optional nonexistent", Clip.load_optional("nonexistent") == nil)

    local clip = Clip.load_optional("clip-save-1")
    check("load_optional existing", clip ~= nil)
    check("load_optional existing name", clip.name == "Save Test")
end

-- NOTE: NULL frame data and zero fps_numerator tests are unreachable at SQL level.
-- Schema enforces: timeline_start_frame INTEGER NOT NULL, CHECK(fps_numerator > 0).
-- The Lua-side assert guards (lines 113-120, 149-152) are defensive against schema corruption.
-- These cannot be tested without bypassing SQLite constraints.

-- ============================================================
-- load(): master clip (no sequence fps needed)
-- ============================================================
print("\n--- load: master clip no sequence fps ---")
do
    -- Master clip without track (no sequence join)
    db:exec(string.format([[
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
            owner_sequence_id,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES ('clip-master', 'proj1', 'master', 'Master Clip', NULL, 'med1',
            NULL,
            0, 1000, 0, 1000,
            24, 1, 1, 0, %d, %d);
    ]], now, now))

    local clip = Clip.load("clip-master")
    check("master clip loaded", clip ~= nil)
    check("master clip_kind", clip.clip_kind == "master")
    -- Master uses clip fps for timeline fields too
    check("master timeline_start fps", clip.timeline_start.fps_numerator == 24)
end

-- ============================================================
-- delete()
-- ============================================================
print("\n--- delete ---")
do
    local clip = Clip.create("Delete Me", "med1", {
        id = "clip-delete",
        project_id = "proj1",
        fps_numerator = 24, fps_denominator = 1,
        track_id = "trk1",
        owner_sequence_id = "seq1",
        timeline_start = Rational.new(0, 24),
        duration = Rational.new(10, 24),
    })
    clip:save()
    check("delete: exists before", Clip.load_optional("clip-delete") ~= nil)

    local ok = clip:delete()
    check("delete returns true", ok == true)
    check("delete: gone after", Clip.load_optional("clip-delete") == nil)
end

-- ============================================================
-- get_sequence_id()
-- ============================================================
print("\n--- get_sequence_id ---")
do
    local seq_id = Clip.get_sequence_id("clip-save-1")
    check("get_sequence_id returns seq1", seq_id == "seq1")

    expect_error("get_sequence_id nil", function()
        Clip.get_sequence_id(nil)
    end, "clip_id is required")

    expect_error("get_sequence_id empty", function()
        Clip.get_sequence_id("")
    end, "clip_id is required")

    expect_error("get_sequence_id nonexistent", function()
        Clip.get_sequence_id("nonexistent")
    end, "not found or has no track")
end

-- ============================================================
-- find_at_time()
-- ============================================================
print("\n--- find_at_time ---")
do
    -- clip-save-1 is at timeline_start=20, duration=80 (frames 20-99)
    local found = Clip.find_at_time("trk1", Rational.new(50, 24))
    check("find_at_time within clip", found ~= nil)
    check("find_at_time correct clip", found.id == "clip-save-1")

    -- At exact start
    local at_start = Clip.find_at_time("trk1", Rational.new(20, 24))
    check("find_at_time at start", at_start ~= nil and at_start.id == "clip-save-1")

    -- Just before end (99)
    local before_end = Clip.find_at_time("trk1", Rational.new(99, 24))
    check("find_at_time before end", before_end ~= nil and before_end.id == "clip-save-1")

    -- At end (100) → not found (exclusive)
    local at_end = Clip.find_at_time("trk1", Rational.new(100, 24))
    -- clip-zero-fps is at 0-100 but has fps=0 so it errored on load.
    -- clip-null-start can't be found. So at 100 nothing should be found.
    check("find_at_time at end exclusive", at_end == nil)

    -- Before clip
    local before = Clip.find_at_time("trk1", Rational.new(5, 24))
    -- clip-zero-fps occupies 0-100 with track_id trk1, but it has fps=0.
    -- Actually find_at_time queries then calls Clip.load() which would error.
    -- Let me check: clip-zero-fps has enabled=1 and track_id=trk1, start=0, dur=100
    -- So it would match frame 5 → Clip.load("clip-zero-fps") → error.
    -- Clean it up first.
end

do
    local before = Clip.find_at_time("trk1", Rational.new(5, 24))
    check("find_at_time before clip", before == nil)

    -- Empty track
    local empty = Clip.find_at_time("trk1", Rational.new(500, 24))
    check("find_at_time empty region", empty == nil)

    expect_error("find_at_time nil track", function()
        Clip.find_at_time(nil, Rational.new(0, 24))
    end, "track_id is required")

    expect_error("find_at_time nil time", function()
        Clip.find_at_time("trk1", nil)
    end, "time_rat must be a Rational")
end

-- ============================================================
-- restore_without_occlusion()
-- ============================================================
print("\n--- restore_without_occlusion ---")
do
    local clip = Clip.load("clip-save-1")
    clip.timeline_start = Rational.new(0, 24)
    local ok = clip:restore_without_occlusion()
    check("restore_without_occlusion returns true", ok == true)

    local reloaded = Clip.load("clip-save-1")
    check("restore updated value", reloaded.timeline_start.frames == 0)
end

-- ============================================================
-- get_property / set_property
-- ============================================================
print("\n--- get_property / set_property ---")
do
    local clip = Clip.load("clip-save-1")
    check("get_property name", clip:get_property("name") == "Save Test")
    check("get_property nil field", clip:get_property("nonexistent") == nil)

    clip:set_property("name", "Renamed")
    check("set_property updates", clip.name == "Renamed")
    check("get_property after set", clip:get_property("name") == "Renamed")
end

-- ============================================================
-- generate_id()
-- ============================================================
print("\n--- generate_id ---")
do
    local id1 = Clip.generate_id()
    local id2 = Clip.generate_id()
    check("generate_id returns string", type(id1) == "string")
    check("generate_id non-empty", id1 ~= "")
    check("generate_id unique", id1 ~= id2)
end

-- ============================================================
-- Summary
-- ============================================================
print("")
print(string.format("Passed: %d  Failed: %d  Total: %d", pass_count, fail_count, pass_count + fail_count))
if fail_count > 0 then
    print("SOME TESTS FAILED")
    os.exit(1)
else
    print("✅ test_clip_model_error_paths.lua passed")
end
