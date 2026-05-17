#!/usr/bin/env luajit

-- Test AddClipsToSequence command - THE algorithm for timeline edits
-- Tests: serial/stacked arrangement, insert/overwrite edit types, cross-track carving, linking

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
require('models.track')  -- luacheck: ignore 411 (needed for Clip model dependencies)
local command_manager = require('core.command_manager')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== AddClipsToSequence Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_add_clips_to_sequence.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence (30fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('project', 'Test Project', 'resample', %d, %d);
]], now, now))
-- V13: synthesize placeholder media + master sequence for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _existing = _Media.load("media_1")
    if not _existing then
        local _m = _Media.create({
            id = "media_1",
            project_id = "project",
            file_path = "/tmp/jve/_placeholder.mov",
            name = "Placeholder",
            duration_frames = 10000,
            fps_numerator = 30,
            fps_denominator = 1,
            width = 1920,
            height = 1080,
            audio_channels = 0,
            metadata = _json.encode({ start_tc_value = 0, start_tc_rate = 30 }),
        })
        assert(_m:save())
    end
end
-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_1")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media_1", "project")

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a2', 'sequence', 'A2', 'AUDIO', 2, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media (500 frames @ 30fps)
local test_env = require("test_env")
test_env.create_test_media({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/video1.mov",
    name = "Video 1",
    duration_frames = 500,
    fps_numerator = 30,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 48000,
})

-- Helper: execute command with proper event wrapping
local function execute_command(name, params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

-- Helper: undo/redo with proper event wrapping
local function undo()
    command_manager.begin_command_event("script")
    local result = command_manager.undo()
    command_manager.end_command_event()
    return result
end

local function redo()
    command_manager.begin_command_event("script")
    local result = command_manager.redo()
    command_manager.end_command_event()
    return result
end

-- Helper: count clips on track
local function count_clips(track_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = ?")
    stmt:bind_value(1, track_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Helper: get clip position
local function get_clip_position(clip_id)
    local stmt = db:prepare("SELECT sequence_start_frame, duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    if stmt:next() then
        local start = stmt:value(0)
        local dur = stmt:value(1)
        stmt:finalize()
        return start, dur
    end
    stmt:finalize()
    return nil, nil
end

-- Helper: reset timeline. Direct-DB DELETE bypasses timeline_state's
-- cache; reload after each reset so clip_state.apply_mutations bulk_shift
-- finds the right clips (the test's create_clip below also goes
-- direct-DB; reload_clips is repeated after the setup if pre-existing
-- clips are part of the test's preconditions).
local function reset_timeline()
    db:exec("DELETE FROM clips")
    db:exec("DELETE FROM clip_links")
    local timeline_state = require("ui.timeline.timeline_state")
    if timeline_state.reload_clips then
        timeline_state.reload_clips("sequence")
    end
end

-- Helper: create existing clip
local function create_clip(id, track_id, start_frame, duration_frames)
    local clip = Clip.create({
        name = "Clip " .. id,
        id = id,
        project_id = "project",
        track_id = track_id,
        owner_sequence_id = "sequence",
        sequence_id = MC_TEST,
        sequence_start_frame = start_frame,
        duration_frames = duration_frames,
        source_in_frame = 0,
        source_out_frame = duration_frames,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
    assert(clip ~= nil and clip ~= "", "Failed to save clip " .. id)
    -- Direct Clip.create bypasses timeline_state cache; sync.
    local timeline_state = require("ui.timeline.timeline_state")
    if timeline_state.reload_clips then
        timeline_state.reload_clips("sequence")
    end
    return clip
end

-- =============================================================================
-- TEST 1: Basic insert at empty timeline
-- =============================================================================
print("Test 1: Basic insert at empty timeline")
reset_timeline()

local groups = {
    {
        clips = {
            {
                role = "video",
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "Test Clip",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 100,
    }
}

local result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
    arrangement = "serial",
})
assert(result.success, "AddClipsToSequence should succeed: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 1, "Should have 1 clip on V1")

-- =============================================================================
-- TEST 2: Insert ripples existing clips
-- =============================================================================
print("Test 2: Insert ripples existing clips")
reset_timeline()
create_clip("existing", "track_v1", 0, 100)  -- Clip at [0, 100)

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "Inserted",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,  -- Insert at start
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
assert(result.success, "Insert should succeed: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 2, "Should have 2 clips on V1")

-- Existing clip should be pushed to frame 50
local start, dur = get_clip_position("existing")
assert(start == 50, string.format("Existing clip should be at 50, got %s", tostring(start)))
assert(dur == 100, "Existing clip should still be 100 frames")

-- =============================================================================
-- TEST 3: Overwrite does NOT ripple
-- =============================================================================
print("Test 3: Overwrite does not ripple")
reset_timeline()
create_clip("existing2", "track_v1", 0, 100)

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "Overwritten",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "overwrite",
})
assert(result.success, "Overwrite should succeed")

-- Existing clip should be trimmed, not pushed
start, dur = get_clip_position("existing2")
assert(start == 50, string.format("Existing should start at 50 after trim, got %s", tostring(start)))
assert(dur == 50, string.format("Existing should be 50 frames after trim, got %s", tostring(dur)))

-- =============================================================================
-- TEST 4: Serial arrangement places groups back-to-back
-- =============================================================================
print("Test 4: Serial arrangement")
reset_timeline()

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "Clip A",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 100,
    },
    {
        clips = {
            {
                role = "video",
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "Clip B",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
    arrangement = "serial",
})
assert(result.success, "Serial insert should succeed")
assert(count_clips("track_v1") == 2, "Should have 2 clips on V1")

-- Verify positions: Clip A at 0, Clip B at 100
local stmt = db:prepare("SELECT sequence_start_frame FROM clips WHERE track_id = 'track_v1' ORDER BY sequence_start_frame")
stmt:exec()
local positions = {}
while stmt:next() do
    table.insert(positions, stmt:value(0))
end
stmt:finalize()
assert(positions[1] == 0, string.format("First clip should be at 0, got %s", tostring(positions[1])))
assert(positions[2] == 100, string.format("Second clip should be at 100, got %s", tostring(positions[2])))

-- =============================================================================
-- TEST 5: Video + audio group creates linked clips
-- =============================================================================
print("Test 5: Video + audio creates linked clips")
reset_timeline()

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "AV Clip",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            },
            {
                role = "audio",
                channel = 0,
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "AV Clip (Audio)",
                source_in = 0,
                source_out = 100,
                duration = 100,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_a1",
            }
        },
        duration = 100,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
assert(result.success, "AV insert should succeed")
assert(count_clips("track_v1") == 1, "Should have 1 clip on V1")
assert(count_clips("track_a1") == 1, "Should have 1 clip on A1")

-- Check clips are linked
local link_stmt = db:prepare("SELECT COUNT(*) FROM clip_links")
link_stmt:exec()
link_stmt:next()
local link_count = link_stmt:value(0)
link_stmt:finalize()
assert(link_count == 2, string.format("Should have 2 link entries, got %d", link_count))

-- =============================================================================
-- TEST 6: Undo reverses entire operation
-- =============================================================================
print("Test 6: Undo reverses entire operation")
-- Continuing from test 5
local undo_result = undo()
assert(undo_result.success, "Undo should succeed")
assert(count_clips("track_v1") == 0, "V1 should be empty after undo")
assert(count_clips("track_a1") == 0, "A1 should be empty after undo")

-- Links should be gone
local link_stmt2 = db:prepare("SELECT COUNT(*) FROM clip_links")
link_stmt2:exec()
link_stmt2:next()
link_count = link_stmt2:value(0)
link_stmt2:finalize()
assert(link_count == 0, "Links should be removed after undo")

-- =============================================================================
-- TEST 7: Redo restores clips and links
-- =============================================================================
print("Test 7: Redo restores clips and links")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed")
assert(count_clips("track_v1") == 1, "V1 should have clip after redo")
assert(count_clips("track_a1") == 1, "A1 should have clip after redo")

-- =============================================================================
-- TEST 8: Insert ripples ALL tracks (cross-track)
-- =============================================================================
print("Test 8: Insert ripples ALL tracks (cross-track)")
reset_timeline()
create_clip("v1_clip", "track_v1", 0, 100)
create_clip("v2_clip", "track_v2", 0, 100)
create_clip("a1_clip", "track_a1", 0, 100)

groups = {
    {
        clips = {
            {
                role = "video",
                media_id = "media_1", sequence_id = MC_TEST, fps_mismatch_policy = "resample",
                project_id = "project",
                name = "Inserted",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 30,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        },
        duration = 50,
    }
}

result = execute_command("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "insert",
})
assert(result.success, "Cross-track insert should succeed")

-- ALL existing clips should be rippled to 50
local v1_start, _ = get_clip_position("v1_clip")
assert(v1_start == 50, string.format("V1 clip should be at 50, got %s", tostring(v1_start)))

local v2_start, _ = get_clip_position("v2_clip")
assert(v2_start == 50, string.format("V2 clip should be at 50 (cross-track ripple), got %s", tostring(v2_start)))

local a1_start, _ = get_clip_position("a1_clip")
assert(a1_start == 50, string.format("A1 clip should be at 50 (cross-track ripple), got %s", tostring(a1_start)))

print("\n\226\156\133 AddClipsToSequence command tests passed")
