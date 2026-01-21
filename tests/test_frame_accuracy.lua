-- Tests for frame-accurate clip insertion using Rational Time.

-- Adjust package path to find the libraries if running from project root
package.path = package.path .. ";src/lua/?.lua;tests/?.lua;src/?.lua"

local database = require("core.database")
local command_manager = require("core.command_manager")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Media = require("models.media")
local Track = require("models.track")
local Clip = require("models.clip")
local Rational = require("core.rational")
local Command = require("command")

-- Test Runner State
local passed = 0
local failed = 0

local function pass()
    passed = passed + 1
    io.write(".")
end

local function fail(msg)
    failed = failed + 1
    io.write("\nFAIL: " .. msg .. "\n")
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        fail(string.format("%s: Expected '%s', got '%s'", msg, tostring(expected), tostring(actual)))
    else
        pass()
    end
end

local function assert_not_nil(value, msg)
    if value == nil then
        fail(string.format("%s: Expected not nil, got nil", msg))
    else
        pass()
    end
end

local function setup_test_db()
    collectgarbage("collect")
    local db_path = ":memory:" -- Use in-memory database for tests
    local db = database.init(db_path)
    assert_not_nil(db, "Failed to initialize in-memory database")

    local now = os.time()
    assert(db:exec(string.format([[
        INSERT OR IGNORE INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', %d, %d);
    ]], now, now)))
    assert(db:exec(string.format([[
        INSERT OR IGNORE INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height,
            view_start_frame, view_duration_frames, playhead_frame,
            selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number,
            created_at, modified_at
        ) VALUES (
            'default_sequence', 'default_project', 'Default Sequence', 'timeline',
            30, 1, 48000,
            1920, 1080,
            0, 240, 0,
            '[]', '[]', '[]',
            0,
            %d, %d
        );
    ]], now, now)))
    assert(db:exec([[
        INSERT OR IGNORE INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('default_video1', 'default_sequence', 'V1', 'VIDEO', 1);
    ]]))

    return db
end

local function teardown_test_db(db)
    command_manager.shutdown()
    if db then
        db:close()
    end
    collectgarbage("collect")
end

local function run_test(name, func)
    io.write(string.format("Running test: %s\n", name))
    func()
end

-- ============================================================================
-- TEST SUITE FUNCTIONS (moved into main for consistent execution)
-- ============================================================================

local function test_create_clip_command_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")
    
    local project = Project.create("Test Project")
    project:save(db)
    assert_not_nil(project.id, "Project ID should not be nil")

    local sequence = Sequence.create("Test Sequence", project.id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
    sequence:save(db)
    assert_not_nil(sequence.id, "Sequence ID should not be nil")
    
    local track = Track.create_video("Video Track 1", sequence.id, {index = 1})
    track:save(db)
    assert_not_nil(track.id, "Track ID should not be nil")

    local media_duration_rational = Rational.new(240, 24, 1) -- 10 seconds at 24 FPS
    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/media.mov",
        name = "Test Media",
        duration = media_duration_rational,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)
    assert_not_nil(media.id, "Media ID should not be nil")

    -- Simulate a CreateClip command
    local command_data = {
        id = "cmd_create_clip_1",
        type = "CreateClip",
        parameters = {
            project_id = project.id,
            sequence_id = sequence.id,
            track_id = track.id,
            media_id = media.id,
            timeline_start_frame = 0,
            duration_frames = 120, -- 5 seconds at 24 FPS
            source_in_frame = 24, -- 1 second into source
            source_out_frame = 144, -- 6 seconds into source
        }
    }
    
    local success_obj = command_manager.execute(command_data)
    if not success_obj.success then
        print("Command execution failed with error: " .. success_obj.error_message)
    end
    assert_eq(success_obj.success, true, "CreateClip command execution should succeed")
    assert_not_nil(command_data.parameters.clip_id, "Clip ID should be set by command")
    -- Ensure clip_id is accessible if it was set on the command object
    local clip_id_from_command = success_obj.result_data.parameters and success_obj.result_data.parameters.clip_id
    if not clip_id_from_command then
        local deserialized_command = require('command').deserialize(success_obj.result_data)
        clip_id_from_command = deserialized_command.parameters.clip_id
    end
    assert_not_nil(clip_id_from_command, "Clip ID should be available in result data")

    local created_clip = Clip.load(clip_id_from_command, db)
    assert_not_nil(created_clip, "Created clip should be loadable from DB")
    
    assert_eq(created_clip.timeline_start.frames, 0, "Created clip timeline_start_frame")
    assert_eq(created_clip.duration.frames, 120, "Created clip duration_frames")
    assert_eq(created_clip.source_in.frames, 24, "Created clip source_in_frame")
    assert_eq(created_clip.source_out.frames, 144, "Created clip source_out_frame")
    assert_eq(created_clip.rate.fps_numerator, 24, "Created clip fps_numerator")
    assert_eq(created_clip.rate.fps_denominator, 1, "Created clip fps_denominator")
    assert_eq(created_clip.project_id, project.id, "Created clip project_id")
    assert_eq(created_clip.track_id, track.id, "Created clip track_id")
    assert_eq(created_clip.media_id, media.id, "Created clip media_id")

    teardown_test_db(db)
end

local function test_insert_clip_to_timeline_command_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")
    
    local project = Project.create("Test Project 2")
    project:save(db)

    local sequence = Sequence.create("Test Sequence 2", project.id, {fps_numerator = 30, fps_denominator = 1}, 1920, 1080)
    sequence:save(db)
    
    local track = Track.create_video("Video Track 2", sequence.id, {index = 1})
    track:save(db)

    local media_duration_rational = Rational.new(300, 30, 1) -- 10 seconds at 30 FPS
    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/media2.mov",
        name = "Test Media 2",
        duration = media_duration_rational,
        fps_numerator = 30,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)

    -- Simulate an InsertClipToTimeline command (no master clip)
    local command_data = {
        id = "cmd_insert_clip_1",
        type = "InsertClipToTimeline",
        parameters = {
            project_id = project.id,
            sequence_id = sequence.id,
            track_id = track.id,
            media_id = media.id,
            timeline_start_frame = 60, -- Insert at 2 seconds (30 FPS)
            -- No explicit duration_frames, should use media's duration (rescaled if necessary)
            -- No explicit source_in/out, should use media's full duration
        }
    }
    
    local success_obj = command_manager.execute(command_data)
    assert_eq(success_obj.success, true, "InsertClipToTimeline command execution should succeed")
    
    local deserialized_command = Command.deserialize(success_obj.result_data)
    local clip_id_from_command = deserialized_command.parameters.clip_id
    assert_not_nil(clip_id_from_command, "Clip ID should be set by command")

    local inserted_clip = Clip.load(clip_id_from_command, db)
    assert_not_nil(inserted_clip, "Inserted clip should be loadable from DB")
    
    assert_eq(inserted_clip.timeline_start.frames, 60, "Inserted clip timeline_start_frame")
    assert_eq(inserted_clip.duration.frames, 300, "Inserted clip duration_frames (from media)")
    assert_eq(inserted_clip.source_in.frames, 0, "Inserted clip source_in_frame (from media)")
    assert_eq(inserted_clip.source_out.frames, 300, "Inserted clip source_out_frame (from media)")
    assert_eq(inserted_clip.rate.fps_numerator, 30, "Inserted clip fps_numerator")
    assert_eq(inserted_clip.rate.fps_denominator, 1, "Inserted clip fps_denominator")
    
    teardown_test_db(db)
end

local function test_insert_clip_with_master_clip_rescale_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")
    
    local project = Project.create("Test Project 3")
    project:save(db)

    -- Sequence at 24 FPS
    local sequence = Sequence.create("Test Sequence 3", project.id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
    sequence:save(db)
    
    local track = Track.create_video("Video Track 3", sequence.id, {index = 1})
    track:save(db)

    -- Media at 30 FPS, 10 seconds
    local media_duration_rational = Rational.new(300, 30, 1) -- 10 seconds at 30 FPS
    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/media3.mov",
        name = "Test Media 3",
        duration = media_duration_rational,
        fps_numerator = 30,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)

    -- Create a master clip at 30 FPS, 5 seconds from media
    local master_clip_duration_rational = Rational.new(150, 30, 1) -- 5 seconds at 30 FPS
    local master_clip_source_in_rational = Rational.new(30, 30, 1) -- 1 second in
    local master_clip_source_out_rational = Rational.new(180, 30, 1) -- 6 seconds in
    local master_clip_obj = Clip.create("Master Clip 1", media.id, {
        project_id = project.id,
        clip_kind = "master",
        timeline_start = Rational.new(0, 30, 1), -- Doesn't matter for master clip
        duration = master_clip_duration_rational,
        source_in = master_clip_source_in_rational,
        source_out = master_clip_source_out_rational,
        fps_numerator = 30, -- Master clip maintains its native rate
        fps_denominator = 1,
    })
    master_clip_obj:save(db)
    assert_not_nil(master_clip_obj.id, "Master Clip ID should not be nil")


    -- Simulate an InsertClipToTimeline command using the master clip
    -- Master clip's 5-second duration (150f @ 30fps) should be 120f @ 24fps
    local command_data = {
        id = "cmd_insert_clip_2",
        type = "InsertClipToTimeline",
        parameters = {
            project_id = project.id,
            sequence_id = sequence.id,
            track_id = track.id,
            media_id = media.id, -- Still provide media_id
            master_clip_id = master_clip_obj.id,
            timeline_start_frame = 48, -- Insert at 2 seconds (24 FPS)
        }
    }
    
    local success_obj = command_manager.execute(command_data)
    assert_eq(success_obj.success, true, "InsertClipToTimeline command with master clip should succeed")
    
    local deserialized_command = Command.deserialize(success_obj.result_data)
    local clip_id_from_command = deserialized_command.parameters.clip_id
    assert_not_nil(clip_id_from_command, "Clip ID should be set by command")

    local inserted_clip = Clip.load(clip_id_from_command, db)
    assert_not_nil(inserted_clip, "Inserted clip from master should be loadable from DB")
    
    assert_eq(inserted_clip.timeline_start.frames, 48, "Inserted clip timeline_start_frame (rescaled from command param)")
    
    -- Master clip 150f@30fps = 5s. 5s@24fps = 120 frames.
    assert_eq(inserted_clip.duration.frames, 120, "Inserted clip duration_frames (rescaled from master clip)")
    -- Master clip source_in 30f@30fps = 1s. 1s@24fps = 24 frames.
    assert_eq(inserted_clip.source_in.frames, 24, "Inserted clip source_in_frame (rescaled from master clip)")
    -- Master clip source_out 180f@30fps = 6s. 6s@24fps = 144 frames.
    assert_eq(inserted_clip.source_out.frames, 144, "Inserted clip source_out_frame (rescaled from master clip)")

    assert_eq(inserted_clip.rate.fps_numerator, 24, "Inserted clip fps_numerator (should match sequence)")
    assert_eq(inserted_clip.rate.fps_denominator, 1, "Inserted clip fps_denominator (should match sequence)")
    
    teardown_test_db(db)
end

local function test_split_clip_command_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")

    local project = Project.create("Test Project Split")
    project:save(db)
    assert_not_nil(project.id, "Project ID should not be nil")

    local sequence_fps_num = 24
    local sequence_fps_den = 1
    local sequence = Sequence.create("Test Sequence Split", project.id, {fps_numerator = sequence_fps_num, fps_denominator = sequence_fps_den}, 1920, 1080)
    sequence:save(db)
    assert_not_nil(sequence.id, "Sequence ID should not be nil")
    
    local track = Track.create_video("Video Track Split", sequence.id, {index = 1})
    track:save(db)
    assert_not_nil(track.id, "Track ID should not be nil")

    -- Media: 10 seconds at 24 FPS
    local media_duration_rational = Rational.new(240, 24, 1)
    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/split_media.mov",
        name = "Split Media",
        duration = media_duration_rational,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)
    assert_not_nil(media.id, "Media ID should not be nil")

    -- Insert an initial clip: 10 seconds (240 frames) from media start
    local initial_clip_duration_frames = 240
    local insert_command_data = {
        id = "cmd_initial_insert",
        type = "InsertClipToTimeline",
        parameters = {
            project_id = project.id,
            sequence_id = sequence.id,
            track_id = track.id,
            media_id = media.id,
            timeline_start_frame = 0,
            duration_frames = initial_clip_duration_frames,
            source_in_frame = 0,
            source_out_frame = initial_clip_duration_frames,
        }
    }
    local insert_success_obj = command_manager.execute(insert_command_data)
    if not insert_success_obj.success then
        print("Initial insert failed with error: " .. insert_success_obj.error_message)
    end
    assert_eq(insert_success_obj.success, true, "Initial InsertClipToTimeline command should succeed")
    local initial_clip_deserialized_command = Command.deserialize(insert_success_obj.result_data)
    local initial_clip_id = initial_clip_deserialized_command.parameters.clip_id
    assert_not_nil(initial_clip_id, "Initial Clip ID should be set by command")

    local initial_clip_obj = Clip.load(initial_clip_id, db)
    assert_not_nil(initial_clip_obj, "Initial clip should be loadable from DB")

    -- Define split point: 5 seconds (120 frames) into the clip
    local split_frame = 120
    local split_rational = Rational.new(split_frame, sequence_fps_num, sequence_fps_den)

    -- Simulate SplitClip command
    local split_command_data = {
        id = "cmd_split_clip",
        type = "SplitClip",
        parameters = {
            clip_id = initial_clip_id,
            project_id = project.id,
            split_value = split_rational,
            sequence_id = sequence.id, -- Passed for mutation bucket
        }
    }

    local split_success_obj = command_manager.execute(split_command_data)
    if not split_success_obj.success then
        print("SplitClip failed with error: " .. split_success_obj.error_message)
    end
    assert_eq(split_success_obj.success, true, "SplitClip command should succeed")

    local split_deserialized_command = Command.deserialize(split_success_obj.result_data)
    local second_clip_id = split_deserialized_command.parameters.second_clip_id
    assert_not_nil(second_clip_id, "Second Clip ID should be set by split command")

    -- Verify original clip (first part)
    local first_part_clip = Clip.load(initial_clip_id, db)
    assert_not_nil(first_part_clip, "First part clip should be loadable")
    assert_eq(first_part_clip.duration.frames, split_frame, "First part duration should be split_frame")
    assert_eq(first_part_clip.source_out.frames, split_frame, "First part source_out should be split_frame")
    assert_eq(first_part_clip.timeline_start.frames, 0, "First part timeline_start should be 0")
    assert_eq(first_part_clip.rate.fps_numerator, sequence_fps_num, "First part fps_numerator")

    -- Verify new clip (second part)
    local second_part_clip = Clip.load(second_clip_id, db)
    assert_not_nil(second_part_clip, "Second part clip should be loadable")
    assert_eq(second_part_clip.timeline_start.frames, split_frame, "Second part timeline_start should be split_frame")
    assert_eq(second_part_clip.duration.frames, initial_clip_duration_frames - split_frame, "Second part duration")
    assert_eq(second_part_clip.source_in.frames, split_frame, "Second part source_in should be split_frame")
    assert_eq(second_part_clip.source_out.frames, initial_clip_duration_frames, "Second part source_out")
    assert_eq(second_part_clip.rate.fps_numerator, sequence_fps_num, "Second part fps_numerator")

    -- Test UndoSplitClip
    local split_cmd_obj = Command.deserialize(split_success_obj.result_data)
    local undo_success_obj = command_manager.execute(split_cmd_obj:create_undo())
    if not undo_success_obj.success then
        print("UndoSplitClip failed with error: " .. undo_success_obj.error_message)
    end
    assert_eq(undo_success_obj.success, true, "UndoSplitClip command should succeed")

    -- Verify original clip is restored
    local restored_clip = Clip.load(initial_clip_id, db)
    assert_not_nil(restored_clip, "Original clip should be loadable after undo")
    assert_eq(restored_clip.duration.frames, initial_clip_duration_frames, "Original clip duration restored")
    assert_eq(restored_clip.source_in.frames, 0, "Original clip source_in restored")
    assert_eq(restored_clip.source_out.frames, initial_clip_duration_frames, "Original clip source_out restored")

    -- Verify second clip is deleted
    local deleted_clip = Clip.load_optional(second_clip_id, db)
    assert_eq(deleted_clip, nil, "Second clip should be deleted after undo")

    teardown_test_db(db)
end

local function test_ripple_delete_command_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")

    local project = Project.create("Test Project Ripple")
    project:save(db)
    
    local sequence = Sequence.create("Test Sequence Ripple", project.id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
    sequence:save(db)
    
    local track = Track.create_video("Video Track Ripple", sequence.id, {index = 1})
    track:save(db)

    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/ripple_media.mov",
        name = "Ripple Media",
        duration = Rational.new(2400, 24, 1), -- 100s
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)

    -- Clip 1: [0, 24) frames (1s)
    local clip1 = Clip.create("Clip 1", media.id, {
        project_id = project.id,
        track_id = track.id,
        owner_sequence_id = sequence.id,
        timeline_start = Rational.new(0, 24, 1),
        duration = Rational.new(24, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(24, 24, 1),
        fps_numerator = 24, fps_denominator = 1
    })
    clip1:save(db)

    -- Gap: [24, 48) frames (1s)

    -- Clip 2: [48, 72) frames (1s)
    local clip2 = Clip.create("Clip 2", media.id, {
        project_id = project.id,
        track_id = track.id,
        owner_sequence_id = sequence.id,
        timeline_start = Rational.new(48, 24, 1),
        duration = Rational.new(24, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(24, 24, 1),
        fps_numerator = 24, fps_denominator = 1
    })
    clip2:save(db)

    -- Ripple delete the gap: start=24, duration=24
    local gap_start = Rational.new(24, 24, 1)
    local gap_duration = Rational.new(24, 24, 1)

    local command_data = {
        id = "cmd_ripple_delete",
        type = "RippleDelete",
        parameters = {
            project_id = project.id,
            track_id = track.id,
            sequence_id = sequence.id,
            gap_start = gap_start,
            gap_duration = gap_duration
        }
    }

    local success_obj = command_manager.execute(command_data)
    if not success_obj.success then
        print("RippleDelete failed: " .. success_obj.error_message)
    end
    assert_eq(success_obj.success, true, "RippleDelete should succeed")

    -- Verify Clip 2 moved to frame 24
    local clip2_moved = Clip.load(clip2.id, db)
    assert_eq(clip2_moved.timeline_start.frames, 24, "Clip 2 should move to frame 24")

    -- Undo
    local undo_cmd = Command.deserialize(success_obj.result_data):create_undo()
    local undo_success = command_manager.execute(undo_cmd)
    assert_eq(undo_success.success, true, "Undo RippleDelete should succeed")

    -- Verify Clip 2 restored to frame 48
    local clip2_restored = Clip.load(clip2.id, db)
    assert_eq(clip2_restored.timeline_start.frames, 48, "Clip 2 should restore to frame 48")

    teardown_test_db(db)
end

local function test_ripple_edit_command_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")

    local project = Project.create("Test Project RippleEdit")
    project:save(db)
    
    local sequence = Sequence.create("Test Sequence RippleEdit", project.id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
    sequence:save(db)
    
    local track = Track.create_video("Video Track RippleEdit", sequence.id, {index = 1})
    track:save(db)

    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/ripple_edit_media.mov",
        name = "RippleEdit Media",
        duration = Rational.new(2400, 24, 1), -- 100s
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)

    -- Clip 1: [0, 48) frames (2s). Media In: 0, Out: 48
    local clip1 = Clip.create("Clip 1", media.id, {
        project_id = project.id,
        track_id = track.id,
        owner_sequence_id = sequence.id,
        timeline_start = Rational.new(0, 24, 1),
        duration = Rational.new(48, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(48, 24, 1),
        fps_numerator = 24, fps_denominator = 1
    })
    clip1:save(db)

    -- Clip 2: [48, 96) frames (2s). Media In: 0, Out: 48
    local clip2 = Clip.create("Clip 2", media.id, {
        project_id = project.id,
        track_id = track.id,
        owner_sequence_id = sequence.id,
        timeline_start = Rational.new(48, 24, 1),
        duration = Rational.new(48, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(48, 24, 1),
        fps_numerator = 24, fps_denominator = 1
    })
    clip2:save(db)

    -- Ripple Edit: Trim Clip 1 OUT point by +24 frames (extend right)
    -- This should push Clip 2 to start at 72.
    local delta_frames = 24
    local command_data = {
        id = "cmd_ripple_edit",
        type = "RippleEdit",
        parameters = {
            project_id = project.id,
            edge_info = {
                clip_id = clip1.id,
                edge_type = "out",
                track_id = track.id,
                trim_type = "ripple",
                type = "standard"
            },
            delta_frames = delta_frames
        }
    }

    local success_obj = command_manager.execute(command_data)
    if not success_obj.success then
        print("RippleEdit failed: " .. success_obj.error_message)
    end
    assert_eq(success_obj.success, true, "RippleEdit should succeed")

    -- Verify Clip 1 extended
    local clip1_new = Clip.load(clip1.id, db)
    assert_eq(clip1_new.duration.frames, 72, "Clip 1 duration should increase by 24")
    assert_eq(clip1_new.source_out.frames, 72, "Clip 1 source_out should increase by 24")

    -- Verify Clip 2 moved
    local clip2_new = Clip.load(clip2.id, db)
    assert_eq(clip2_new.timeline_start.frames, 72, "Clip 2 start should shift by 24")

    -- Undo
    local undo_cmd = Command.deserialize(success_obj.result_data):create_undo()
    local undo_success = command_manager.execute(undo_cmd)
    assert_eq(undo_success.success, true, "Undo RippleEdit should succeed")

    -- Verify restored state
    local clip1_restored = Clip.load(clip1.id, db)
    assert_eq(clip1_restored.duration.frames, 48, "Clip 1 duration restored")
    
    local clip2_restored = Clip.load(clip2.id, db)
    assert_eq(clip2_restored.timeline_start.frames, 48, "Clip 2 start restored")

    teardown_test_db(db)
end

local function test_nudge_command_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")

    local project = Project.create("Test Project Nudge")
    project:save(db)
    
    local sequence = Sequence.create("Test Sequence Nudge", project.id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
    sequence:save(db)
    
    local track = Track.create_video("Video Track Nudge", sequence.id, {index = 1})
    track:save(db)

    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/nudge_media.mov",
        name = "Nudge Media",
        duration = Rational.new(2400, 24, 1), -- 100s
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)

    -- Clip 1: [0, 48) frames (2s)
    local clip1 = Clip.create("Clip 1", media.id, {
        project_id = project.id,
        track_id = track.id,
        owner_sequence_id = sequence.id,
        timeline_start = Rational.new(0, 24, 1),
        duration = Rational.new(48, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(48, 24, 1),
        fps_numerator = 24, fps_denominator = 1
    })
    clip1:save(db)

    -- Nudge clip by +24 frames
    local nudge_amount = Rational.new(24, 24, 1)
    local command_data = {
        id = "cmd_nudge_clip",
        type = "Nudge",
        parameters = {
            project_id = project.id,
            selected_clip_ids = {clip1.id},
            nudge_amount_rat = nudge_amount,
            sequence_id = sequence.id
        }
    }

    local success_obj = command_manager.execute(command_data)
    if not success_obj.success then
        print("Nudge failed: " .. success_obj.error_message)
    end
    assert_eq(success_obj.success, true, "Nudge command should succeed")

    local clip1_nudged = Clip.load(clip1.id, db)
    assert_eq(clip1_nudged.timeline_start.frames, 24, "Clip 1 timeline_start should be 24")

    -- Undo
    local undo_cmd = Command.deserialize(success_obj.result_data):create_undo()
    local undo_success = command_manager.execute(undo_cmd)
    assert_eq(undo_success.success, true, "Undo Nudge command should succeed")

    local clip1_restored = Clip.load(clip1.id, db)
    assert_eq(clip1_restored.timeline_start.frames, 0, "Clip 1 timeline_start restored to 0")

    -- Nudge clip edge 'out' by +24 frames
    local nudge_edge_amount = Rational.new(24, 24, 1)
    local edge_command_data = {
        id = "cmd_nudge_edge",
        type = "Nudge",
        parameters = {
            project_id = project.id,
            selected_edges = {{clip_id = clip1.id,
                edge_type = "out",
                track_id = track.id
            }},
            nudge_amount_rat = nudge_edge_amount,
            sequence_id = sequence.id
        }
    }

    local edge_success_obj = command_manager.execute(edge_command_data)
    assert_eq(edge_success_obj.success, true, "Nudge edge command should succeed")
    
    local clip1_edge_nudged = Clip.load(clip1.id, db)
    assert_eq(clip1_edge_nudged.duration.frames, 72, "Clip 1 duration should be 72 after edge nudge")
    assert_eq(clip1_edge_nudged.source_out.frames, 72, "Clip 1 source_out should be 72 after edge nudge")

    -- Undo Edge Nudge
    local undo_edge_cmd = Command.deserialize(edge_success_obj.result_data):create_undo()
    local undo_edge_success = command_manager.execute(undo_edge_cmd)
    assert_eq(undo_edge_success.success, true, "Undo Nudge edge command should succeed")
    
    local clip1_edge_restored = Clip.load(clip1.id, db)
    assert_eq(clip1_edge_restored.duration.frames, 48, "Clip 1 duration restored after edge nudge")

    teardown_test_db(db)
end

local function test_move_clip_to_track_command_func()
    local db = setup_test_db()
    command_manager.init("default_sequence", "default_project")

    local project = Project.create("Test Project MoveClip")
    project:save(db)
    
    local sequence = Sequence.create("Test Sequence MoveClip", project.id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
    sequence:save(db)
    
    local track1 = Track.create_video("Video Track 1", sequence.id, {index = 1})
    track1:save(db)
    local track2 = Track.create_video("Video Track 2", sequence.id, {index = 2})
    track2:save(db)

    local media = Media.create({
        project_id = project.id,
        file_path = "/path/to/move_media.mov",
        name = "Move Media",
        duration = Rational.new(2400, 24, 1), -- 100s
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    })
    media:save(db)

    -- Clip on track1: [0, 48) frames (2s)
    local clip = Clip.create("Clip to Move", media.id, {
        project_id = project.id,
        track_id = track1.id,
        owner_sequence_id = sequence.id,
        timeline_start = Rational.new(0, 24, 1),
        duration = Rational.new(48, 24, 1),
        source_in = Rational.new(0, 24, 1),
        source_out = Rational.new(48, 24, 1),
        fps_numerator = 24, fps_denominator = 1
    })
    clip:save(db)

    -- Move clip to track2
    local command_data = {
        id = "cmd_move_clip",
        type = "MoveClipToTrack",
        parameters = {
            project_id = project.id,
            clip_id = clip.id,
            target_track_id = track2.id,
            sequence_id = sequence.id -- Provide sequence_id
        }
    }

    local success_obj = command_manager.execute(command_data)
    if not success_obj.success then
        print("MoveClipToTrack failed: " .. success_obj.error_message)
    end
    assert_eq(success_obj.success, true, "MoveClipToTrack command should succeed")

    local moved_clip = Clip.load(clip.id, db)
    assert_eq(moved_clip.track_id, track2.id, "Clip should be on target track2")
    assert_eq(moved_clip.timeline_start.frames, 0, "Clip timeline_start should remain 0")

    -- Undo
    local undo_cmd = Command.deserialize(success_obj.result_data):create_undo()
    local undo_success = command_manager.execute(undo_cmd)
    assert_eq(undo_success.success, true, "Undo MoveClipToTrack command should succeed")

    local restored_clip = Clip.load(clip.id, db)
    assert_eq(restored_clip.track_id, track1.id, "Clip should be restored to track1")
    assert_eq(restored_clip.timeline_start.frames, 0, "Clip timeline_start should remain 0 after undo")

    -- Test move with pending_new_start_rat
    local pending_start_rat = Rational.new(72, 24, 1) -- Move to 3s (72 frames)
    local command_data_pending = {
        id = "cmd_move_clip_pending",
        type = "MoveClipToTrack",
        parameters = {
            project_id = project.id,
            clip_id = clip.id,
            target_track_id = track2.id,
            sequence_id = sequence.id,
            pending_new_start_rat = pending_start_rat,
            -- pending_duration_rat is not needed if clip.duration is used
        }
    }

    local pending_success_obj = command_manager.execute(command_data_pending)
    assert_eq(pending_success_obj.success, true, "MoveClipToTrack with pending start should succeed")

    local moved_clip_pending = Clip.load(clip.id, db)
    assert_eq(moved_clip_pending.track_id, track2.id, "Clip should be on track2 after pending move")
    assert_eq(moved_clip_pending.timeline_start.frames, 72, "Clip timeline_start should be 72 after pending move")

    -- Undo pending move
    local undo_pending_cmd = Command.deserialize(pending_success_obj.result_data):create_undo()
    local undo_pending_success = command_manager.execute(undo_pending_cmd)
    assert_eq(undo_pending_success.success, true, "Undo pending MoveClipToTrack should succeed")

    local restored_clip_pending = Clip.load(clip.id, db)
    assert_eq(restored_clip_pending.track_id, track1.id, "Clip should be restored to track1 after pending undo")
    assert_eq(restored_clip_pending.timeline_start.frames, 0, "Clip timeline_start should be 0 after pending undo")

    teardown_test_db(db)
end


-- ============================================================================
-- MAIN
-- ============================================================================

local function main()
    print("Starting frame accuracy tests...")
    
    -- Load all command modules to register them before running tests
    -- This mimics command_manager's behavior
    local modules_to_load = {
        "core.commands.create_clip",
        "core.commands.insert_clip_to_timeline",
        "core.commands.split_clip", -- Added split_clip
        "core.commands.ripple_delete", -- Added ripple_delete
        "core.commands.ripple_edit", -- Added ripple_edit
        "core.commands.nudge", -- Added nudge
        "core.commands.move_clip_to_track", -- Added move_clip_to_track
        -- Add other command modules here as they are refactored
    }
    for _, module_name in ipairs(modules_to_load) do
        require(module_name)
    end

    print("\n------------------------------------")
    
    collectgarbage("collect")
    run_test("test_create_clip_command", test_create_clip_command_func)

    collectgarbage("collect")
    run_test("test_insert_clip_to_timeline_command", test_insert_clip_to_timeline_command_func)

    collectgarbage("collect")
    run_test("test_insert_clip_with_master_clip_rescale", test_insert_clip_with_master_clip_rescale_func)

    collectgarbage("collect")
    run_test("test_split_clip_command", test_split_clip_command_func)

    collectgarbage("collect")
    run_test("test_ripple_delete_command", test_ripple_delete_command_func)

    collectgarbage("collect")
    run_test("test_ripple_edit_command", test_ripple_edit_command_func)

    collectgarbage("collect")
    run_test("test_nudge_command", test_nudge_command_func)

    -- New MoveClipToTrack test will go here
    collectgarbage("collect")
    run_test("test_move_clip_to_track_command", test_move_clip_to_track_command_func)


    print("\n------------------------------------")
    print(string.format("Total PASSED: %d, FAILED: %d", passed, failed))
    print("------------------------------------")

    if failed > 0 then
        os.exit(1)
    else
        os.exit(0)
    end
end

main()
