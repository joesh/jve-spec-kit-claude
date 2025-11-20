#!/usr/bin/env luajit

-- Overlap regressions using the real timeline_state path.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;tests/?/init.lua;" .. package.path

local test_env = require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")
local Clip = require("models.clip")

local function assert_true(label, value)
    if not value then
        io.stderr:write(label .. "\n")
        os.exit(1)
    end
end

local function assert_no_overlap(label, clips)
    table.sort(clips, function(a, b)
        if a.track_id == b.track_id then
            return a.start_time < b.start_time
        end
        return a.track_id < b.track_id
    end)
    local last_end = {}
    for _, c in ipairs(clips) do
        local e = (c.start_time or 0) + (c.duration or 0)
        local prev = last_end[c.track_id]
        if prev and (c.start_time < prev) then
            io.stderr:write(string.format("%s: overlap on %s between clips near %d\n", label, c.track_id, c.start_time))
            os.exit(1)
        end
        last_end[c.track_id] = e
    end
end

local function seed_db(layout)
    local db = test_env.reset_db()

    local db_module = require('core.database')
    for _, t in ipairs(layout.tracks) do
        local ok = db_module.insert_track_row({
            id = t.id,
            sequence_id = "default_sequence",
            name = t.name or t.id,
            track_type = t.track_type or "VIDEO",
            timebase_type = t.timebase_type or "video_frames",
            timebase_rate = t.timebase_rate or 30.0,
            track_index = t.index or 1,
            enabled = true
        }, db)
        assert_true("track", ok)
    end

    for _, media in ipairs(layout.media) do
        assert_true("media", db:exec(string.format([[INSERT INTO media (id, project_id, name, file_path, file_name, duration, frame_rate, width, height, audio_channels)
          VALUES ('%s','default_project','%s','/tmp/%s.mov','%s',%d,%.1f,1920,1080,2);]],
          media.id, media.name or media.id, media.id, media.id, media.duration, media.frame_rate or 30.0)))
    end

    for _, clip in ipairs(layout.clips) do
        assert_true("clip", db:exec(string.format([[INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
          start_time, duration, source_in, source_out, enabled)
          VALUES ('%s','default_project','timeline','', '%s','%s','default_sequence',%d,%d,%d,%d,1);]],
          clip.id, clip.track_id, clip.media_id, clip.start_time, clip.duration, clip.source_in or 0, clip.source_out or (clip.source_in or 0) + clip.duration)))
    end

    return db
end

local function init_timeline_state()
    timeline_state.init("default_sequence")
    timeline_state.reload_clips("default_sequence")
end

local function run_command(cmd)
    local result = command_manager.execute(cmd)
    assert_true(cmd:get_parameter("__label") or "command", result.success)
end

-- Scenario 1: single-track overlap prevention using real timeline_state
do
    local layout = {
        tracks = {{id="v1", index=1}},
        media = {{id="m", duration=10000}},
        clips = {
            {id="clip_one", track_id="v1", media_id="m", start_time=0, duration=2000, source_out=2000},
            {id="clip_two", track_id="v1", media_id="m", start_time=1500, duration=1000, source_in=2000, source_out=3000}
        }
    }
    local db = seed_db(layout)
    command_manager.init(db, "default_sequence", "default_project")
    init_timeline_state()

    local cmd = Command.create("BatchRippleEdit", "default_project")
    cmd:set_parameter("edge_infos", {{clip_id="clip_one", edge_type="out", track_id="v1"}})
    cmd:set_parameter("delta_ms", -800)
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("__label", "single_track_overlap")
    run_command(cmd)

    local one = Clip.load("clip_one", db)
    local two = Clip.load("clip_two", db)
    assert_true("clip_one duration", one.duration == 1500)
    assert_true("clip_two start", two.start_time == 1500)
    assert_no_overlap("single_track_timeline_state", {one, two})
end

-- Scenario 2: linked AV overlap prevention using real timeline_state
do
    local layout = {
        tracks = {{id="v1", index=1}, {id="a1", index=1, track_type="AUDIO", timebase_type="audio_samples", timebase_rate=48000}},
        media = {{id="av", duration=10000, frame_rate=30.0}},
        clips = {
            {id="clip_v1", track_id="v1", media_id="av", start_time=0, duration=2500, source_out=2500},
            {id="clip_v2", track_id="v1", media_id="av", start_time=2200, duration=1000, source_in=3000, source_out=4000},
            {id="clip_a1", track_id="a1", media_id="av", start_time=0, duration=2500, source_out=2500},
            {id="clip_a2", track_id="a1", media_id="av", start_time=2200, duration=1000, source_in=3000, source_out=4000}
        }
    }
    local db = seed_db(layout)
    command_manager.init(db, "default_sequence", "default_project")
    init_timeline_state()

    local cmd = Command.create("BatchRippleEdit", "default_project")
    cmd:set_parameter("edge_infos", {
        {clip_id="clip_v1", edge_type="out", track_id="v1"},
        {clip_id="clip_a1", edge_type="out", track_id="a1"}
    })
    cmd:set_parameter("delta_ms", -800)
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("__label", "linked_av_overlap")
    run_command(cmd)

    local v1 = Clip.load("clip_v1", db)
    local v2 = Clip.load("clip_v2", db)
    local a1 = Clip.load("clip_a1", db)
    local a2 = Clip.load("clip_a2", db)
    assert_true("v1 duration", v1.duration == 1700)
    assert_true("a1 duration", a1.duration == 1700)
    assert_true("v2 start", v2.start_time == 1700)
    assert_true("a2 start", a2.start_time == 1700)
    assert_no_overlap("linked_av_v", {v1, v2})
    assert_no_overlap("linked_av_a", {a1, a2})
end

-- Scenario 3: gap-before drag matching qualitative regression example
do
    local layout = {
        tracks = {{id="track1", index=1}, {id="track2", index=2}},
        media = {{id="m1", duration=10000}},
        clips = {
            {id="gap_clip", track_id="track1", media_id="m1", start_time=2000, duration=4000, source_in=0, source_out=4000},
            {id="t1_clip_b", track_id="track1", media_id="m1", start_time=6250, duration=2000, source_in=4000, source_out=6000},
            {id="t2_clip_a", track_id="track2", media_id="m1", start_time=0, duration=2000, source_out=2000},
            {id="t2_clip_b", track_id="track2", media_id="m1", start_time=2500, duration=4500, source_in=2000, source_out=6500}
        }
    }
    local db = seed_db(layout)
    command_manager.init(db, "default_sequence", "default_project")
    init_timeline_state()

    local cmd = Command.create("BatchRippleEdit", "default_project")
    cmd:set_parameter("edge_infos", {{clip_id="gap_clip", edge_type="gap_before", track_id="track1"}})
    cmd:set_parameter("delta_ms", -1000)
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("__label", "gap_before_overlap")
    run_command(cmd)

    local gap_clip = Clip.load("gap_clip", db)
    local t1b = Clip.load("t1_clip_b", db)
    local t2b = Clip.load("t2_clip_b", db)
    assert_true("gap_clip moved left with clamp", gap_clip.start_time == 1500)
    assert_true("next V1 clip shifted consistently", t1b.start_time == 5750)
    assert_true("t2 clip respects guard", t2b.start_time == 2000)
    assert_no_overlap("gap_before_overlap_tracks", {gap_clip, t2b})
end

-- Scenario 4: RippleEdit gap-before clamp mirrors BatchRipple behavior
do
    local layout = {
        tracks = {{id="track1", index=1}, {id="track2", index=2}},
        media = {{id="m1", duration=10000}},
        clips = {
            {id="gap_clip", track_id="track1", media_id="m1", start_time=2000, duration=4000, source_in=0, source_out=4000},
            {id="t1_clip_b", track_id="track1", media_id="m1", start_time=6250, duration=2000, source_in=4000, source_out=6000},
            {id="t2_clip_a", track_id="track2", media_id="m1", start_time=0, duration=2000, source_out=2000},
            {id="t2_clip_b", track_id="track2", media_id="m1", start_time=2500, duration=4500, source_in=2000, source_out=6500}
        }
    }
    local db = seed_db(layout)
    command_manager.init(db, "default_sequence", "default_project")
    init_timeline_state()

    local cmd = Command.create("RippleEdit", "default_project")
    cmd:set_parameter("edge_info", {clip_id="gap_clip", edge_type="gap_before", track_id="track1"})
    cmd:set_parameter("delta_ms", -1000)
    cmd:set_parameter("sequence_id", "default_sequence")
    cmd:set_parameter("__label", "ripple_gap_before_overlap")
    run_command(cmd)

    local gap_clip = Clip.load("gap_clip", db)
    local t1b = Clip.load("t1_clip_b", db)
    local t2b = Clip.load("t2_clip_b", db)
    assert_true("ripple gap clip clamped", gap_clip.start_time == 1500)
    assert_true("ripple next V1 clip shifted consistently", t1b.start_time == 5750)
    assert_true("ripple t2 clip respects guard", t2b.start_time == 2000)
    assert_no_overlap("ripple_gap_before_overlap_tracks", {gap_clip, t2b})
end

print("✅ BatchRipple timeline_state overlap tests passed")
