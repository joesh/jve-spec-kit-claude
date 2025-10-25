#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_impl = require('core.command_implementations')

local function new_command_env(db)
    local executors = {}
    local undoers = {}
    command_impl.register_commands(executors, undoers, db)
    return executors, undoers
end

local function setup_db(path)
    os.remove(path)
    database.init(path)
    local db = database.get_connection()
    rawset(_G, "db", db)

    db:exec([[
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            settings TEXT NOT NULL DEFAULT '{}'
        );

        CREATE TABLE IF NOT EXISTS sequences (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            frame_rate REAL NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            timecode_start INTEGER NOT NULL DEFAULT 0,
            playhead_time INTEGER NOT NULL DEFAULT 0,
            selected_clip_ids TEXT DEFAULT '[]',
            selected_edge_infos TEXT DEFAULT '[]',
            current_sequence_number INTEGER
        );

        CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY,
            sequence_id TEXT NOT NULL,
            track_type TEXT NOT NULL,
            track_index INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS clips (
            id TEXT PRIMARY KEY,
            track_id TEXT NOT NULL,
            media_id TEXT,
            start_time INTEGER NOT NULL,
            duration INTEGER NOT NULL,
            source_in INTEGER NOT NULL DEFAULT 0,
            source_out INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS media (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            file_path TEXT,
            name TEXT,
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
    ]])

    db:exec([[
        INSERT INTO projects (id, name) VALUES ('project', 'Test Project');
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('sequence', 'project', 'Seq', 30.0, 1920, 1080);
        INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
        VALUES ('track_v1', 'sequence', 'VIDEO', 1, 1);
        INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
        VALUES ('track_v2', 'sequence', 'VIDEO', 2, 1);
        INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
        VALUES ('track_v3', 'sequence', 'VIDEO', 3, 1);
        INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
        VALUES ('track_v4', 'sequence', 'VIDEO', 4, 1);
    ]])

    return db
end

local function fetch_clip(db, clip_id)
    local stmt = db:prepare([[
        SELECT start_time, duration, source_in, source_out
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "query exec failed")
    assert(stmt:next(), "clip not found: " .. tostring(clip_id))
    return {
        start_time = stmt:value(0),
        duration = stmt:value(1),
        source_in = stmt:value(2),
        source_out = stmt:value(3)
    }
end

print("=== Clip Occlusion Tests ===\n")

local db_path = "/tmp/test_clip_occlusion.db"
local db = setup_db(db_path)

-- Seed two clips
local clip_a = Clip.create("A", "media_A")
clip_a.track_id = "track_v1"
clip_a.start_time = 0
clip_a.duration = 4000
clip_a.source_in = 0
clip_a.source_out = 4000
assert(clip_a:save(db), "failed saving clip A")

local clip_b = Clip.create("B", "media_B")
clip_b.track_id = "track_v1"
clip_b.start_time = 6000
clip_b.duration = 3000
clip_b.source_in = 0
clip_b.source_out = 3000
assert(clip_b:save(db), "failed saving clip B")

print("Test 1: inserting overlapping clip trims existing tails")
local clip_c = Clip.create("C", "media_C")
clip_c.track_id = "track_v1"
clip_c.start_time = 2500   -- overlaps tail of clip A
clip_c.duration = 2000     -- occupies [2500, 4500)
clip_c.source_in = 0
clip_c.source_out = 2000
assert(clip_c:save(db, {resolve_occlusion = true}), "failed saving clip C")

local state_a = fetch_clip(db, clip_a.id)
assert(state_a.start_time == 0, "clip A start should remain 0")
assert(state_a.duration == 2500, string.format("clip A duration trimmed to 2500, got %d", state_a.duration))

local state_c = fetch_clip(db, clip_c.id)
assert(state_c.start_time == 2500, "clip C start mismatch")

print("✅ Tail trim applied to clip A")

print("Test 2: moving clip over neighbour trims neighbours")
local clip_d = Clip.create("D", "media_D")
clip_d.track_id = "track_v1"
clip_d.start_time = 5000   -- sits between C and B
clip_d.duration = 5000     -- spans into clip B
clip_d.source_in = 0
clip_d.source_out = 5000
assert(clip_d:save(db, {resolve_occlusion = true}), "failed saving clip D")

-- Move clip_d earlier so it straddles clip C and its right portion creates overlap
clip_d = Clip.load(clip_d.id, db)
clip_d.start_time = 2000   -- spans [2000, 7000) covering end of A, all of C, start of B
assert(clip_d:save(db, {resolve_occlusion = {ignore_ids = {[clip_d.id] = true}}}), "failed moving clip D with occlusion")

local stmt = db:prepare("SELECT id FROM clips WHERE track_id = 'track_v1'")
stmt:exec()
local ids = {}
while stmt:next() do
    table.insert(ids, stmt:value(0))
end
assert(#ids == 2, string.format("expected 2 clips remaining (one deleted), got %d", #ids))

local state_d = fetch_clip(db, clip_d.id)
assert(state_d.start_time == 2000, "clip D start should be 2000")
assert(state_d.duration == 5000, "clip D duration should remain 5000")

local stmt_a = db:prepare("SELECT duration FROM clips WHERE id = ?")
stmt_a:bind_value(1, clip_a.id)
stmt_a:exec()
stmt_a:next()
assert(stmt_a:value(0) == 2000, "clip A should be trimmed to 2000ms")

local stmt_b = db:prepare("SELECT COUNT(*) FROM clips WHERE media_id = 'media_B'")
stmt_b:exec(); stmt_b:next()
assert(stmt_b:value(0) == 0, "clip B should be deleted when fully occluded")

print("✅ Occlusions resolved via trim/delete cascade")

print("Test 3: insert inside long clip splits into two segments")
local clip_e = Clip.create("E", "media_E")
clip_e.track_id = "track_v2"
clip_e.start_time = 0
clip_e.duration = 8000
clip_e.source_in = 0
clip_e.source_out = 8000
assert(clip_e:save(db, {resolve_occlusion = true}), "failed saving clip E")

local clip_f = Clip.create("F", "media_F")
clip_f.track_id = "track_v2"
clip_f.start_time = 3000
clip_f.duration = 2000
clip_f.source_in = 0
clip_f.source_out = 2000
assert(clip_f:save(db, {resolve_occlusion = true}), "failed saving clip F (split test)")

stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = 'track_v2'")
stmt:exec(); stmt:next()
clip_count = stmt:value(0)
assert(clip_count == 3, string.format("expected split into three clips on track_v2, got %d", clip_count))

local left_fragment = fetch_clip(db, clip_e.id)
assert(left_fragment.duration == 3000, "left fragment duration should be 3000")

stmt = db:prepare([[
    SELECT id FROM clips
    WHERE track_id = 'track_v2' AND start_time = 5000
]])
stmt:exec(); stmt:next()
local right_id = stmt:value(0)
assert(right_id, "right fragment not found")
local right_fragment = fetch_clip(db, right_id)
assert(right_fragment.duration == 3000, "right fragment duration should be 3000")

print("✅ Straddled clip split into two fragments")

print("Test 4: Ripple clamp respects media duration")
local media_row = Media.create({
    id = "media_ripple",
    project_id = "project",
    file_path = "/tmp/media_ripple.mov",
    file_name = "media_ripple.mov",
    duration = 5000,
    frame_rate = 30.0
})
assert(media_row:save(db), "failed saving media for ripple test")

local loaded_media = Media.load("media_ripple", db)
assert(loaded_media and loaded_media.duration == 5000, "media duration should be 5000ms")

local ripple_clip = Clip.create("Ripple Clip", "media_ripple")
ripple_clip.track_id = "track_v1"
ripple_clip.start_time = 0
ripple_clip.duration = 4000
ripple_clip.source_in = 0
ripple_clip.source_out = 4000
assert(ripple_clip:save(db), "failed saving ripple clip")

local clip_row = db:prepare([[SELECT media_id, source_in, source_out FROM clips WHERE id = ?]])
clip_row:bind_value(1, ripple_clip.id)
assert(clip_row:exec() and clip_row:next(), "failed to fetch ripple clip row")
assert(clip_row:value(0) == "media_ripple", "clip should reference media_ripple")

local command_executors = new_command_env(db)
local ripple_cmd = Command.create("RippleEdit", "project")
ripple_cmd:set_parameter("edge_info", {clip_id = ripple_clip.id, edge_type = "out", track_id = "track_v1"})
ripple_cmd:set_parameter("delta_ms", 1500)
ripple_cmd:set_parameter("sequence_id", "sequence")

local ripple_result = command_executors["RippleEdit"](ripple_cmd)
assert(ripple_result == true, "RippleEdit should succeed with clamped delta")
local ripple_after = fetch_clip(db, ripple_clip.id)
assert(ripple_after.duration == 5000, string.format("ripple duration should clamp to media length (5000), got %d", ripple_after.duration))
assert(ripple_after.source_out == 5000, "source_out should match media duration after clamping")

print("✅ RippleEdit clamps extension to media duration")

print("Test 5: Insert splits overlapping clip")
local base_media = Media.create({id = "media_split_base", project_id = "project", file_path = "/tmp/base.mov", file_name = "base.mov", duration = 6000, frame_rate = 30})
assert(base_media:save(db), "failed to save base media")
local new_media = Media.create({id = "media_split_new", project_id = "project", file_path = "/tmp/new.mov", file_name = "new.mov", duration = 1000, frame_rate = 30})
assert(new_media:save(db), "failed to save new media")

local base_clip = Clip.create("Base Split", "media_split_base")
base_clip.track_id = "track_v3"
base_clip.start_time = 0
base_clip.duration = 6000
base_clip.source_in = 0
base_clip.source_out = 6000
assert(base_clip:save(db), "failed saving base clip for split test")

command_executors = new_command_env(db)
local insert_split = Command.create("Insert", "project")
insert_split:set_parameter("media_id", "media_split_new")
insert_split:set_parameter("track_id", "track_v3")
insert_split:set_parameter("insert_time", 2000)
insert_split:set_parameter("duration", 1000)
insert_split:set_parameter("source_in", 0)
insert_split:set_parameter("source_out", 1000)
insert_split:set_parameter("sequence_id", "sequence")
assert(command_executors["Insert"](insert_split), "Insert command failed")

local stmt_split = db:prepare([[SELECT id, start_time, duration FROM clips WHERE track_id = 'track_v3' ORDER BY start_time]])
assert(stmt_split:exec(), "failed to query split results")

local rows = {}
while stmt_split:next() do
    table.insert(rows, {
        id = stmt_split:value(0),
        start_time = stmt_split:value(1),
        duration = stmt_split:value(2)
    })
end

-- Debug output for inspection (removed in final assertions if needed)
-- for _, row in ipairs(rows) do
--     print("track_v3 clip", row.id, row.start_time, row.duration)
-- end

assert(#rows == 3, string.format("expected 3 clips after insert split, got %d", #rows))
assert(rows[1].id == base_clip.id, "base clip should retain original id")
assert(rows[1].start_time == 0, "left fragment start should remain 0")
assert(rows[1].duration == 2000, string.format("left fragment duration should be 2000ms, got %d", rows[1].duration))

local inserted_row = rows[2]
assert(inserted_row.start_time == 2000, string.format("inserted clip should start at 2000ms, got %d", inserted_row.start_time))
assert(inserted_row.duration == 1000, string.format("inserted clip duration mismatch: %d", inserted_row.duration))

local right_row = rows[3]
assert(right_row.start_time == 3000, string.format("right fragment should start at 3000ms, got %d", right_row.start_time))
assert(right_row.duration == 3000, string.format("right fragment duration should be 3000ms, got %d", right_row.duration))

print("✅ Insert splits overlapping clip into left/new/right segments")

print("Test 6: Overwrite reuses clip ID for downstream commands")
local overwrite_media = Media.create({id = "media_overwrite_src", project_id = "project", file_path = "/tmp/overwrite_src.mov", file_name = "overwrite_src.mov", duration = 4000, frame_rate = 30})
assert(overwrite_media:save(db), "failed to save overwrite source media")
local overwrite_replacement = Media.create({id = "media_overwrite_new", project_id = "project", file_path = "/tmp/overwrite_new.mov", file_name = "overwrite_new.mov", duration = 1500, frame_rate = 30})
assert(overwrite_replacement:save(db), "failed to save overwrite replacement media")

local overwrite_clip = Clip.create("Overwrite Target", "media_overwrite_src")
overwrite_clip.track_id = "track_v4"
overwrite_clip.start_time = 5000
overwrite_clip.duration = 2000
overwrite_clip.source_in = 0
overwrite_clip.source_out = 2000
assert(overwrite_clip:save(db), "failed saving overwrite base clip")

command_executors = new_command_env(db)
local overwrite_cmd = Command.create("Overwrite", "project")
overwrite_cmd:set_parameter("media_id", "media_overwrite_new")
overwrite_cmd:set_parameter("track_id", "track_v4")
overwrite_cmd:set_parameter("overwrite_time", 5000)
overwrite_cmd:set_parameter("duration", 2000)
overwrite_cmd:set_parameter("source_in", 0)
overwrite_cmd:set_parameter("source_out", 2000)
overwrite_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["Overwrite"](overwrite_cmd), "Overwrite command failed")

local stmt_overwrite = db:prepare("SELECT start_time, duration FROM clips WHERE id = ?")
stmt_overwrite:bind_value(1, overwrite_clip.id)
assert(stmt_overwrite:exec() and stmt_overwrite:next(), "overwritten clip not found")
local start_time = tonumber(stmt_overwrite:value(0))
local duration_after = tonumber(stmt_overwrite:value(1))
assert(start_time == 5000, string.format("overwritten clip start should remain 5000, got %s", tostring(start_time)))
assert(duration_after == 2000, string.format("overwritten clip duration should be 2000ms, got %s", tostring(duration_after)))

local move_cmd = Command.create("MoveClipToTrack", "project")
move_cmd:set_parameter("clip_id", overwrite_clip.id)
move_cmd:set_parameter("target_track_id", "track_v2")
assert(command_executors["MoveClipToTrack"](move_cmd), "MoveClipToTrack failed after overwrite")

local stmt_verify = db:prepare("SELECT start_time FROM clips WHERE id = ?")
stmt_verify:bind_value(1, overwrite_clip.id)
assert(stmt_verify:exec() and stmt_verify:next(), "clip missing after move")
local moved_start = tonumber(stmt_verify:value(0))
assert(moved_start == 5000, string.format("moved clip should retain start time, got %s", tostring(moved_start)))

print("✅ Overwrite preserves clip ID for subsequent commands")

print("\nAll occlusion tests passed.")
