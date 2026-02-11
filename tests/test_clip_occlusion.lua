#!/usr/bin/env luajit

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"

local test_env = require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local timeline_constraints = require('core.timeline_constraints')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

-- Mock Qt timer for command_manager/state
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

local function setup_db(path)
    os.remove(path)
    database.init(path)
    local db = database.get_connection()
    rawset(_G, "db", db)

    db:exec(require('import_schema'))

    local now = os.time()
    
    local function exec_safe(sql, label)
        local ok, err = db:exec(sql)
        if ok ~= true then
            local msg = err or "unknown"
            if db.errmsg then msg = db:errmsg() end
            print(string.format("FAIL: %s: %s", label, msg))
            os.exit(1)
        end
    end

    exec_safe(string.format([[ 
        INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
    ]], now, now), "Insert Project")

    -- V5 Schema INSERT
    local seq1_sql = string.format("INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at) VALUES ('sequence', 'project', 'Seq', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0, 240, %d, %d);", now, now)
    exec_safe(seq1_sql, "Insert Sequence 1")

    local seq2_sql = string.format("INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at) VALUES ('selection_sequence', 'project', 'Selection Seq', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0, 240, %d, %d);", now, now)
    exec_safe(seq2_sql, "Insert Sequence 2")

    exec_safe([[ 
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
    ]], "Insert Tracks")

    return db
end

local function fetch_clip(db, clip_id)
    local stmt = db:prepare([[ 
        SELECT track_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "query exec failed")
    assert(stmt:next(), "clip not found: " .. tostring(clip_id))
    
    -- Convert frames to MS for test logic compatibility (30fps hardcoded in setup)
    local function to_ms(frames) return math.floor(frames / 30.0 * 1000.0 + 0.5) end
    
    local start_val = to_ms(stmt:value(1) or 0)
    local dur_val = to_ms(stmt:value(2) or 0)
    local src_in = to_ms(stmt:value(3) or 0)
    local src_out = to_ms(stmt:value(4) or 0)
    
    return {
        track_id = stmt:value(0),
        start_value = start_val,
        duration_value = dur_val,
        duration = dur_val,
        source_in_value = src_in,
        source_in = src_in,
        source_out_value = src_out,
        source_out = src_out
    }
end

local function fetch_track_clips(db, track_id)
    local stmt = db:prepare([[SELECT timeline_start_frame, duration_frames, id FROM clips WHERE track_id = ? ORDER BY timeline_start_frame]])
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "track clip query failed")
    
    local function to_ms(frames) return math.floor(frames / 30.0 * 1000.0 + 0.5) end
    
    local clips = {}
    while stmt:next() do
        clips[#clips + 1] = {
            start_value = to_ms(stmt:value(0) or 0),
            duration = to_ms(stmt:value(1) or 0),
            id = stmt:value(2)
        }
    end
    return clips
end

local function assert_no_overlaps(clips)
    local prev_end = nil
    for _, clip in ipairs(clips) do
        if prev_end then
            assert(clip.start_value >= prev_end, string.format(
                "expected no overlap, but clip %s starts at %d before previous end %d",
                tostring(clip.id), clip.start_value, prev_end
            ))
        end
        prev_end = clip.start_value + clip.duration
    end
end

local function ensure_media_record(db, media_id, duration_frames)
    -- V5 Schema Insert
    local stmt = db:prepare([[ 
        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES (?, 'project', ?, ?, ?, 30, 1, 1920, 1080, 0, 'raw', strftime('%s','now'), strftime('%s','now'), '{}')
    ]])
    stmt:bind_value(1, media_id)
    stmt:bind_value(2, media_id .. ".mov")
    stmt:bind_value(3, "/tmp/jve/" .. media_id .. ".mov")
    stmt:bind_value(4, duration_frames)
    assert(stmt:exec(), "media insert failed")
    stmt:finalize()
end

print("=== Clip Occlusion Tests ===\n")

local db_path = "/tmp/jve/test_clip_occlusion.db"
local db = setup_db(db_path)
command_manager.init('sequence', 'project') -- Initialize command manager

ensure_media_record(db, "media_A", 120) -- 4000ms
ensure_media_record(db, "media_B", 90)  -- 3000ms
ensure_media_record(db, "media_C", 120) -- 4000ms
ensure_media_record(db, "media_D", 150) -- 5000ms
ensure_media_record(db, "media_E", 240) -- 8000ms
ensure_media_record(db, "media_F", 60)  -- 2000ms

-- Seed two clips
local clip_a = Clip.create("A", "media_A", {
    id = "A",
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = 0,
    duration = 120, -- 4000ms
    source_in = 0,
    source_out = 120,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(clip_a:save(db), "failed saving clip A")

local clip_b = Clip.create("B", "media_B", {
    id = "B",
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = 180, -- 6000ms
    duration = 90, -- 3000ms
    source_in = 0,
    source_out = 90,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(clip_b:save(db), "failed saving clip B")

print("Test 2b: MoveClipToTrack resolves overlaps on destination track")
db:exec([[INSERT OR IGNORE INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1)]])

local mover_clip = Clip.create("Mover", "media_C", {
    id = "Mover",
    project_id = "project",
    track_id = "track_v2",
    owner_sequence_id = "sequence",
    timeline_start = 60, -- 2000ms
    duration = 120, -- 4000ms
    source_in = 0,
    source_out = 120,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(mover_clip:save(db), "failed saving mover clip")

local move_cmd = Command.create("MoveClipToTrack", "project")
move_cmd:set_parameter("clip_id", mover_clip.id)
move_cmd:set_parameter("target_track_id", "track_v1")
move_cmd:set_parameter("sequence_id", "sequence")
local move_result = command_manager.execute(move_cmd)
assert(move_result.success, "MoveClipToTrack should succeed and resolve overlaps: " .. tostring(move_result.error_message))

local trimmed_a_after_move = fetch_clip(db, clip_a.id)
-- A was 2000ms. Mover overlaps from 2000ms.
assert(math.abs(trimmed_a_after_move.duration - 2000) < 20,
    string.format("upstream clip should be trimmed to 2000ms after move, got %d", trimmed_a_after_move.duration))

local moved_on_v1 = fetch_clip(db, mover_clip.id)
assert(moved_on_v1, "moved clip should still exist after move")
assert(moved_on_v1.track_id == "track_v1",
    string.format("moved clip should now reside on track_v1, got %s", tostring(moved_on_v1.track_id)))
assert(math.abs(moved_on_v1.start_value - 2000) < 20,
    string.format("moved clip should retain start time 2000ms, got %d", moved_on_v1.start_value))
assert(math.abs(moved_on_v1.duration - 4000) < 20, "moved clip duration should remain unchanged")

print("✅ MoveClipToTrack trims overlaps on destination track")

print("Test 2c: Move + Nudge keeps destination track collision-free")
db:exec([[INSERT OR REPLACE INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_nudge_v1', 'sequence', 'NV1', 'VIDEO', 12, 1); 
          INSERT OR REPLACE INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_nudge_v2', 'sequence', 'NV2', 'VIDEO', 13, 1);]])

local base_left = Clip.create("Base Left", "media_C", {
    id = "Base Left",
    project_id = "project",
    track_id = "track_nudge_v1",
    owner_sequence_id = "sequence",
    timeline_start = 30, -- 1000ms
    duration = 90, -- 3000ms
    source_in = 0,
    source_out = 90,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(base_left:save(db), "failed saving base_left clip")

local base_right = Clip.create("Base Right", "media_C", {
    id = "Base Right",
    project_id = "project",
    track_id = "track_nudge_v1",
    owner_sequence_id = "sequence",
    timeline_start = 180, -- 6000ms
    duration = 90, -- 3000ms
    source_in = 90,
    source_out = 180,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(base_right:save(db), "failed saving base_right clip")

local mover_for_nudge = Clip.create("Mover Nudge", "media_C", {
    id = "Mover Nudge",
    project_id = "project",
    track_id = "track_nudge_v2",
    owner_sequence_id = "sequence",
    timeline_start = 105, -- 3500ms
    duration = 120, -- 4000ms
    source_in = 0,
    source_out = 120,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(mover_for_nudge:save(db), "failed saving mover clip for nudge test")

local move_cmd = Command.create("MoveClipToTrack", "project")
move_cmd:set_parameter("clip_id", mover_for_nudge.id)
move_cmd:set_parameter("target_track_id", "track_nudge_v1")
move_cmd:set_parameter("sequence_id", "sequence")
local res = command_manager.execute(move_cmd)
assert(res.success, "Move command should succeed: " .. tostring(res.error_message))

local nudge_cmd = Command.create("Nudge", "project")
-- Nudge amount in frames (30fps, -75 frames = -2500ms)
nudge_cmd:set_parameter("nudge_amount", -75)
nudge_cmd:set_parameter("nudge_axis", "time")
nudge_cmd:set_parameter("selected_clip_ids", {mover_for_nudge.id})
nudge_cmd:set_parameter("selected_edges", {})
nudge_cmd:set_parameter("sequence_id", "sequence")
assert(command_manager.execute(nudge_cmd).success, "Nudge command should succeed")

local nudge_track_clips = fetch_track_clips(db, "track_nudge_v1")
assert(#nudge_track_clips >= 2, "nudge track should retain clips")
assert_no_overlaps(nudge_track_clips)

local moved_after_nudge = fetch_clip(db, mover_for_nudge.id)
assert(math.abs(moved_after_nudge.start_value - 1000) < 20,
    string.format("nudge should shift mover to 1000ms, got %d", moved_after_nudge.start_value))

print("✅ Move + Nudge maintains occlusion invariant")

print("Test 4: Ripple clamp respects media duration")
db:exec([[INSERT OR IGNORE INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
          VALUES ('track_ripple_test', 'sequence', 'VRipple', 'VIDEO', 10, 1)]])

local media_row = Media.create({
    id = "media_ripple",
    project_id = "project",
    file_path = "/tmp/jve/media_ripple.mov",
    file_name = "media_ripple.mov",
    duration_frames = 150, -- 150 frames so delta 45 gets clamped to 30
    fps_numerator = 30,
    fps_denominator = 1,
    created_at = os.time(),
    modified_at = os.time()
})
assert(media_row:save(db), "failed saving media for ripple test")

local ripple_clip = Clip.create("Ripple Clip", "media_ripple", {
    track_id = "track_ripple_test",
    project_id = "project",
    owner_sequence_id = "sequence",
    timeline_start = 0,
    duration = 120,
    source_in = 0,
    source_out = 120,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(ripple_clip:save(db), "failed saving ripple clip")

local ripple_cmd = Command.create("RippleEdit", "project")
ripple_cmd:set_parameter("edge_info", {clip_id = ripple_clip.id, edge_type = "out", track_id = "track_ripple_test"})
ripple_cmd:set_parameter("delta_frames", 45)
ripple_cmd:set_parameter("sequence_id", "sequence")

local ripple_result = command_manager.execute(ripple_cmd)
assert(ripple_result.success, "RippleEdit should succeed with clamped delta")
local ripple_after = fetch_clip(db, ripple_clip.id)
-- Clamped: max extension = 150 - 120 = 30 frames, so new duration = 120 + 30 = 150 frames = 5000ms
assert(ripple_after.duration == 5000, string.format("ripple duration should clamp to media length (5000ms), got %d", ripple_after.duration))

print("✅ RippleEdit clamps extension to media duration")

print("Test 5: Insert splits overlapping clip")
local base_media = Media.create({id = "media_split_base", project_id = "project", file_path = "/tmp/jve/base.mov", file_name = "base.mov", duration = 180, frame_rate = 30, created_at = os.time(), modified_at = os.time()})
assert(base_media:save(db), "failed to save base media")
local new_media = Media.create({id = "media_split_new", project_id = "project", file_path = "/tmp/jve/new.mov", file_name = "new.mov", duration = 30, frame_rate = 30, created_at = os.time(), modified_at = os.time()})
assert(new_media:save(db), "failed to save new media")

-- Create masterclip sequence for the new media (required for Insert)
local split_master_clip_id = test_env.create_test_masterclip_sequence(
    'project', 'Split New Master', 30, 1, 30, 'media_split_new')

local base_clip = Clip.create("Base Split", "media_split_base", {
    track_id = "track_v3",
    project_id = "project",
    owner_sequence_id = "sequence",
    timeline_start = 0,
    duration = 180, -- 6000ms
    source_in = 0,
    source_out = 180,
    fps_numerator = 30,
    fps_denominator = 1,
    enabled = true
})
assert(base_clip:save(db), "failed saving base clip for split test")

local insert_split = Command.create("Insert", "project")
insert_split:set_parameter("master_clip_id", split_master_clip_id)
insert_split:set_parameter("track_id", "track_v3")
insert_split:set_parameter("insert_time", 60) -- 2000ms
insert_split:set_parameter("duration", 30) -- 1000ms
insert_split:set_parameter("source_in", 0)
insert_split:set_parameter("source_out", 30)
insert_split:set_parameter("sequence_id", "sequence")
assert(command_manager.execute(insert_split).success, "Insert command failed")

local stmt_split = db:prepare([[SELECT id, timeline_start_frame, duration_frames FROM clips WHERE track_id = 'track_v3' ORDER BY timeline_start_frame]])
assert(stmt_split:exec(), "failed to query split results")

local rows = {}
local function to_ms(frames) return math.floor(frames / 30.0 * 1000.0 + 0.5) end
while stmt_split:next() do
    table.insert(rows, {
        id = stmt_split:value(0),
        start_value = to_ms(stmt_split:value(1)),
        duration = to_ms(stmt_split:value(2))
    })
end

assert(#rows == 3, string.format("expected 3 clips after insert split, got %d", #rows))
assert(rows[1].id == base_clip.id, "base clip should retain original id")
assert(rows[1].start_value == 0, "left fragment start should remain 0")
assert(rows[1].duration == 2000, string.format("left fragment duration should be 2000ms, got %d", rows[1].duration))

local inserted_row = rows[2]
assert(inserted_row.start_value == 2000, string.format("inserted clip should start at 2000ms, got %d", inserted_row.start_value))
assert(inserted_row.duration == 1000, string.format("inserted clip duration mismatch: %d", inserted_row.duration))

print("✅ Insert splits overlapping clip")

print("\nAll occlusion tests passed.")
