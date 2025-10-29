#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_impl = require('core.command_implementations')
local timeline_constraints = require('core.timeline_constraints')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

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
            name TEXT,
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
        CREATE TABLE IF NOT EXISTS commands (
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            parent_sequence_number INTEGER,
            sequence_number INTEGER,
            command_type TEXT NOT NULL,
            command_args TEXT,
            pre_hash TEXT,
            post_hash TEXT,
            timestamp INTEGER,
            playhead_time INTEGER DEFAULT 0,
            selected_clip_ids TEXT DEFAULT '[]',
            selected_edge_infos TEXT DEFAULT '[]',
            selected_clip_ids_pre TEXT DEFAULT '[]',
            selected_edge_infos_pre TEXT DEFAULT '[]'
        );
    ]])

    db:exec([[
        INSERT INTO projects (id, name) VALUES ('project', 'Test Project');
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('sequence', 'project', 'Seq', 30.0, 1920, 1080);
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('selection_sequence', 'project', 'Selection Seq', 30.0, 1920, 1080);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v3', 'sequence', 'V3', 'VIDEO', 3, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v4', 'sequence', 'V4', 'VIDEO', 4, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v5', 'sequence', 'V5', 'VIDEO', 5, 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('selection_track_v1', 'selection_sequence', 'Selection V1', 'VIDEO', 1, 1);
    ]])

    return db
end

local function fetch_clip(db, clip_id)
    local stmt = db:prepare([[
        SELECT track_id, start_time, duration, source_in, source_out
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "query exec failed")
    assert(stmt:next(), "clip not found: " .. tostring(clip_id))
    return {
        track_id = stmt:value(0),
        start_time = stmt:value(1),
        duration = stmt:value(2),
        source_in = stmt:value(3),
        source_out = stmt:value(4)
    }
end

local function fetch_track_clips(db, track_id)
    local stmt = db:prepare([[SELECT start_time, duration, id FROM clips WHERE track_id = ? ORDER BY start_time]])
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "track clip query failed")
    local clips = {}
    while stmt:next() do
        clips[#clips + 1] = {
            start_time = stmt:value(0),
            duration = stmt:value(1),
            id = stmt:value(2)
        }
    end
    return clips
end

local function assert_no_overlaps(clips)
    local prev_end = nil
    for _, clip in ipairs(clips) do
        if prev_end then
            assert(clip.start_time >= prev_end, string.format(
                "expected no overlap, but clip %s starts at %d before previous end %d",
                tostring(clip.id), clip.start_time, prev_end
            ))
        end
        prev_end = clip.start_time + clip.duration
    end
end

local function ensure_media_record(db, media_id, duration)
    local media = Media.create({
        id = media_id,
        project_id = "project",
        file_path = "/tmp/" .. media_id .. ".mov",
        file_name = media_id .. ".mov",
        name = media_id .. ".mov",
        duration = duration,
        frame_rate = 30
    })
    assert(media, "failed creating media " .. tostring(media_id))
    assert(media:save(db), "failed saving media " .. tostring(media_id))
end

print("=== Clip Occlusion Tests ===\n")

local db_path = "/tmp/test_clip_occlusion.db"
local db = setup_db(db_path)

ensure_media_record(db, "media_A", 4000)
ensure_media_record(db, "media_B", 3000)
ensure_media_record(db, "media_C", 4000)
ensure_media_record(db, "media_D", 5000)
ensure_media_record(db, "media_E", 8000)
ensure_media_record(db, "media_F", 2000)

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
assert(clip_c:save(db), "failed saving clip C")

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
assert(clip_d:save(db), "failed saving clip D")

-- Move clip_d earlier so it straddles clip C and its right portion creates overlap
clip_d = Clip.load(clip_d.id, db)
clip_d.start_time = 2000   -- spans [2000, 7000) covering end of A, all of C, start of B
assert(clip_d:save(db), "failed moving clip D with occlusion")

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

print("Test 2b: MoveClipToTrack resolves overlaps on destination track")
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1)]])

local mover_clip = Clip.create("Mover", "media_C")
mover_clip.track_id = "track_v2"
mover_clip.start_time = 2000
mover_clip.duration = 4000
mover_clip.source_in = 0
mover_clip.source_out = 4000
assert(mover_clip:save(db), "failed saving mover clip")

command_executors = new_command_env(db)
local move_cmd = Command.create("MoveClipToTrack", "project")
move_cmd:set_parameter("clip_id", mover_clip.id)
move_cmd:set_parameter("target_track_id", "track_v1")
move_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["MoveClipToTrack"](move_cmd), "MoveClipToTrack should succeed and resolve overlaps")

local trimmed_a_after_move = fetch_clip(db, clip_a.id)
assert(trimmed_a_after_move.duration == 2000,
    string.format("upstream clip should be trimmed to 2000ms after move, got %d", trimmed_a_after_move.duration))

local moved_on_v1 = fetch_clip(db, mover_clip.id)
assert(moved_on_v1, "moved clip should still exist after move")
assert(moved_on_v1.track_id == "track_v1",
    string.format("moved clip should now reside on track_v1, got %s", tostring(moved_on_v1.track_id)))
assert(moved_on_v1.start_time == 2000,
    string.format("moved clip should retain start time 2000ms, got %d", moved_on_v1.start_time))
assert(moved_on_v1.duration == 4000, "moved clip duration should remain unchanged")

print("✅ MoveClipToTrack trims overlaps on destination track")

print("Test 2c: Move + Nudge keeps destination track collision-free")
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_nudge_v1', 'sequence', 'NV1', 'VIDEO', 12, 1);
          INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_nudge_v2', 'sequence', 'NV2', 'VIDEO', 13, 1);]])

local base_left = Clip.create("Base Left", "media_C")
base_left.track_id = "track_nudge_v1"
base_left.start_time = 1000
base_left.duration = 3000
base_left.source_in = 0
base_left.source_out = 3000
assert(base_left:save(db), "failed saving base_left clip")

local base_right = Clip.create("Base Right", "media_C")
base_right.track_id = "track_nudge_v1"
base_right.start_time = 6000
base_right.duration = 3000
base_right.source_in = 3000
base_right.source_out = 6000
assert(base_right:save(db), "failed saving base_right clip")

local mover_for_nudge = Clip.create("Mover Nudge", "media_C")
mover_for_nudge.track_id = "track_nudge_v2"
mover_for_nudge.start_time = 3500
mover_for_nudge.duration = 4000
mover_for_nudge.source_in = 0
mover_for_nudge.source_out = 4000
assert(mover_for_nudge:save(db), "failed saving mover clip for nudge test")

command_executors = new_command_env(db)
local move_cmd = Command.create("MoveClipToTrack", "project")
move_cmd:set_parameter("clip_id", mover_for_nudge.id)
move_cmd:set_parameter("target_track_id", "track_nudge_v1")
move_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["MoveClipToTrack"](move_cmd), "Move command should succeed")

local nudge_cmd = Command.create("Nudge", "project")
nudge_cmd:set_parameter("nudge_amount_ms", -2500)
nudge_cmd:set_parameter("nudge_axis", "time")
nudge_cmd:set_parameter("selected_clip_ids", {mover_for_nudge.id})
nudge_cmd:set_parameter("selected_edges", {})
nudge_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["Nudge"](nudge_cmd), "Nudge command should succeed")

local nudge_track_clips = fetch_track_clips(db, "track_nudge_v1")
assert(#nudge_track_clips >= 2, "nudge track should retain clips")
assert_no_overlaps(nudge_track_clips)

local moved_after_nudge = fetch_clip(db, mover_for_nudge.id)
assert(moved_after_nudge.start_time == 1000,
    string.format("nudge should shift mover to 1000ms, got %d", moved_after_nudge.start_time))

print("✅ Move + Nudge maintains occlusion invariant")

print("Test 3: insert inside long clip splits into two segments")
local clip_e = Clip.create("E", "media_E")
clip_e.track_id = "track_v2"
clip_e.start_time = 0
clip_e.duration = 8000
clip_e.source_in = 0
clip_e.source_out = 8000
assert(clip_e:save(db), "failed saving clip E")

local clip_f = Clip.create("F", "media_F")
clip_f.track_id = "track_v2"
clip_f.start_time = 3000
clip_f.duration = 2000
clip_f.source_in = 0
clip_f.source_out = 2000
assert(clip_f:save(db), "failed saving clip F (split test)")

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

print("✅ Insert splits overlapping clip")

print("Test 6: Gap trim clamps against upstream clip")
local gap_media_up = Media.create({
    id = "media_gap_up",
    project_id = "project",
    file_path = "/tmp/gap_up.mov",
    name = "gap_up.mov",
    duration = 10000,
    frame_rate = 30
})
assert(gap_media_up:save(db), "failed saving gap upstream media")

local gap_media_down = Media.create({
    id = "media_gap_down",
    project_id = "project",
    file_path = "/tmp/gap_down.mov",
    name = "gap_down.mov",
    duration = 8000,
    frame_rate = 30
})
assert(gap_media_down:save(db), "failed saving gap downstream media")

local gap_upstream = Clip.create("Gap Upstream", "media_gap_up")
gap_upstream.track_id = "track_v5"
gap_upstream.start_time = 1000
gap_upstream.duration = 3000
gap_upstream.source_in = 0
gap_upstream.source_out = 3000
assert(gap_upstream:save(db), "failed saving upstream gap clip")

local gap_downstream = Clip.create("Gap Downstream", "media_gap_down")
gap_downstream.track_id = "track_v5"
gap_downstream.start_time = 7000
gap_downstream.duration = 2000
gap_downstream.source_in = 0
gap_downstream.source_out = 2000
assert(gap_downstream:save(db), "failed saving downstream gap clip")

local gap_all_clips = database.load_clips("sequence")
local gap_start = gap_upstream.start_time + gap_upstream.duration
local gap_end = gap_downstream.start_time
local gap_duration = gap_end - gap_start
assert(gap_duration > 1, "gap duration should be greater than 1ms for constraint test")

local materialized_gap = {
    id = "temp_gap_" .. gap_upstream.id,
    track_id = gap_upstream.track_id,
    start_time = gap_start,
    duration = gap_duration,
    source_in = 0,
    source_out = gap_duration,
    is_gap = true
}

local gap_constraints = timeline_constraints.calculate_trim_range(
    materialized_gap,
    "in",
    gap_all_clips,
    false,
    true
)

assert(gap_constraints.min_delta < 0, string.format("expected negative min_delta to allow gap expansion, got %d", gap_constraints.min_delta))
assert(gap_constraints.max_delta == math.huge, string.format("expected max_delta to allow closing past original gap, got %s", tostring(gap_constraints.max_delta)))

print("✅ Gap trim clamps against upstream clip")

local right_row = rows[3]
assert(right_row.start_time == 3000, string.format("right fragment should start at 3000ms, got %d", right_row.start_time))
assert(right_row.duration == 3000, string.format("right fragment duration should be 3000ms, got %d", right_row.duration))

print("✅ Insert splits overlapping clip into left/new/right segments")

print("Test 7: Gap bracket trim delegates to clip when closing")
command_executors = new_command_env(db)
local close_gap_cmd = Command.create("RippleEdit", "project")
close_gap_cmd:set_parameter("edge_info", {clip_id = gap_upstream.id, edge_type = "gap_after", track_id = "track_v5"})
close_gap_cmd:set_parameter("delta_ms", gap_duration + 500)
close_gap_cmd:set_parameter("sequence_id", "sequence")
local original_upstream_duration = gap_upstream.duration
local original_downstream_start = gap_downstream.start_time
assert(command_executors["RippleEdit"](close_gap_cmd), "RippleEdit closing gap via gap_after should succeed")

local upstream_after = fetch_clip(db, gap_upstream.id)
assert(upstream_after.duration == original_upstream_duration,
    string.format("upstream clip duration should remain %d, got %d", original_upstream_duration, upstream_after.duration))

local downstream_stmt = db:prepare("SELECT start_time FROM clips WHERE id = ?")
downstream_stmt:bind_value(1, gap_downstream.id)
assert(downstream_stmt:exec() and downstream_stmt:next(), "downstream clip missing after gap close")
local downstream_start = tonumber(downstream_stmt:value(0))
assert(downstream_start >= gap_upstream.start_time + upstream_after.duration,
    "downstream clip should not overlap upstream clip after gap close")

print("✅ Gap closing via bracket removes gap without touching upstream clip")

print("Test 8: Gap ripple opens downstream space")
local gap_extend_clip = Clip.create("Gap Extend Upstream", "media_gap_up")
gap_extend_clip.track_id = "track_v5"
gap_extend_clip.start_time = 20000
gap_extend_clip.duration = 3000
gap_extend_clip.source_in = 0
gap_extend_clip.source_out = 3000
assert(gap_extend_clip:save(db), "failed saving gap extend clip")

local gap_extend_down = Clip.create("Gap Extend Downstream", "media_gap_down")
gap_extend_down.track_id = "track_v5"
gap_extend_down.start_time = 26000
gap_extend_down.duration = 2000
gap_extend_down.source_in = 0
gap_extend_down.source_out = 2000
assert(gap_extend_down:save(db), "failed saving gap extend downstream clip")

local gap_extend_cmd = Command.create("RippleEdit", "project")
gap_extend_cmd:set_parameter("edge_info", {clip_id = gap_extend_clip.id, edge_type = "gap_after", track_id = "track_v5"})
gap_extend_cmd:set_parameter("delta_ms", -1500)
gap_extend_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["RippleEdit"](gap_extend_cmd), "RippleEdit gap extension should succeed")

local extended_downstream = fetch_clip(db, gap_extend_down.id)
assert(extended_downstream.start_time == 27500,
    string.format("downstream clip should shift right by gap extension (expected 27500, got %d)", extended_downstream.start_time))

print("✅ Gap ripple opens additional space and shifts downstream clips")

print("Test 9: Batch gap ripple handles multiple edges")
local batch_gap_cmd = Command.create("BatchRippleEdit", "project")
batch_gap_cmd:set_parameter("edge_infos", {{clip_id = gap_extend_clip.id, edge_type = "gap_after", track_id = "track_v5"}})
batch_gap_cmd:set_parameter("delta_ms", -1200)
batch_gap_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["BatchRippleEdit"](batch_gap_cmd), "BatchRippleEdit gap extension should succeed")
local batch_downstream = fetch_clip(db, gap_extend_down.id)
assert(batch_downstream.start_time == 28700,
    string.format("downstream clip should shift right by batch gap extension (expected 28700, got %d)", batch_downstream.start_time))

print("✅ Batch gap ripple expands gap and shifts downstream clips")

print("Test 10: Track1 gap ripple matches UI scenario")
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v6', 'sequence', 'V6', 'VIDEO', 6, 1)]])

local gap_track_media = Media.create({id = "media_gap_track", project_id = "project", file_path = "/tmp/gap_track.mov", name = "gap_track.mov", duration = 4543567, frame_rate = 30})
assert(gap_track_media:save(db), "failed to save track gap media")

local track_clip1 = Clip.create("Track Clip 1", "media_gap_track")
track_clip1.track_id = "track_v6"
track_clip1.start_time = 0
track_clip1.duration = 4543567
track_clip1.source_in = 0
track_clip1.source_out = 4543567
assert(track_clip1:save(db), "failed saving track clip1")

local track_clip2 = Clip.create("Track Clip 2", "media_gap_track")
track_clip2.track_id = "track_v6"
track_clip2.start_time = 5614567
track_clip2.duration = 4543567
track_clip2.source_in = 0
track_clip2.source_out = 4543567
assert(track_clip2:save(db), "failed saving track clip2")

local gap_delta = track_clip2.start_time - (track_clip1.start_time + track_clip1.duration)

command_executors = new_command_env(db)
local track_gap_cmd = Command.create("RippleEdit", "project")
track_gap_cmd:set_parameter("edge_info", {clip_id = track_clip1.id, edge_type = "gap_after", track_id = "track_v6"})
track_gap_cmd:set_parameter("delta_ms", -1500)
track_gap_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["RippleEdit"](track_gap_cmd), "RippleEdit gap expansion on track should succeed")

local track_clip2_after = fetch_clip(db, track_clip2.id)
assert(track_clip2_after.start_time == 5614567 + 1500,
    string.format("track gap ripple should shift downstream clip by delta (expected %d, got %d)", 5614567 + 1500, track_clip2_after.start_time))

local track_clip1_after = fetch_clip(db, track_clip1.id)
assert(track_clip1_after.duration == 4543567,
    string.format("track gap ripple should not change upstream clip duration (expected %d, got %d)", 4543567, track_clip1_after.duration))

print("✅ Track1 gap ripple expands gap without altering upstream clip")

local clip1_after_expand = fetch_clip(db, track_clip1.id)
local clip2_after_expand = fetch_clip(db, track_clip2.id)
local current_gap = clip2_after_expand.start_time - (clip1_after_expand.start_time + clip1_after_expand.duration)
assert(current_gap > 0, string.format("expected positive gap after expansion, got %d", current_gap))

print("Test 11: Gap edge drag prefers clip after closure")
local track_close_cmd = Command.create("RippleEdit", "project")
track_close_cmd:set_parameter("edge_info", {clip_id = track_clip1.id, edge_type = "gap_after", track_id = "track_v6"})
track_close_cmd:set_parameter("delta_ms", current_gap)
track_close_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["RippleEdit"](track_close_cmd), "RippleEdit gap-after closure should succeed")

local clip1_post_close = fetch_clip(db, track_clip1.id)
local clip2_post_close = fetch_clip(db, track_clip2.id)
assert(clip2_post_close.start_time == clip1_post_close.start_time + clip1_post_close.duration,
    string.format("gap should be closed (expected %d, got %d)", clip1_post_close.start_time + clip1_post_close.duration, clip2_post_close.start_time))

local trim_amount = 1200
local track_trim_cmd = Command.create("RippleEdit", "project")
track_trim_cmd:set_parameter("edge_info", {clip_id = track_clip1.id, edge_type = "out", track_id = "track_v6"})
track_trim_cmd:set_parameter("delta_ms", -trim_amount)
track_trim_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["RippleEdit"](track_trim_cmd), "RippleEdit clip out trim after gap closure should succeed")

local clip1_after_trim = fetch_clip(db, track_clip1.id)
assert(clip1_after_trim.duration == clip1_post_close.duration - trim_amount,
    string.format("clip out trim should reduce duration (expected %d, got %d)", clip1_post_close.duration - trim_amount, clip1_after_trim.duration))

local clip2_after_trim = fetch_clip(db, track_clip2.id)
assert(clip2_after_trim.start_time == clip2_post_close.start_time - trim_amount,
    string.format("downstream clip should shift left by trim amount (expected %d, got %d)", clip2_post_close.start_time - trim_amount, clip2_after_trim.start_time))

print("✅ Gap edge drag after closure affects clip out appropriately")

print("Test 12: Gap selection normalizes after closure")

local selection_media_left = Media.create({
    id = "media_gap_selection_left",
    project_id = "project",
    file_path = "/tmp/gap_selection_left.mov",
    name = "gap_selection_left.mov",
    duration = 8000,
    frame_rate = 30
})
assert(selection_media_left:save(db), "failed saving selection upstream media")

local selection_media_right = Media.create({
    id = "media_gap_selection_right",
    project_id = "project",
    file_path = "/tmp/gap_selection_right.mov",
    name = "gap_selection_right.mov",
    duration = 6000,
    frame_rate = 30
})
assert(selection_media_right:save(db), "failed saving selection downstream media")

local selection_upstream = Clip.create("Selection Upstream", selection_media_left.id)
selection_upstream.track_id = "selection_track_v1"
selection_upstream.start_time = 0
selection_upstream.duration = 4000
selection_upstream.source_in = 0
selection_upstream.source_out = 4000
assert(selection_upstream:save(db), "failed saving selection upstream clip")

local selection_downstream = Clip.create("Selection Downstream", selection_media_right.id)
selection_downstream.track_id = "selection_track_v1"
selection_downstream.start_time = 7000
selection_downstream.duration = 3500
selection_downstream.source_in = 0
selection_downstream.source_out = 3500
assert(selection_downstream:save(db), "failed saving selection downstream clip")

local selection_gap = selection_downstream.start_time - (selection_upstream.start_time + selection_upstream.duration)
assert(selection_gap > 1, string.format("expected gap larger than 1ms for selection test, got %d", selection_gap))

command_manager.init(db, 'selection_sequence', 'project')
timeline_state.init('selection_sequence')

timeline_state.set_edge_selection({
    {clip_id = selection_upstream.id, edge_type = "gap_after", trim_type = "ripple"}
})

local close_selection_cmd = Command.create("RippleEdit", "project")
close_selection_cmd:set_parameter("edge_info", {clip_id = selection_upstream.id, edge_type = "gap_after", track_id = "selection_track_v1"})
local close_delta = selection_gap - 1  -- Gap closure leaves 1ms due to constraint
close_selection_cmd:set_parameter("delta_ms", close_delta)
close_selection_cmd:set_parameter("sequence_id", "selection_sequence")

local close_result = command_manager.execute(close_selection_cmd)
assert(close_result.success, "RippleEdit via CommandManager should close gap successfully")

local edges_after_close = timeline_state.get_selected_edges()
assert(#edges_after_close == 1, "selection should persist with one edge after closing gap")
local normalized_edge = edges_after_close[1]
assert(normalized_edge.clip_id == selection_downstream.id,
    "expected selection to move to downstream clip in-edge after closing gap_after")
assert(normalized_edge.edge_type == "in",
    string.format("expected gap_after to normalize to downstream 'in', got %s", tostring(normalized_edge.edge_type)))

local upstream_after_close = fetch_clip(db, selection_upstream.id)
local downstream_after_close = fetch_clip(db, selection_downstream.id)
local expected_contact = upstream_after_close.start_time + upstream_after_close.duration
assert(downstream_after_close.start_time == expected_contact or
       downstream_after_close.start_time == expected_contact + 1,
    string.format("downstream clip should align with upstream clip (expected %d or %d, got %d)",
        expected_contact, expected_contact + 1, downstream_after_close.start_time))

local trim_delta = 600
local selection_trim_cmd = Command.create("RippleEdit", "project")
selection_trim_cmd:set_parameter("edge_info", {clip_id = normalized_edge.clip_id, edge_type = normalized_edge.edge_type, track_id = "selection_track_v1"})
selection_trim_cmd:set_parameter("delta_ms", trim_delta)
selection_trim_cmd:set_parameter("sequence_id", "selection_sequence")

local trim_result = command_manager.execute(selection_trim_cmd)
assert(trim_result.success, "trim after normalized selection should execute successfully")

print("✅ Gap selection converts gap handles to clip edge after closure")

print("Test 13: Gap-before selection normalizes to upstream out edge")
timeline_state.set_edge_selection({
    {clip_id = selection_downstream.id, edge_type = "gap_before", trim_type = "ripple"}
})

local gap_before_close = Command.create("RippleEdit", "project")
gap_before_close:set_parameter("edge_info", {clip_id = selection_downstream.id, edge_type = "gap_before", track_id = "selection_track_v1"})
gap_before_close:set_parameter("delta_ms", -trim_delta)
gap_before_close:set_parameter("sequence_id", "selection_sequence")

local gap_before_result = command_manager.execute(gap_before_close)
assert(gap_before_result.success, "gap_before closure via RippleEdit should succeed")

local edges_after_gap_before = timeline_state.get_selected_edges()
assert(#edges_after_gap_before == 1, "gap_before collapse should leave one selected edge")
local normalized_gap_before = edges_after_gap_before[1]
assert(normalized_gap_before.clip_id == selection_upstream.id,
    "expected gap_before collapse to target upstream clip")
assert(normalized_gap_before.edge_type == "out",
    string.format("expected gap_before collapse to normalize to 'out', got %s", tostring(normalized_gap_before.edge_type)))

print("Test 14: Batch ripple closes gaps without leaving overlaps")
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v8', 'sequence', 'V8', 'VIDEO', 8, 1);
          INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v9', 'sequence', 'V9', 'VIDEO', 9, 1)]])

local multi_media = Media.create({
    id = "media_multi_gap",
    project_id = "project",
    file_path = "/tmp/media_multi_gap.mov",
    name = "media_multi_gap.mov",
    duration = 20000,
    frame_rate = 30
})
assert(multi_media:save(db), "failed saving multi-track media for gap test")

local top_left = Clip.create("Top Left", "media_multi_gap")
top_left.track_id = "track_v8"
top_left.start_time = 0
top_left.duration = 4000
top_left.source_in = 0
top_left.source_out = 4000
assert(top_left:save(db), "failed saving top_left clip")

local bottom_left = Clip.create("Bottom Left", "media_multi_gap")
bottom_left.track_id = "track_v9"
bottom_left.start_time = 0
bottom_left.duration = 5000
bottom_left.source_in = 0
bottom_left.source_out = 5000
assert(bottom_left:save(db), "failed saving bottom_left clip")

local top_right = Clip.create("Top Right", "media_multi_gap")
top_right.track_id = "track_v8"
top_right.start_time = 8000
top_right.duration = 3000
top_right.source_in = 4000
top_right.source_out = 7000
assert(top_right:save(db), "failed saving top_right clip")

local bottom_right = Clip.create("Bottom Right", "media_multi_gap")
bottom_right.track_id = "track_v9"
bottom_right.start_time = 9000
bottom_right.duration = 3500
bottom_right.source_in = 6000
bottom_right.source_out = 9500
assert(bottom_right:save(db), "failed saving bottom_right clip")

command_executors = new_command_env(db)
local multi_close_cmd = Command.create("BatchRippleEdit", "project")
multi_close_cmd:set_parameter("edge_infos", {
    {clip_id = top_right.id, edge_type = "gap_before", track_id = "track_v8"},
    {clip_id = bottom_right.id, edge_type = "gap_before", track_id = "track_v9"}
})
multi_close_cmd:set_parameter("delta_ms", -4000)
multi_close_cmd:set_parameter("sequence_id", "sequence")
assert(command_executors["BatchRippleEdit"](multi_close_cmd), "BatchRippleEdit multi-track overlap closure failed")

local top_left_after = fetch_clip(db, top_left.id)
local top_right_after = fetch_clip(db, top_right.id)
local bottom_left_after = fetch_clip(db, bottom_left.id)
local bottom_right_after = fetch_clip(db, bottom_right.id)

local top_left_end = top_left_after.start_time + top_left_after.duration
local bottom_left_end = bottom_left_after.start_time + bottom_left_after.duration

assert(top_right_after.start_time == top_left_end,
    string.format("top track should butt after closure (expected %d, got %d)", top_left_end, top_right_after.start_time))
assert(bottom_right_after.start_time == bottom_left_end,
    string.format("bottom track should butt after closure (expected %d, got %d)", bottom_left_end, bottom_right_after.start_time))

print("✅ Batch ripple trims overlaps when closing gaps across tracks")

print("Test 14b: Batch ripple clamps oversized opposing gap drag")
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v10', 'sequence', 'V10', 'VIDEO', 10, 1)]])
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v11', 'sequence', 'V11', 'VIDEO', 11, 1)]])

local clamp_media = Media.create({
    id = "media_gap_clamp",
    project_id = "project",
    file_path = "/tmp/media_gap_clamp.mov",
    name = "media_gap_clamp.mov",
    duration = 30000,
    frame_rate = 30
})
assert(clamp_media:save(db), "failed saving clamp media")

local clamp_left = Clip.create("Clamp Left", "media_gap_clamp")
clamp_left.track_id = "track_v10"
clamp_left.start_time = 0
clamp_left.duration = 4000
clamp_left.source_in = 0
clamp_left.source_out = 4000
assert(clamp_left:save(db), "failed saving clamp left clip")

local clamp_right = Clip.create("Clamp Right", "media_gap_clamp")
clamp_right.track_id = "track_v10"
clamp_right.start_time = 8000  -- 4000ms gap
clamp_right.duration = 3500
clamp_right.source_in = 4000
clamp_right.source_out = 7500
assert(clamp_right:save(db), "failed saving clamp right clip")

command_executors = new_command_env(db)
local oversized_gap_cmd = Command.create("BatchRippleEdit", "project")
oversized_gap_cmd:set_parameter("edge_infos", {
    {clip_id = clamp_left.id, edge_type = "gap_after", track_id = "track_v10"},
    {clip_id = clamp_right.id, edge_type = "gap_before", track_id = "track_v10"}
})
oversized_gap_cmd:set_parameter("delta_ms", 6000)  -- larger than 4000 gap
oversized_gap_cmd:set_parameter("sequence_id", "sequence")

local original_right_start = clamp_right.start_time
local original_gap = clamp_right.start_time - (clamp_left.start_time + clamp_left.duration)

local oversized_result = command_executors["BatchRippleEdit"](oversized_gap_cmd)
assert(oversized_result, "BatchRippleEdit should succeed even when requested delta exceeds gap")

local clamp_left_after = fetch_clip(db, clamp_left.id)
local clamp_right_after = fetch_clip(db, clamp_right.id)
local clamp_gap = clamp_right_after.start_time - (clamp_left_after.start_time + clamp_left_after.duration)
assert(clamp_gap <= original_gap,
    string.format("gap closure should not exceed original (orig=%d, got %d)", original_gap, clamp_gap))

local actual_shift = original_right_start - clamp_right_after.start_time
assert(actual_shift == original_gap,
    string.format("downstream clip should shift by original gap (%d), got %d", original_gap, actual_shift))

print("✅ Oversized opposing gap drag correctly clamps to gap duration")

print("Test 14c: Mixed clip+gap ripple clamps to available gap")
local mixed_media = Media.create({
    id = "media_gap_mixed",
    project_id = "project",
    file_path = "/tmp/media_gap_mixed.mov",
    name = "media_gap_mixed.mov",
    duration = 20000,
    frame_rate = 30
})
assert(mixed_media:save(db), "failed saving mixed gap media")

local mixed_left = Clip.create("Mixed Left", "media_gap_mixed")
mixed_left.track_id = "track_v11"
mixed_left.start_time = 0
mixed_left.duration = 4000
mixed_left.source_in = 0
mixed_left.source_out = 4000
assert(mixed_left:save(db), "failed saving mixed left clip")

local mixed_right = Clip.create("Mixed Right", "media_gap_mixed")
mixed_right.track_id = "track_v11"
mixed_right.start_time = 8000 -- 4000ms gap
mixed_right.duration = 5000
mixed_right.source_in = 4000
mixed_right.source_out = 9000
assert(mixed_right:save(db), "failed saving mixed right clip")

command_executors = new_command_env(db)
local mixed_cmd = Command.create("BatchRippleEdit", "project")
mixed_cmd:set_parameter("edge_infos", {
    {clip_id = mixed_right.id, edge_type = "in", track_id = "track_v11"},
    {clip_id = mixed_right.id, edge_type = "gap_before", track_id = "track_v11"}
})
mixed_cmd:set_parameter("delta_ms", 6000) -- exceeds 4000 gap
mixed_cmd:set_parameter("sequence_id", "sequence")

local mixed_result = command_executors["BatchRippleEdit"](mixed_cmd)
assert(mixed_result, "BatchRippleEdit mixed clip+gap should succeed when delta exceeds gap")

local mixed_left_after = fetch_clip(db, mixed_left.id)
local mixed_right_after = fetch_clip(db, mixed_right.id)
local mixed_gap = mixed_right_after.start_time - (mixed_left_after.start_time + mixed_left_after.duration)
assert(mixed_gap <= original_gap,
    string.format("mixed clip+gap ripple should not enlarge gap (orig=%d, got %d)", original_gap, mixed_gap))

print("✅ Mixed clip+gap ripple clamps to gap duration")

print("Test 14d: Multiple gap_before collapse clamps to available gaps")
local multi_gap_media = Media.create({
    id = "media_gap_chain",
    project_id = "project",
    file_path = "/tmp/media_gap_chain.mov",
    name = "media_gap_chain.mov",
    duration = 30000,
    frame_rate = 30
})
assert(multi_gap_media:save(db), "failed saving gap chain media")

local chain_left = Clip.create("Chain Left", "media_gap_chain")
chain_left.track_id = "track_v11"
chain_left.start_time = 0
chain_left.duration = 3000
chain_left.source_in = 0
chain_left.source_out = 3000
assert(chain_left:save(db), "failed saving chain left clip")

local chain_mid = Clip.create("Chain Mid", "media_gap_chain")
chain_mid.track_id = "track_v11"
chain_mid.start_time = 8000 -- gap of 5000 after left
chain_mid.duration = 2000
chain_mid.source_in = 3000
chain_mid.source_out = 5000
assert(chain_mid:save(db), "failed saving chain mid clip")

local chain_right = Clip.create("Chain Right", "media_gap_chain")
chain_right.track_id = "track_v11"
chain_right.start_time = 15000 -- gap of 5000 after mid
chain_right.duration = 3000
chain_right.source_in = 5000
chain_right.source_out = 8000
assert(chain_right:save(db), "failed saving chain right clip")

command_executors = new_command_env(db)
local multi_gap_cmd = Command.create("BatchRippleEdit", "project")
multi_gap_cmd:set_parameter("edge_infos", {
    {clip_id = chain_mid.id, edge_type = "gap_before", track_id = "track_v11"},
    {clip_id = chain_right.id, edge_type = "gap_before", track_id = "track_v11"}
})
multi_gap_cmd:set_parameter("delta_ms", -7000) -- exceeds both gaps
multi_gap_cmd:set_parameter("sequence_id", "sequence")

local multi_gap_result = command_executors["BatchRippleEdit"](multi_gap_cmd)
assert(multi_gap_result, "BatchRippleEdit gap_before collapse should succeed with oversized delta")

local chain_left_after = fetch_clip(db, chain_left.id)
local chain_mid_after = fetch_clip(db, chain_mid.id)
local chain_right_after = fetch_clip(db, chain_right.id)

local gap_one = chain_mid_after.start_time - (chain_left_after.start_time + chain_left_after.duration)
local gap_two = chain_right_after.start_time - (chain_mid_after.start_time + chain_mid_after.duration)
assert(gap_one >= 0, string.format("first gap should not invert (got %d)", gap_one))
assert(gap_two >= 0, string.format("second gap should not invert (got %d)", gap_two))

print("✅ Multiple gap_before collapse stays within available gaps")

print("Test 14e: Ripple trim deletes clip when duration under frame")
db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v12', 'sequence', 'V12', 'VIDEO', 12, 1)]])

local delete_media = Media.create({
    id = "media_ripple_delete",
    project_id = "project",
    file_path = "/tmp/media_ripple_delete.mov",
    name = "media_ripple_delete.mov",
    duration = 10000,
    frame_rate = 30
})
assert(delete_media:save(db), "failed saving ripple delete media")

local delete_clip = Clip.create("Delete Clip", "media_ripple_delete")
delete_clip.track_id = "track_v12"
delete_clip.start_time = 5000
delete_clip.duration = 4000
delete_clip.source_in = 0
delete_clip.source_out = 4000
assert(delete_clip:save(db), "failed saving delete test clip")

command_executors = new_command_env(db)
local delete_cmd = Command.create("RippleEdit", "project")
delete_cmd:set_parameter("edge_info", {clip_id = delete_clip.id, edge_type = "out", track_id = "track_v12"})
delete_cmd:set_parameter("delta_ms", -5000) -- larger than clip duration
delete_cmd:set_parameter("sequence_id", "sequence")

local delete_success = command_executors["RippleEdit"](delete_cmd)
assert(delete_success, "RippleEdit should succeed when trimming clip to zero")

local stmt_delete = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
stmt_delete:bind_value(1, delete_clip.id)
assert(stmt_delete:exec() and stmt_delete:next(), "delete check query failed")
assert(stmt_delete:value(0) == 0, "clip should be deleted when ripple duration falls to zero")

print("✅ Ripple trim deletes clip when duration collapses")

print("Test 15: Overwrite reuses clip ID for downstream commands")
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
