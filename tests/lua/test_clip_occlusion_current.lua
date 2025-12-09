#!/usr/bin/env luajit

-- Overlap resolution tests for insert/move/ripple commands using current schema.

package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

_G.qt_json_encode = _G.qt_json_encode or function(_) return "{}" end
_G.qt_create_single_shot_timer = _G.qt_create_single_shot_timer or function(_, cb) cb(); return {} end

local function assert_true(label, value)
    if not value then
        io.stderr:write(label .. "\n")
        os.exit(1)
    end
end

local function assert_eq(label, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format("%s: expected %s, got %s\n", label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local function assert_no_overlaps(clips)
    table.sort(clips, function(a, b) return a.start_value < b.start_value end)
    local prev_end = nil
    for _, c in ipairs(clips) do
        if prev_end and c.start_value < prev_end then
            io.stderr:write(string.format("overlap: %s starts %d before prev_end %d\n", c.id, c.start_value, prev_end))
            os.exit(1)
        end
        prev_end = c.start_value + c.duration
    end
end

local function seed_project(layout)
    local path = os.tmpname() .. ".jvp"
    os.remove(path)
    assert_true("set_path", database.set_path(path))
    local db = database.get_connection()
    _G.db = db

    local schema = [[
    CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, created_at INTEGER, modified_at INTEGER, settings TEXT);
    CREATE TABLE sequences (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'timeline',
      frame_rate REAL NOT NULL,
      audio_rate REAL NOT NULL DEFAULT 48000,
      width INTEGER NOT NULL,
      height INTEGER NOT NULL,
      timecode_start_frame INTEGER NOT NULL DEFAULT 0,
      playhead_value INTEGER NOT NULL DEFAULT 0,
      selected_clip_ids TEXT DEFAULT '[]',
      selected_edge_infos TEXT DEFAULT '[]',
      viewport_start_value INTEGER NOT NULL DEFAULT 0,
      viewport_duration_frames_value INTEGER NOT NULL DEFAULT 10000,
      mark_in_value INTEGER,
      mark_out_value INTEGER,
      current_sequence_number INTEGER
    );
    CREATE TABLE tracks (
      id TEXT PRIMARY KEY,
      sequence_id TEXT NOT NULL,
      name TEXT,
      track_type TEXT NOT NULL,
      timebase_type TEXT NOT NULL DEFAULT 'video_frames',
      timebase_rate REAL NOT NULL DEFAULT 30.0,
      track_index INTEGER NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      locked INTEGER NOT NULL DEFAULT 0,
      muted INTEGER NOT NULL DEFAULT 0,
      soloed INTEGER NOT NULL DEFAULT 0,
      volume REAL NOT NULL DEFAULT 1.0,
      pan REAL NOT NULL DEFAULT 0.0
    );
    CREATE TABLE media (
      id TEXT PRIMARY KEY,
      project_id TEXT,
      name TEXT,
      file_path TEXT,
      file_name TEXT NOT NULL DEFAULT '',
      duration INTEGER,
      frame_rate REAL,
      width INTEGER,
      height INTEGER,
      audio_channels INTEGER,
      codec TEXT,
      created_at INTEGER,
      modified_at INTEGER,
      metadata TEXT
    );
    CREATE TABLE clips (
      id TEXT PRIMARY KEY,
      project_id TEXT,
      clip_kind TEXT NOT NULL DEFAULT 'timeline',
      name TEXT DEFAULT '',
      track_id TEXT,
      media_id TEXT,
      source_sequence_id TEXT,
      parent_clip_id TEXT,
      owner_sequence_id TEXT,
      start_value INTEGER NOT NULL,
      duration INTEGER NOT NULL,
      source_in INTEGER NOT NULL DEFAULT 0,
      source_out INTEGER NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      offline INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL DEFAULT 0,
      modified_at INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_value INTEGER DEFAULT 0,
        playhead_rate REAL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );
    ]]

    for stmt in schema:gmatch("[^;]+;") do
        local s = db:prepare(stmt)
        assert_true("prepare", s ~= nil)
        assert_true("exec", s:exec())
        s:finalize()
    end

    db:exec("INSERT INTO projects (id, name, settings) VALUES ('project','Occlusion','{}')")
    db:exec("INSERT INTO sequences (id, project_id, name, frame_rate, width, height) VALUES ('sequence','project','Seq',30,1920,1080)")

    for _, track in ipairs(layout.tracks) do
        db:exec(string.format(
            "INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('%s','sequence','%s','VIDEO',%d,1)",
            track.id, track.name or track.id, track.index))
    end

    for _, media in ipairs(layout.media) do
        db:exec(string.format(
            "INSERT INTO media (id, project_id, name, file_path, file_name, duration, frame_rate, width, height, audio_channels) VALUES ('%s','project','%s','/tmp/%s.mov','%s',%d,30,1920,1080,2)",
            media.id, media.name or media.id, media.id, media.id, media.duration))
    end

    for _, clip in ipairs(layout.clips) do
        db:exec(string.format(
            "INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, start_value, duration, source_in, source_out, enabled) VALUES ('%s','project','timeline','', '%s','%s','sequence',%d,%d,%d,%d,1)",
            clip.id, clip.track_id, clip.media_id, clip.start_value, clip.duration, clip.source_in or 0, clip.source_out or (clip.source_in or 0) + clip.duration))
    end

    command_manager.init(db)
    return db
end

local function load_track_clips(db, track_id)
    local stmt = db:prepare("SELECT id, start_value, duration FROM clips WHERE track_id = ? ORDER BY start_value")
    stmt:bind_value(1, track_id)
    assert_true("query", stmt:exec())
    local clips = {}
    while stmt:next() do
        clips[#clips + 1] = {
            id = stmt:value(0),
            start_value = stmt:value(1),
            duration = stmt:value(2)
        }
    end
    stmt:finalize()
    return clips
end

-- Test 1: Insert trims overlapping tails on same track
do
    local db = seed_project({
        tracks = {{id="v1", index=1}},
        media = {{id="m", duration=10000}},
        clips = {
            {id="a", track_id="v1", media_id="m", start_value=0, duration=5000, source_out=5000},
            {id="b", track_id="v1", media_id="m", start_value=5000, duration=5000, source_out=10000}
        }
    })

    local cmd = Command.create("InsertClipToTimeline", "project")
    cmd:set_parameter("track_id", "v1")
    cmd:set_parameter("start_value", 2500)
    cmd:set_parameter("clip_id", "c")
    cmd:set_parameter("media_id", "m")
    cmd:set_parameter("duration", 2000)
    cmd:set_parameter("sequence_id", "sequence")
    assert_true("InsertClip executes", command_manager.execute(cmd).success)

    local track_clips = load_track_clips(db, "v1")
    assert_no_overlaps(track_clips)
end

-- Test 2: MoveClipToTrack resolves overlaps on destination track
do
    local db = seed_project({
        tracks = {{id="v1", index=1},{id="v2", index=2}},
        media = {{id="m", duration=20000}},
        clips = {
            {id="mov", track_id="v1", media_id="m", start_value=2000, duration=4000, source_out=4000},
            {id="dst1", track_id="v2", media_id="m", start_value=0, duration=5000, source_out=5000},
            {id="dst2", track_id="v2", media_id="m", start_value=10000, duration=5000, source_out=10000}
        }
    })

    local cmd = Command.create("MoveClipToTrack", "project")
    cmd:set_parameter("clip_id", "mov")
    cmd:set_parameter("target_track_id", "v2")
    cmd:set_parameter("target_start_value", 3000)
    cmd:set_parameter("sequence_id", "sequence")
    assert_true("MoveClipToTrack executes", command_manager.execute(cmd).success)

    local track_clips = load_track_clips(db, "v2")
    assert_no_overlaps(track_clips)
end

-- Test 3: BatchRippleEdit closes a gap without causing overlap across tracks
do
    local db = seed_project({
        tracks = {{id="v1", index=1},{id="v2", index=2}},
        media = {{id="m", duration=60000}},
        clips = {
            {id="v1_left", track_id="v1", media_id="m", start_value=0, duration=5000, source_out=5000},
            {id="v1_right", track_id="v1", media_id="m", start_value=8000, duration=4000, source_out=9000},
            {id="v2_left", track_id="v2", media_id="m", start_value=0, duration=5000, source_out=5000},
            {id="v2_right", track_id="v2", media_id="m", start_value=12000, duration=6000, source_out=6000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", "project")
    cmd:set_parameter("edge_infos", {
        {clip_id="v1_right", edge_type="gap_before", track_id="v1"},
        {clip_id="v2_left", edge_type="out", track_id="v2"}
    })
    cmd:set_parameter("delta_frames", -90) -- 3000ms at 30fps
    cmd:set_parameter("sequence_id", "sequence")
    local result = command_manager.execute(cmd)
    assert_true("BatchRipple gap close", result.success)

    assert_no_overlaps(load_track_clips(db, "v1"))
    assert_no_overlaps(load_track_clips(db, "v2"))
end

print("✅ Clip occlusion/overlap tests passed")
