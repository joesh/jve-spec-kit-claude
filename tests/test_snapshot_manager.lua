require("test_env")

local database = require("core.database")
local Rational = require("core.rational")
local snapshot_manager = require("core.snapshot_manager")

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

print("\n=== Snapshot Manager Tests (T9) ===")

-- ============================================================
-- should_snapshot
-- ============================================================
print("\n--- should_snapshot ---")
do
    check("interval 50 → true", snapshot_manager.should_snapshot(50))
    check("interval 100 → true", snapshot_manager.should_snapshot(100))
    check("interval 0 → false (must be > 0)", not snapshot_manager.should_snapshot(0))
    check("interval 1 → false", not snapshot_manager.should_snapshot(1))
    check("interval 49 → false", not snapshot_manager.should_snapshot(49))
    check("interval 51 → false", not snapshot_manager.should_snapshot(51))
    check("negative → false", not snapshot_manager.should_snapshot(-50))
    check("SNAPSHOT_INTERVAL exposed", snapshot_manager.SNAPSHOT_INTERVAL == 50)
end

-- ============================================================
-- Database setup for create/load tests
-- ============================================================
local db_path = "/tmp/jve/test_snapshot_manager.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()

-- Seed project
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);
]], now, now))

-- Seed sequence with all required fields
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Timeline 1', 'timeline', 24, 1, 48000,
        1920, 1080, 0, 240, 10, '[]', '[]', %d, %d);
]], now, now))

-- Seed track
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

-- Seed media
db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'shot_01.mov', '/tmp/shot_01.mov', 1000,
        24, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now))

-- ============================================================
-- create_snapshot + load_snapshot: round-trip with clips
-- ============================================================
print("\n--- create_snapshot + load_snapshot: round-trip ---")
do
    local clips = {
        {
            id = "clip1",
            clip_kind = "timeline",
            name = "My Clip",
            project_id = "proj1",
            track_id = "trk1",
            owner_sequence_id = "seq1",
            parent_clip_id = nil,
            source_sequence_id = nil,
            media_id = "med1",
            timeline_start = 0,
            duration = 100,
            source_in = 0,
            source_out = 100,
            rate = { fps_numerator = 24, fps_denominator = 1 },
            enabled = true,
            offline = false,
        },
    }

    local ok = snapshot_manager.create_snapshot(db, "seq1", 50, clips)
    check("create_snapshot returns true", ok == true)

    local snap = snapshot_manager.load_snapshot(db, "seq1")
    check("load_snapshot not nil", snap ~= nil)
    check("snapshot sequence_number", snap.sequence_number == 50)

    -- Sequence record
    check("snapshot has sequence", snap.sequence ~= nil)
    check("sequence.id", snap.sequence.id == "seq1")
    check("sequence.project_id", snap.sequence.project_id == "proj1")
    check("sequence.name", snap.sequence.name == "Timeline 1")
    check("sequence.fps_numerator", snap.sequence.fps_numerator == 24)
    check("sequence.playhead_frame", snap.sequence.playhead_frame == 10)

    -- Tracks
    check("snapshot has tracks", #snap.tracks == 1)
    check("track.id", snap.tracks[1].id == "trk1")
    check("track.track_type", snap.tracks[1].track_type == "VIDEO")
    check("track.name", snap.tracks[1].name == "V1")

    -- Clips with Rational reconstruction
    check("snapshot has clips", #snap.clips == 1)
    local c = snap.clips[1]
    check("clip.id", c.id == "clip1")
    check("clip.clip_kind", c.clip_kind == "timeline")
    check("clip.name", c.name == "My Clip")
    check("clip.track_id", c.track_id == "trk1")
    check("clip.media_id", c.media_id == "med1")
    check("clip.timeline_start is Rational", c.timeline_start ~= nil and c.timeline_start ~= nil)
    check("clip.timeline_start == 0", c.timeline_start == 0)
    check("clip.duration == 100", c.duration == 100)
    check("clip.source_in == 0", c.source_in == 0)
    check("clip.source_out == 100", c.source_out == 100)
    check("clip.rate.fps_numerator", c.rate.fps_numerator == 24)
    check("clip.rate.fps_denominator", c.rate.fps_denominator == 1)
    check("clip.enabled == true", c.enabled == true)
    check("clip.offline == false", c.offline == false)

    -- Media
    check("snapshot has media", #snap.media == 1)
    local m = snap.media[1]
    check("media.id", m.id == "med1")
    check("media.name", m.name == "shot_01.mov")
    check("media.file_path", m.file_path == "/tmp/shot_01.mov")
    check("media.duration is Rational", m.duration ~= nil and m.duration ~= nil)
    check("media.duration == 1000", m.duration == 1000)
    check("media.frame_rate.fps_numerator", m.frame_rate.fps_numerator == 24)
    check("media.width", m.width == 1920)
    check("media.audio_channels", m.audio_channels == 2)
end

-- ============================================================
-- create_snapshot overwrites previous
-- ============================================================
print("\n--- create_snapshot: overwrites previous ---")
do
    local clips2 = {
        {
            id = "clip2",
            clip_kind = "timeline",
            name = "Clip 2",
            project_id = "proj1",
            track_id = "trk1",
            owner_sequence_id = "seq1",
            media_id = "med1",
            timeline_start = 200,
            duration = 50,
            source_in = 0,
            source_out = 50,
            rate = { fps_numerator = 24, fps_denominator = 1 },
            enabled = true,
            offline = false,
        },
    }

    local ok = snapshot_manager.create_snapshot(db, "seq1", 100, clips2)
    check("overwrite create returns true", ok == true)

    local snap = snapshot_manager.load_snapshot(db, "seq1")
    check("overwrite sequence_number updated", snap.sequence_number == 100)
    check("overwrite has 1 clip (new set)", #snap.clips == 1)
    check("overwrite clip is clip2", snap.clips[1].id == "clip2")
end

-- ============================================================
-- create_snapshot: empty clips
-- ============================================================
print("\n--- create_snapshot: empty clips ---")
do
    local ok = snapshot_manager.create_snapshot(db, "seq1", 150, {})
    check("empty clips create returns true", ok == true)

    local snap = snapshot_manager.load_snapshot(db, "seq1")
    check("empty clips snapshot loaded", snap ~= nil)
    check("empty clips sequence_number", snap.sequence_number == 150)
    check("empty clips has 0 clips", #snap.clips == 0)
    check("empty clips has sequence", snap.sequence ~= nil)
    check("empty clips has tracks", #snap.tracks == 1)
end

-- ============================================================
-- load_snapshot: nonexistent sequence
-- ============================================================
print("\n--- load_snapshot: nonexistent sequence ---")
do
    local snap = snapshot_manager.load_snapshot(db, "no_such_seq")
    check("nonexistent sequence → nil", snap == nil)
end

-- ============================================================
-- create_snapshot: missing params (asserts disabled)
-- ============================================================
print("\n--- create_snapshot: missing params ---")
do
    local asserts_mod = require("core.asserts")
    local was_enabled = asserts_mod.enabled()
    asserts_mod._set_enabled_for_tests(false)

    check("nil db → false", snapshot_manager.create_snapshot(nil, "seq1", 50, {}) == false)
    check("nil sequence_id → false", snapshot_manager.create_snapshot(db, nil, 50, {}) == false)
    check("nil sequence_number → false", snapshot_manager.create_snapshot(db, "seq1", nil, {}) == false)
    check("nil clips → false", snapshot_manager.create_snapshot(db, "seq1", 50, nil) == false)

    asserts_mod._set_enabled_for_tests(was_enabled)
end

-- ============================================================
-- load_snapshot: missing params (asserts disabled)
-- ============================================================
print("\n--- load_snapshot: missing params ---")
do
    local asserts_mod = require("core.asserts")
    local was_enabled = asserts_mod.enabled()
    asserts_mod._set_enabled_for_tests(false)

    check("load nil db → nil", snapshot_manager.load_snapshot(nil, "seq1") == nil)
    check("load nil sequence_id → nil", snapshot_manager.load_snapshot(db, nil) == nil)

    asserts_mod._set_enabled_for_tests(was_enabled)
end

-- ============================================================
-- create_snapshot: missing params (asserts enabled)
-- ============================================================
print("\n--- create_snapshot: missing params (asserts enabled) ---")
do
    expect_error("create nil db asserts", function()
        snapshot_manager.create_snapshot(nil, "seq1", 50, {})
    end, "missing required parameters")

    expect_error("create nil sequence_id asserts", function()
        snapshot_manager.create_snapshot(db, nil, 50, {})
    end, "missing required parameters")
end

-- ============================================================
-- load_snapshot: missing params (asserts enabled)
-- ============================================================
print("\n--- load_snapshot: missing params (asserts enabled) ---")
do
    expect_error("load nil db asserts", function()
        snapshot_manager.load_snapshot(nil, "seq1")
    end, "missing required parameters")

    expect_error("load nil sequence_id asserts", function()
        snapshot_manager.load_snapshot(db, nil)
    end, "missing required parameters")
end

-- ============================================================
-- create_snapshot: clip missing required field
-- ============================================================
print("\n--- create_snapshot: clip missing required fields ---")
do
    expect_error("clip missing id", function()
        snapshot_manager.create_snapshot(db, "seq1", 200, {{ clip_kind = "timeline" }})
    end, "missing required field 'id'")

    expect_error("clip missing clip_kind", function()
        snapshot_manager.create_snapshot(db, "seq1", 200, {{ id = "c1" }})
    end, "missing required field 'clip_kind'")
end

-- ============================================================
-- Rational reconstruction accuracy
-- ============================================================
print("\n--- Rational reconstruction accuracy ---")
do
    local clips = {
        {
            id = "clip_r",
            clip_kind = "timeline",
            name = "Rational Test",
            project_id = "proj1",
            track_id = "trk1",
            owner_sequence_id = "seq1",
            media_id = "med1",
            timeline_start = 120,
            duration = 300,
            source_in = 10,
            source_out = 310,
            rate = { fps_numerator = 30, fps_denominator = 1 },
            enabled = false,
            offline = true,
        },
    }

    snapshot_manager.create_snapshot(db, "seq1", 250, clips)
    local snap = snapshot_manager.load_snapshot(db, "seq1")
    local c = snap.clips[1]

    check("30fps clip timeline_start.frames", c.timeline_start == 120)
    check("30fps clip duration.frames", c.duration == 300)
    check("30fps clip source_in.frames", c.source_in == 10)
    check("30fps clip source_out.frames", c.source_out == 310)
    check("30fps clip rate.fps_numerator", c.rate.fps_numerator == 30)
    check("30fps clip rate.fps_denominator", c.rate.fps_denominator == 1)
    check("30fps clip enabled=false", c.enabled == false)
    check("30fps clip offline=true", c.offline == true)
end

-- ============================================================
-- Media deduplication
-- ============================================================
print("\n--- media deduplication ---")
do
    -- Two clips referencing the same media
    local clips = {
        {
            id = "clip_d1", clip_kind = "timeline", name = "D1",
            project_id = "proj1", track_id = "trk1", owner_sequence_id = "seq1",
            media_id = "med1",
            timeline_start = 0,
            duration = 50,
            source_in = 0,
            source_out = 50,
            rate = { fps_numerator = 24, fps_denominator = 1 },
            enabled = true, offline = false,
        },
        {
            id = "clip_d2", clip_kind = "timeline", name = "D2",
            project_id = "proj1", track_id = "trk1", owner_sequence_id = "seq1",
            media_id = "med1",
            timeline_start = 50,
            duration = 50,
            source_in = 50,
            source_out = 100,
            rate = { fps_numerator = 24, fps_denominator = 1 },
            enabled = true, offline = false,
        },
    }

    snapshot_manager.create_snapshot(db, "seq1", 300, clips)
    local snap = snapshot_manager.load_snapshot(db, "seq1")
    check("dedup: 2 clips", #snap.clips == 2)
    check("dedup: 1 media (not 2)", #snap.media == 1)
    check("dedup: media is med1", snap.media[1].id == "med1")
end

-- ============================================================
-- Clip with no media_id
-- ============================================================
print("\n--- clip with no media ---")
do
    local clips = {
        {
            id = "clip_nm", clip_kind = "timeline", name = "No Media",
            project_id = "proj1", track_id = "trk1", owner_sequence_id = "seq1",
            media_id = nil,
            timeline_start = 0,
            duration = 30,
            source_in = 0,
            source_out = 30,
            rate = { fps_numerator = 24, fps_denominator = 1 },
            enabled = true, offline = false,
        },
    }

    snapshot_manager.create_snapshot(db, "seq1", 350, clips)
    local snap = snapshot_manager.load_snapshot(db, "seq1")
    check("no-media clip loaded", #snap.clips == 1)
    check("no-media: 0 media", #snap.media == 0)
end

-- ============================================================
-- load_project_snapshots
-- ============================================================
print("\n--- load_project_snapshots ---")
do
    -- Create second sequence in same project
    db:exec(string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
            audio_rate, width, height, view_start_frame, view_duration_frames,
            playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
        VALUES ('seq2', 'proj1', 'Timeline 2', 'timeline', 30, 1, 48000,
            1920, 1080, 0, 300, 0, '[]', '[]', %d, %d);
    ]], now, now))
    db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
            enabled, locked, muted, soloed, volume, pan)
        VALUES ('trk2', 'seq2', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    ]])

    -- Snapshot seq1 at 50, seq2 at 75
    snapshot_manager.create_snapshot(db, "seq1", 50, {
        { id = "cs1", clip_kind = "timeline", name = "S1C",
          project_id = "proj1", track_id = "trk1", owner_sequence_id = "seq1",
          media_id = "med1",
          timeline_start = 0, duration = 10,
          source_in = 0, source_out = 10,
          rate = { fps_numerator = 24, fps_denominator = 1 },
          enabled = true, offline = false },
    })
    snapshot_manager.create_snapshot(db, "seq2", 75, {
        { id = "cs2", clip_kind = "timeline", name = "S2C",
          project_id = "proj1", track_id = "trk2", owner_sequence_id = "seq2",
          media_id = "med1",
          timeline_start = 0, duration = 20,
          source_in = 0, source_out = 20,
          rate = { fps_numerator = 30, fps_denominator = 1 },
          enabled = true, offline = false },
    })

    -- Load all for project with target_sequence_number=100 (both qualify)
    local all = snapshot_manager.load_project_snapshots(db, "proj1", 100, nil)
    check("project snapshots has seq1", all["seq1"] ~= nil)
    check("project snapshots has seq2", all["seq2"] ~= nil)
    check("seq1 snapshot number", all["seq1"].sequence_number == 50)
    check("seq2 snapshot number", all["seq2"].sequence_number == 75)
    check("seq1 has clips", #all["seq1"].clips == 1)
    check("seq2 has clips", #all["seq2"].clips == 1)

    -- Filter by target_sequence_number=60 (only seq1 at 50 qualifies)
    local filtered = snapshot_manager.load_project_snapshots(db, "proj1", 60, nil)
    check("filtered has seq1", filtered["seq1"] ~= nil)
    check("filtered missing seq2", filtered["seq2"] == nil)

    -- Exclude seq1
    local excluded = snapshot_manager.load_project_snapshots(db, "proj1", 100, "seq1")
    check("excluded missing seq1", excluded["seq1"] == nil)
    check("excluded has seq2", excluded["seq2"] ~= nil)

    -- nil/empty project → {}
    check("nil db → {}", next(snapshot_manager.load_project_snapshots(nil, "proj1", 100)) == nil)
    check("nil project_id → {}", next(snapshot_manager.load_project_snapshots(db, nil, 100)) == nil)

    -- Nonexistent project → {}
    check("nonexistent project → {}", next(snapshot_manager.load_project_snapshots(db, "no_proj", 100)) == nil)
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
    print("✅ test_snapshot_manager.lua passed")
end
