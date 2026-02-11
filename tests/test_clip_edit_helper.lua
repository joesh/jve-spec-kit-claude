require("test_env")

local database = require("core.database")
local _ = require("models.track")  -- luacheck: ignore 211

-- Stub timeline_state before clip_edit_helper is required
-- (it loads via pcall, so we can control what it sees)
local mock_timeline_state = {}
package.loaded["ui.timeline.timeline_state"] = mock_timeline_state

local clip_edit_helper = require("core.clip_edit_helper")

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

--- Simple command mock that records set_parameter calls.
local function mock_command()
    local params = {}
    return {
        set_parameter = function(self, k, v) params[k] = v end,
        get_parameter = function(self, k) return params[k] end,
        params = params,
    }
end

print("\n=== clip_edit_helper Tests (T7) ===")

-- Set up database with schema
local db_path = "/tmp/jve/test_clip_edit_helper.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

-- Seed: project + sequence + tracks + media
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
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
    VALUES ('trk_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a1', 'seq1', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'shot.mov', '/tmp/jve/shot.mov', 500,
        24, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now))

-- Sequence with no tracks (for error paths)
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq_empty', 'proj1', 'Empty', 'timeline', 24, 1, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now))


-- ═══════════════════════════════════════════════════════════════
-- 1. resolve_media_id_from_ui
-- ═══════════════════════════════════════════════════════════════

print("\n--- 1. resolve_media_id_from_ui ---")

-- 1a. Already provided → pass through
local result = clip_edit_helper.resolve_media_id_from_ui("med1", nil)
check("media_id provided → pass through", result == "med1")

-- 1b. Empty string → attempts UI resolution (no ui.ui_state → nil)
package.loaded["ui.ui_state"] = nil  -- ensure no mock
result = clip_edit_helper.resolve_media_id_from_ui("", nil)
check("media_id '' no UI → nil", result == nil or result == "")

-- 1c. nil → attempts UI resolution → nil without UI
result = clip_edit_helper.resolve_media_id_from_ui(nil, nil)
check("media_id nil no UI → nil", result == nil)

-- 1d. With mocked UI state → resolves from project browser
local cmd = mock_command()
package.loaded["ui.ui_state"] = {
    get_project_browser = function()
        return {
            get_selected_master_clip = function()
                return { media_id = "med_from_ui" }
            end
        }
    end
}
result = clip_edit_helper.resolve_media_id_from_ui(nil, cmd)
check("media_id from UI", result == "med_from_ui")
check("media_id set on command", cmd.params.media_id == "med_from_ui")

-- Cleanup UI mock
package.loaded["ui.ui_state"] = nil


-- ═══════════════════════════════════════════════════════════════
-- 2. resolve_sequence_id
-- ═══════════════════════════════════════════════════════════════

print("\n--- 2. resolve_sequence_id ---")

-- 2a. Provided in args → pass through
cmd = mock_command()
result = clip_edit_helper.resolve_sequence_id({ sequence_id = "seq1" }, nil, cmd)
check("sequence_id from args", result == "seq1")
check("sequence_id set on command", cmd.params.sequence_id == "seq1")

-- 2b. Resolve from track_id
cmd = mock_command()
result = clip_edit_helper.resolve_sequence_id({}, "trk_v1", cmd)
check("sequence_id from track", result == "seq1")

-- 2c. Fallback to timeline_state
mock_timeline_state.get_sequence_id = function() return "seq_from_ts" end
cmd = mock_command()
result = clip_edit_helper.resolve_sequence_id({}, nil, cmd)
check("sequence_id from timeline_state", result == "seq_from_ts")

-- 2d. All nil → nil
mock_timeline_state.get_sequence_id = nil
result = clip_edit_helper.resolve_sequence_id({}, nil, nil)
check("sequence_id all nil → nil", result == nil)


-- ═══════════════════════════════════════════════════════════════
-- 3. resolve_track_id
-- ═══════════════════════════════════════════════════════════════

print("\n--- 3. resolve_track_id ---")

-- 3a. Already provided → pass through
local track_id, err = clip_edit_helper.resolve_track_id("trk_v1", "seq1", nil)
check("track_id provided → pass through", track_id == "trk_v1")
check("no error", err == nil)

-- 3b. Nil → resolve first VIDEO track
cmd = mock_command()
local track_id2
track_id2, err = clip_edit_helper.resolve_track_id(nil, "seq1", cmd)
check("track_id resolved from seq", track_id2 == "trk_v1")
check("track_id set on command", cmd.params.track_id == "trk_v1")
check("no error on resolve", err == nil)

-- 3c. Empty sequence → error
track_id, err = clip_edit_helper.resolve_track_id(nil, "seq_empty", nil)
check("no VIDEO tracks → nil", track_id == nil)
check("error message", err ~= nil and err:match("no VIDEO tracks"))

-- 3d. Empty string track_id → resolve
local track_id3
track_id3, err = clip_edit_helper.resolve_track_id("", "seq1", nil)
check("empty string → resolves", track_id3 == "trk_v1" and err == nil)


-- ═══════════════════════════════════════════════════════════════
-- 4. resolve_edit_time
-- ═══════════════════════════════════════════════════════════════

print("\n--- 4. resolve_edit_time ---")

-- 4a. Explicit value → pass through (including 0)
result = clip_edit_helper.resolve_edit_time(0, nil, "insert_time")
check("edit_time=0 → 0 (not nil)", result == 0)

result = clip_edit_helper.resolve_edit_time(42, nil, "insert_time")
check("edit_time=42 → 42", result == 42)

-- 4b. Integer value → pass through
local int_val = 10
result = clip_edit_helper.resolve_edit_time(int_val, nil, "insert_time")
check("edit_time integer → pass through", result == int_val)

-- 4c. nil → fallback to timeline_state playhead
mock_timeline_state.get_playhead_position = function() return 100 end
cmd = mock_command()
result = clip_edit_helper.resolve_edit_time(nil, cmd, "insert_time")
check("nil → playhead from timeline_state", result == 100)
check("param set on command", cmd.params.insert_time == 100)

-- 4d. nil with no timeline_state → nil
mock_timeline_state.get_playhead_position = nil
result = clip_edit_helper.resolve_edit_time(nil, nil, "overwrite_time")
check("nil no timeline → nil", result == nil)


-- ═══════════════════════════════════════════════════════════════
-- 5. resolve_clip_name
-- ═══════════════════════════════════════════════════════════════

print("\n--- 5. resolve_clip_name ---")

-- 5a. From args
result = clip_edit_helper.resolve_clip_name({ clip_name = "Custom" }, nil, nil, "default")
check("name from args", result == "Custom")

-- 5b. From master_clip
result = clip_edit_helper.resolve_clip_name({}, { name = "Master" }, nil, "default")
check("name from master_clip", result == "Master")

-- 5c. From media
result = clip_edit_helper.resolve_clip_name({}, nil, { name = "shot.mov" }, "default")
check("name from media", result == "shot.mov")

-- 5d. Fallback
result = clip_edit_helper.resolve_clip_name({}, nil, nil, "Untitled")
check("name fallback", result == "Untitled")

-- 5e. Priority: args > master > media > fallback
result = clip_edit_helper.resolve_clip_name(
    { clip_name = "A" }, { name = "B" }, { name = "C" }, "D")
check("name priority: args wins", result == "A")

result = clip_edit_helper.resolve_clip_name(
    {}, { name = "B" }, { name = "C" }, "D")
check("name priority: master wins", result == "B")


-- ═══════════════════════════════════════════════════════════════
-- 6. resolve_timing
-- ═══════════════════════════════════════════════════════════════

print("\n--- 6. resolve_timing ---")

-- resolve_timing now returns plain integers: {duration, source_in, source_out}

-- 6a. Explicit duration + source_in → computes source_out
local timing, timing_err = clip_edit_helper.resolve_timing(
    { duration_value = 100, source_in_value = 10 },
    nil, nil)
check("explicit timing → success", timing ~= nil)
check("timing no error", timing_err == nil)
check("duration = 100", timing.duration == 100)
check("source_in = 10", timing.source_in == 10)
check("source_out = 110", timing.source_out == 110)

-- 6b. Explicit source_in + source_out → computes duration
timing, timing_err = clip_edit_helper.resolve_timing(
    { source_in_value = 0, source_out_value = 50 },
    nil, nil)
check("in+out → duration", timing ~= nil and timing.duration == 50 and timing_err == nil)

-- 6c. No duration, no source_out, no media → error
timing, timing_err = clip_edit_helper.resolve_timing(
    {}, nil, nil)
check("no timing → nil", timing == nil)
check("error message", timing_err ~= nil and timing_err:match("invalid duration"))

-- 6d. Fallback to master_clip duration
local master = {
    duration = 75,
    source_in = 5,
}
timing, timing_err = clip_edit_helper.resolve_timing(
    {}, master, nil)
check("master_clip fallback", timing ~= nil and timing_err == nil)
check("master duration", timing.duration == 75)
check("master source_in", timing.source_in == 5)

-- 6e. Fallback to media duration
local media_obj = {
    duration = 200,
}
timing, timing_err = clip_edit_helper.resolve_timing(
    {}, nil, media_obj)
check("media fallback", timing ~= nil and timing_err == nil)
check("media duration", timing.duration == 200)
check("media default source_in = 0", timing.source_in == 0)

-- 6f. source_in defaults to 0 when not provided
timing, timing_err = clip_edit_helper.resolve_timing(
    { duration_value = 30 }, nil, nil)
check("default source_in = 0", timing.source_in == 0 and timing_err == nil)
check("source_out = 30", timing.source_out == 30)

-- 6g. Zero duration → error
timing, timing_err = clip_edit_helper.resolve_timing(
    { duration_value = 0 }, nil, nil)
check("zero duration → nil", timing == nil)
check("zero duration error", timing_err ~= nil and timing_err:match("invalid duration"))


-- ═══════════════════════════════════════════════════════════════
-- 7. create_selected_clip
-- ═══════════════════════════════════════════════════════════════

print("\n--- 7. create_selected_clip ---")

local dur = 100
local si = 0
local so = 100

-- 7a. Video-only (0 audio channels)
local sc = clip_edit_helper.create_selected_clip({
    media_id = "med1", master_clip_id = "mc1", project_id = "proj1",
    duration = dur, source_in = si, source_out = so,
    clip_name = "MyClip", audio_channels = 0,
})
check("has_video → true", sc:has_video() == true)
check("has_audio → false (0 channels)", sc:has_audio() == false)
check("audio_channel_count → 0", sc:audio_channel_count() == 0)
check("video.role = video", sc.video.role == "video")
check("video.media_id", sc.video.media_id == "med1")
check("video.clip_name", sc.video.clip_name == "MyClip")
check("video.duration", sc.video.duration == dur)

-- 7b. With audio channels
sc = clip_edit_helper.create_selected_clip({
    media_id = "med1", master_clip_id = "mc1", project_id = "proj1",
    duration = dur, source_in = si, source_out = so,
    clip_name = "MyClip", audio_channels = 2,
})
check("has_audio → true", sc:has_audio() == true)
check("audio_channel_count → 2", sc:audio_channel_count() == 2)

-- 7c. audio(0) → first channel payload
local ach = sc:audio(0)
check("audio(0).role = audio", ach.role == "audio")
check("audio(0).channel = 0", ach.channel == 0)
check("audio(0).clip_name", ach.clip_name == "MyClip (Audio)")
check("audio(0).media_id", ach.media_id == "med1")

-- 7d. audio(1) → second channel
ach = sc:audio(1)
check("audio(1).channel = 1", ach.channel == 1)

-- 7e. audio out of bounds → assert
expect_error("audio(-1) → assert", function()
    sc:audio(-1)
end, "invalid audio channel")

expect_error("audio(2) out of range → assert", function()
    sc:audio(2)
end, "invalid audio channel")

-- 7f. Default audio_channels = 0 when nil
sc = clip_edit_helper.create_selected_clip({
    media_id = "med1", master_clip_id = "mc1", project_id = "proj1",
    duration = dur, source_in = si, source_out = so,
    clip_name = "Test",
})
check("nil audio_channels defaults to 0", sc:audio_channel_count() == 0)
check("nil audio_channels → no audio", sc:has_audio() == false)


-- ═══════════════════════════════════════════════════════════════
-- 8. get_media_fps
-- ═══════════════════════════════════════════════════════════════

print("\n--- 8. get_media_fps ---")

-- 8a. From master_clip
local fps_n, fps_d = clip_edit_helper.get_media_fps(
    db,
    { rate = { fps_numerator = 30000, fps_denominator = 1001 } },
    "med1", 24, 1)
check("fps from master_clip num", fps_n == 30000)
check("fps from master_clip den", fps_d == 1001)

-- 8b. From media_id (database lookup)
fps_n, fps_d = clip_edit_helper.get_media_fps(db, nil, "med1", 24, 1)
check("fps from media_id num", fps_n == 24)
check("fps from media_id den", fps_d == 1)

-- 8c. No master_clip, no media_id → sequence fps fallback
fps_n, fps_d = clip_edit_helper.get_media_fps(db, nil, nil, 30, 1)
check("fps fallback to seq num", fps_n == 30)
check("fps fallback to seq den", fps_d == 1)

-- 8d. Empty media_id → sequence fps fallback
fps_n, fps_d = clip_edit_helper.get_media_fps(db, nil, "", 25, 1)
check("fps empty media_id → seq", fps_n == 25 and fps_d == 1)

-- 8e. master_clip without rate → assert
expect_error("master_clip no rate → assert", function()
    clip_edit_helper.get_media_fps(db, { name = "no_rate" }, "med1", 24, 1)
end, "missing rate")


-- ═══════════════════════════════════════════════════════════════
-- 9. create_audio_track_resolver
-- ═══════════════════════════════════════════════════════════════

print("\n--- 9. create_audio_track_resolver ---")

-- Clear timeline_state mock so resolver uses DB
mock_timeline_state.get_audio_tracks = nil

-- 9a. Resolve existing audio track (index 0 → trk_a1)
local resolver = clip_edit_helper.create_audio_track_resolver("seq1")
local track = resolver(nil, 0)
check("resolver(0) → trk_a1", track.id == "trk_a1")

-- 9b. Resolve beyond existing → creates new track
track = resolver(nil, 1)
check("resolver(1) creates new track", track ~= nil)
check("new track is AUDIO", track.track_type == "AUDIO")
check("new track name is A2", track.name == "A2")

-- 9c. Negative index → assert
expect_error("resolver(-1) → assert", function()
    resolver(nil, -1)
end, "invalid audio track")

-- 9d. Resolver with timeline_state mock
mock_timeline_state.get_audio_tracks = function()
    return {
        { id = "ts_a1", track_type = "AUDIO", track_index = 1 },
        { id = "ts_a2", track_type = "AUDIO", track_index = 2 },
    }
end
local resolver2 = clip_edit_helper.create_audio_track_resolver("seq1")
track = resolver2(nil, 0)
check("resolver from timeline_state", track.id == "ts_a1")
track = resolver2(nil, 1)
check("resolver ts index 1", track.id == "ts_a2")

-- Cleanup
mock_timeline_state.get_audio_tracks = nil


-- ═══════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
    print("❌ test_clip_edit_helper.lua FAILED")
    os.exit(1)
else
    print("✅ test_clip_edit_helper.lua passed")
end
