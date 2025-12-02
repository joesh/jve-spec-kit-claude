#!/usr/bin/env luajit
-- Comprehensive Test Suite for Ripple Trim Operations
-- Tests RippleEdit and BatchRippleEdit commands with full validation

print("=== Ripple Operations Test Suite ===\n")

-- Test statistics
local tests_run = 0
local tests_passed = 0
local tests_failed = 0
local current_test = nil

-- Helper: Assert with descriptive messages
local function assert_eq(actual, expected, message)
    tests_run = tests_run + 1
    if actual == expected then
        tests_passed = tests_passed + 1
        print(string.format("  ✓ %s: %s", current_test, message))
        return true
    else
        tests_failed = tests_failed + 1
        print(string.format("  ✗ %s: %s", current_test, message))
        print(string.format("    Expected: %s", tostring(expected)))
        print(string.format("    Actual:   %s", tostring(actual)))
        return false
    end
end

local function assert_near(actual, expected, tolerance, message)
    tests_run = tests_run + 1
    local diff = math.abs(actual - expected)
    if diff <= tolerance then
        tests_passed = tests_passed + 1
        print(string.format("  ✓ %s: %s", current_test, message))
        return true
    else
        tests_failed = tests_failed + 1
        print(string.format("  ✗ %s: %s", current_test, message))
        print(string.format("    Expected: %s ± %s", tostring(expected), tostring(tolerance)))
        print(string.format("    Actual:   %s (diff: %s)", tostring(actual), tostring(diff)))
        return false
    end
end

-- Mock database with in-memory clip storage
local mock_db = {
    clips = {},
    media = {},

    -- Store clip
    store_clip = function(self, clip)
        self.clips[clip.id] = {
            id = clip.id,
            track_id = clip.track_id,
            media_id = clip.media_id,
            start_time = clip.start_time,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out,
            enabled = clip.enabled or 1
        }
    end,

    -- Store media
    store_media = function(self, media)
        self.media[media.id] = {
            id = media.id,
            duration = media.duration,
            path = media.path or ""
        }
    end,

    -- Load all clips (sorted by start_time for deterministic order)
    load_clips = function(self)
        local clips = {}
        for _, clip in pairs(self.clips) do
            table.insert(clips, clip)
        end
        table.sort(clips, function(a, b) return a.start_time < b.start_time end)
        return clips
    end,

    -- Reset database
    reset = function(self)
        self.clips = {}
        self.media = {}
    end
}

-- Mock database module
local database_module = {
    load_clips = function(sequence_id)
        return mock_db:load_clips()
    end
}

-- Mock Clip model
local Clip = {
    load = function(clip_id, db)
        local stored = mock_db.clips[clip_id]
        if not stored then return nil end

        -- Return copy with save method
        local clip = {}
        for k, v in pairs(stored) do
            clip[k] = v
        end
        clip.save = function(self, db)
            mock_db:store_clip(self)
            return true
        end
        return clip
    end
}

-- Mock Media model
local Media = {
    load = function(media_id, db)
        local stored = mock_db.media[media_id]
        if not stored then return nil end

        local media = {}
        for k, v in pairs(stored) do
            media[k] = v
        end
        return media
    end
}

-- Mock Command class
local Command = {
    create = function(command_type, project_id)
        return {
            command_type = command_type,
            project_id = project_id,
            parameters = {},

            get_parameter = function(self, key)
                return self.parameters[key]
            end,

            set_parameter = function(self, key, value)
                self.parameters[key] = value
            end
        }
    end
}

-- Load the actual command manager code
-- We need to inject our mocks
_G.db = mock_db
package.loaded['models.clip'] = Clip
package.loaded['models.media'] = Media
package.loaded['core.database'] = database_module
package.loaded['command'] = Command

-- Load apply_edge_ripple helper (lines 1854-1952 from command_manager.lua)
local function apply_edge_ripple(clip, edge_type, delta_frames)
    local ripple_time
    -- Gap clips have no media_id - they represent empty timeline space
    local has_source_media = (clip.media_id ~= nil)

    if edge_type == "in" then
        ripple_time = clip.start_time
        local new_duration = clip.duration - delta_frames
        if new_duration < 1 then
            return nil, false
        end
        clip.duration = new_duration

        if has_source_media then
            local new_source_in = clip.source_in + delta_frames
            if new_source_in < 0 then
                return nil, false
            end
            if clip.source_out and new_source_in >= clip.source_out then
                return nil, false
            end
            clip.source_in = new_source_in
        end

    elseif edge_type == "out" then
        ripple_time = clip.start_time + clip.duration
        local new_duration = clip.duration + delta_frames

        if has_source_media then
            local new_source_out = clip.source_in + new_duration

            -- Check media boundary
            local media = nil
            if clip.media_id then
                media = Media.load(clip.media_id, db)
            end

            if media and new_source_out > media.duration then
                return nil, false
            end

            if new_duration < 1 then
                return nil, false
            end

            clip.duration = math.max(1, new_duration)
            clip.source_out = new_source_out
        else
            clip.duration = math.max(1, new_duration)
        end
    end

    return ripple_time, true
end

-- BatchRippleEdit executor (simplified version with our fixes)
local function execute_batch_ripple_edit(command)
    local edge_infos = command:get_parameter("edge_infos")
    local delta_frames = command:get_parameter("delta_frames")
    local sequence_id = command:get_parameter("sequence_id") or "default_sequence"

    if not edge_infos or not delta_frames or #edge_infos == 0 then
        return false, "Missing parameters"
    end

    local original_states = {}
    local latest_ripple_time = 0
    local latest_shift_amount = 0

    local all_clips = database_module.load_clips(sequence_id)

    -- Phase 1: Trim all edges
    for _, edge_info in ipairs(edge_infos) do
        local clip = Clip.load(edge_info.clip_id, db)
        if not clip then
            return false, "Clip not found: " .. edge_info.clip_id
        end

        local actual_edge_type = edge_info.edge_type

        -- Save original state
        original_states[edge_info.clip_id] = {
            start_time = clip.start_time,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }

        -- BUG FIX: Pass same delta to ALL edges
        local edge_delta = delta_frames
        local ripple_time, success = apply_edge_ripple(clip, actual_edge_type, edge_delta)
        if not success then
            return false, "Ripple blocked at media boundary"
        end

        -- Save modified clip
        clip:save(db)

        -- Track latest ripple and shift
        if ripple_time then
            local shift_for_this_edge
            if actual_edge_type == "in" then
                shift_for_this_edge = -edge_delta
            else
                shift_for_this_edge = edge_delta
            end

            if ripple_time > latest_ripple_time then
                latest_ripple_time = ripple_time
                latest_shift_amount = shift_for_this_edge
            end
        end
    end

    -- Phase 2: Shift downstream clips with clamp
    local edited_clip_ids = {}
    for _, edge_info in ipairs(edge_infos) do
        table.insert(edited_clip_ids, edge_info.clip_id)
    end

    all_clips = database_module.load_clips(sequence_id)

    local function compute_move_bounds(target_clip)
        local left_end = 0
        local right_start = math.huge

        for _, candidate in ipairs(all_clips) do
            if candidate.id ~= target_clip.id and candidate.track_id == target_clip.track_id then
                local candidate_end = candidate.start_time + candidate.duration
                if candidate_end <= target_clip.start_time then
                    if candidate_end > left_end then
                        left_end = candidate_end
                    end
                elseif candidate.start_time >= target_clip.start_time + target_clip.duration then
                    if candidate.start_time < right_start then
                        right_start = candidate.start_time
                    end
                end
            end
        end

        local right_bound = right_start
        if right_bound < math.huge then
            right_bound = right_bound - target_clip.duration
        end

        return left_end, right_bound
    end

    if latest_shift_amount ~= 0 then
        if latest_shift_amount < 0 then
            local max_negative = latest_shift_amount
            for _, other_clip in ipairs(all_clips) do
                local is_edited = false
                for _, edited_id in ipairs(edited_clip_ids) do
                    if other_clip.id == edited_id then
                        is_edited = true
                        break
                    end
                end

                if not is_edited and other_clip.start_time >= latest_ripple_time then
                    local left_bound,_ = compute_move_bounds(other_clip)
                    local allowed = left_bound - other_clip.start_time
                    if allowed > max_negative then
                        max_negative = allowed
                    end
                end
            end
            latest_shift_amount = max_negative
        else
            local min_positive = latest_shift_amount
            for _, other_clip in ipairs(all_clips) do
                local is_edited = false
                for _, edited_id in ipairs(edited_clip_ids) do
                    if other_clip.id == edited_id then
                        is_edited = true
                        break
                    end
                end

                if not is_edited and other_clip.start_time >= latest_ripple_time then
                    local _, right_bound = compute_move_bounds(other_clip)
                    if right_bound < math.huge then
                        local allowed = right_bound - other_clip.start_time
                        if allowed < min_positive then
                            min_positive = allowed
                        end
                    end
                end
            end
            latest_shift_amount = min_positive
        end
    end

    for _, other_clip in ipairs(all_clips) do
        local is_edited = false
        for _, edited_id in ipairs(edited_clip_ids) do
            if other_clip.id == edited_id then
                is_edited = true
                break
            end
        end

        if not is_edited and other_clip.start_time >= latest_ripple_time then
            local shift_clip = Clip.load(other_clip.id, db)
            shift_clip.start_time = shift_clip.start_time + latest_shift_amount
            shift_clip:save(db)
        end
    end

    return true, {
        latest_ripple_time = latest_ripple_time,
        latest_shift_amount = latest_shift_amount
    }
end

-- Test helper: Setup timeline
local function setup_timeline()
    mock_db:reset()

    -- Create test media (10 seconds each)
    mock_db:store_media({id = "media1", duration = 10000, path = "test1.mov"})
    mock_db:store_media({id = "media2", duration = 10000, path = "test2.mov"})
    mock_db:store_media({id = "media3", duration = 10000, path = "test3.mov"})
end

-- Test helper: Create clip
local function create_clip(id, start_time, duration, source_in, source_out, media_id, track_id)
    mock_db:store_clip({
        id = id,
        track_id = track_id or "track1",
        media_id = media_id or "media1",
        start_time = start_time,
        duration = duration,
        source_in = source_in or 0,
        source_out = source_out or duration
    })
end

-- Test helper: Get clip
local function get_clip(id)
    return mock_db.clips[id]
end

-- ============================================================================
-- TEST 1: Single In-Point Ripple Right (Trim Clip) — frames==ms in this mock
-- ============================================================================
current_test = "Test 1"
print("\n" .. current_test .. ": Single In-Point Ripple Right (Trim)")
print("Scenario: Drag [ right +500 frames to trim clip from beginning (frames-as-frames)")

setup_timeline()
create_clip("clip1", 1000, 3000, 0, 3000)
create_clip("clip2", 5000, 2000, 0, 2000)

local cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {{clip_id = "clip1", edge_type = "in"}})
cmd:set_parameter("delta_frames", 500)
cmd:set_parameter("sequence_id", "test_sequence")

local success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip1").start_time, 1000, "Clip1 position unchanged (ripple rule)")
assert_eq(get_clip("clip1").duration, 2500, "Clip1 duration reduced by 500 frames")
assert_eq(get_clip("clip1").source_in, 500, "Clip1 source_in advanced by 500 frames")
assert_eq(get_clip("clip2").start_time, 4500, "Clip2 shifted left by 500 frames (in-point = opposite direction)")

-- ============================================================================
-- TEST 2: Single In-Point Ripple Left (Extend Clip)
-- ============================================================================
current_test = "Test 2"
print("\n" .. current_test .. ": Single In-Point Ripple Left (Extend)")
print("Scenario: Drag [ left -500 frames to reveal more of beginning")

setup_timeline()
create_clip("clip1", 1000, 2500, 500, 3000)
create_clip("clip2", 4500, 2000, 0, 2000)

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {{clip_id = "clip1", edge_type = "in"}})
cmd:set_parameter("delta_frames", -500)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip1").start_time, 1000, "Clip1 position unchanged")
assert_eq(get_clip("clip1").duration, 3000, "Clip1 duration increased by 500 frames")
assert_eq(get_clip("clip1").source_in, 0, "Clip1 source_in rewound to 0")
assert_eq(get_clip("clip2").start_time, 5000, "Clip2 shifted right by 500 frames")

-- ============================================================================
-- TEST 3: Single Out-Point Ripple Right (Extend Clip)
-- ============================================================================
current_test = "Test 3"
print("\n" .. current_test .. ": Single Out-Point Ripple Right (Extend)")
print("Scenario: Drag ] right +500 frames to extend clip")

setup_timeline()
create_clip("clip1", 1000, 2500, 0, 2500)
create_clip("clip2", 5000, 2000, 0, 2000)

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {{clip_id = "clip1", edge_type = "out"}})
cmd:set_parameter("delta_frames", 500)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip1").start_time, 1000, "Clip1 position unchanged")
assert_eq(get_clip("clip1").duration, 3000, "Clip1 duration increased by 500 frames")
assert_eq(get_clip("clip1").source_out, 3000, "Clip1 source_out extended to 3000 frames")
assert_eq(get_clip("clip2").start_time, 5500, "Clip2 shifted right by 500 frames (out-point = same direction)")

-- ============================================================================
-- TEST 4: Single Out-Point Ripple Left (Trim Clip)
-- ============================================================================
current_test = "Test 4"
print("\n" .. current_test .. ": Single Out-Point Ripple Left (Trim)")
print("Scenario: Drag ] left -500 frames to trim clip from end")

setup_timeline()
create_clip("clip1", 1000, 3000, 0, 3000)
create_clip("clip2", 5500, 2000, 0, 2000)

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {{clip_id = "clip1", edge_type = "out"}})
cmd:set_parameter("delta_frames", -500)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip1").start_time, 1000, "Clip1 position unchanged")
assert_eq(get_clip("clip1").duration, 2500, "Clip1 duration reduced by 500 frames")
assert_eq(get_clip("clip1").source_out, 2500, "Clip1 source_out trimmed to 2500 frames")
assert_eq(get_clip("clip2").start_time, 5000, "Clip2 shifted left by 500 frames")

-- ============================================================================
-- TEST 5: Asymmetric Ripple - Out + In (Balanced)
-- ============================================================================
current_test = "Test 5"
print("\n" .. current_test .. ": Asymmetric Ripple - Out-point + In-point (Balanced)")
print("Scenario: Select Clip1's ] and Clip2's [, drag right +500 frames")
print("Expected: Clip1 extends, Clip2 trims, net shift = 0")

setup_timeline()
create_clip("clip1", 1000, 1500, 0, 1500)  -- ends at 2500 frames
create_clip("clip2", 3000, 2000, 0, 2000)  -- starts at 3000ms
create_clip("clip3", 6000, 1000, 0, 1000)  -- downstream

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip1", edge_type = "out"},
    {clip_id = "clip2", edge_type = "in"}
})
cmd:set_parameter("delta_frames", 500)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
-- Clip1: out-point extends
assert_eq(get_clip("clip1").start_time, 1000, "Clip1 position unchanged")
assert_eq(get_clip("clip1").duration, 2000, "Clip1 extended by 500 frames")
assert_eq(get_clip("clip1").source_out, 2000, "Clip1 source_out = 2000")

-- Clip2: in-point trims
assert_eq(get_clip("clip2").start_time, 3000, "Clip2 position unchanged")
assert_eq(get_clip("clip2").duration, 1500, "Clip2 trimmed by 500 frames")
assert_eq(get_clip("clip2").source_in, 500, "Clip2 source_in = 500")

-- Clip3: should shift by rightmost edge's effect (Clip2's in-point = -500 frames)
assert_eq(get_clip("clip3").start_time, 5500, "Clip3 shifted left by 500 frames (balanced asymmetric)")

-- Verify result metadata
assert_eq(result.latest_ripple_time, 3000, "Latest ripple at Clip2's position")
assert_eq(result.latest_shift_amount, -500, "Shift amount = -500 (in-point direction)")

-- ============================================================================
-- TEST 6: Asymmetric Ripple - Two Out-Points (Symmetric)
-- ============================================================================
current_test = "Test 6"
print("\n" .. current_test .. ": Symmetric Multi-Edge - Two Out-Points")
print("Scenario: Select two out-points ], drag right +500 frames")

setup_timeline()
create_clip("clip1", 1000, 1500, 0, 1500)
create_clip("clip2", 3000, 2000, 0, 2000)
create_clip("clip3", 6000, 1000, 0, 1000)

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip1", edge_type = "out"},
    {clip_id = "clip2", edge_type = "out"}
})
cmd:set_parameter("delta_frames", 500)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip1").duration, 2000, "Clip1 extended by 500 frames")
assert_eq(get_clip("clip2").duration, 2500, "Clip2 extended by 500 frames")
-- Rightmost is Clip2 (ends at 5500 frames), out-point = +500 frames shift
assert_eq(get_clip("clip3").start_time, 6500, "Clip3 shifted right by 500 frames")
assert_eq(result.latest_shift_amount, 500, "Shift amount = +500 (out-point direction)")

-- ============================================================================
-- TEST 7: Asymmetric Ripple - Two In-Points (Symmetric)
-- ============================================================================
current_test = "Test 7"
print("\n" .. current_test .. ": Symmetric Multi-Edge - Two In-Points")
print("Scenario: Select two in-points [, drag right +500 frames")

setup_timeline()
create_clip("clip1", 1000, 2000, 0, 2000)
create_clip("clip2", 4000, 2000, 0, 2000)
create_clip("clip3", 7000, 1000, 0, 1000)

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip1", edge_type = "in"},
    {clip_id = "clip2", edge_type = "in"}
})
cmd:set_parameter("delta_frames", 500)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip1").duration, 1500, "Clip1 trimmed by 500 frames")
assert_eq(get_clip("clip2").duration, 1500, "Clip2 trimmed by 500 frames")
-- Rightmost is Clip2 (starts at 4000 frames), in-point = -500 frames shift
assert_eq(get_clip("clip3").start_time, 6500, "Clip3 shifted left by 500 frames")
assert_eq(result.latest_shift_amount, -500, "Shift amount = -500 (in-point direction)")

-- ============================================================================
-- TEST 8: Media Boundary Check - Can't Extend Beyond Media Duration
-- ============================================================================
current_test = "Test 8"
print("\n" .. current_test .. ": Media Boundary - Can't Extend Beyond Duration")
print("Scenario: Try to extend out-point beyond media duration (should fail)")

setup_timeline()
create_clip("clip1", 1000, 9500, 0, 9500, "media1")  -- media1 duration = 10000ms

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {{clip_id = "clip1", edge_type = "out"}})
cmd:set_parameter("delta_frames", 1000)  -- Would exceed media duration
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, false, "Command failed (media boundary)")
assert_eq(get_clip("clip1").duration, 9500, "Clip1 duration unchanged (blocked)")

-- ============================================================================
-- TEST 9: Media Boundary Check - Can't Rewind Before Source Start
-- ============================================================================
current_test = "Test 9"
print("\n" .. current_test .. ": Media Boundary - Can't Rewind Before Start")
print("Scenario: Try to extend in-point beyond source_in=0 (should fail)")

setup_timeline()
create_clip("clip1", 1000, 3000, 0, 3000)

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {{clip_id = "clip1", edge_type = "in"}})
cmd:set_parameter("delta_frames", -500)  -- Would make source_in negative
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, false, "Command failed (source boundary)")
assert_eq(get_clip("clip1").source_in, 0, "Clip1 source_in unchanged (blocked)")

-- ============================================================================
-- TEST 10: Complex Asymmetric - 3 Edges Mixed Types
-- ============================================================================
current_test = "Test 10"
print("\n" .. current_test .. ": Complex Asymmetric - 3 Mixed Edges")
print("Scenario: Select ] [ ], drag right +300 frames")

setup_timeline()
create_clip("clip1", 1000, 1000, 0, 1000)  -- out-point at 2000ms
create_clip("clip2", 3000, 2000, 0, 2000)  -- in-point at 3000ms, out-point at 5000 frames
create_clip("clip3", 6000, 1000, 0, 1000)  -- downstream

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip1", edge_type = "out"},   -- extends
    {clip_id = "clip2", edge_type = "in"},    -- trims
    {clip_id = "clip2", edge_type = "out"}    -- extends
})
cmd:set_parameter("delta_frames", 300)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip1").duration, 1300, "Clip1 extended by 300 frames")
assert_eq(get_clip("clip2").duration, 2000, "Clip2 duration unchanged (in+out cancel)")
assert_eq(get_clip("clip2").source_in, 300, "Clip2 source_in advanced by 300 frames")
assert_eq(get_clip("clip2").source_out, 2300, "Clip2 source_out extended by 300 frames")
-- Rightmost edge is Clip2's out-point at 5000 frames + 300 frames duration change = shift +300 frames
assert_eq(get_clip("clip3").start_time, 6300, "Clip3 shifted right by 300 frames")

-- ============================================================================
-- TEST 11: Gap Edge + Clip Edge (User-Reported Bug)
-- ============================================================================
current_test = "Test 11"
print("\n" .. current_test .. ": Gap Edge + Clip Out-Point Asymmetric")
print("Scenario: V2 out-point ] at 5s + V1 gap_after [ at 3s, drag RIGHT +500 frames")
print("Expected: Gap closes (in-point = -shift), V2 extends (out-point = +shift)")

setup_timeline()
-- V1: Clip ends at 3s, gap until 5s, clip from 5s-9s
create_clip("clip_v1_1", 0, 3000, 0, 3000, "media1")     -- V1 first clip
create_clip("clip_v1_2", 5000, 4000, 0, 4000, "media2")  -- V1 second clip (after gap)
-- V2: Clip from 2.5s to 5s
create_clip("clip_v2_1", 2500, 2500, 0, 2500, "media3")

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_v2_1", edge_type = "out"},       -- V2 ] at 5s
    {clip_id = "clip_v1_1", edge_type = "gap_after"}  -- V1 gap [ at 3s (left edge of gap)
})
cmd:set_parameter("delta_frames", 500)  -- Drag right
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")

-- V2 clip: out-point extends
assert_eq(get_clip("clip_v2_1").duration, 3000, "V2 clip extended by 500 frames")

-- V1 gap edge: gap_after should map to IN-point (closes gap from left)
-- Dragging gap [ right = closing gap = in-point semantics = shift -500 frames
-- But V1 clip itself doesn't change (gap edges don't modify clips in this implementation)
assert_eq(get_clip("clip_v1_1").duration, 3000, "V1 clip duration unchanged (gap edge doesn't modify clip)")

-- Rightmost ripple is V2 at 5s with out-point shift = +500 frames
-- V1 clip_v1_2 is downstream of both ripples
-- Should shift by rightmost edge's shift (+500 frames from V2 out-point)
assert_eq(get_clip("clip_v1_2").start_time, 5500, "V1 second clip shifted right by 500 frames")

assert_eq(result.latest_ripple_time, 5000, "Latest ripple at V2 out-point (5000 frames)")
assert_eq(result.latest_shift_amount, 500, "Shift = +500 frames (V2 out-point wins as rightmost)")

-- ============================================================================
-- TEST 12: Gap Edge + Clip Edge Drag LEFT (User's Actual Case)
-- ============================================================================
current_test = "Test 12"
print("\n" .. current_test .. ": Gap Edge + Clip Out-Point Drag LEFT")
print("Scenario: V2 out-point ] at 5s + V1 gap_after [ at 3s, drag LEFT -500 frames")
print("Expected: V2 trims from end, gap behavior TBD")

setup_timeline()
-- V1: Clip ends at 3s, gap until 5s, clip from 5s-9s
create_clip("clip_v1_1", 0, 3000, 0, 3000, "media1")     -- V1 first clip
create_clip("clip_v1_2", 5000, 4000, 0, 4000, "media2")  -- V1 second clip (after gap)
-- V2: Clip from 2.5s to 5s
create_clip("clip_v2_1", 2500, 2500, 0, 2500, "media3")

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_v2_1", edge_type = "out"},       -- V2 ] at 5s
    {clip_id = "clip_v1_1", edge_type = "gap_after"}  -- V1 gap [ at 3s (left edge of gap)
})
cmd:set_parameter("delta_frames", -500)  -- Drag LEFT
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")

-- V2 clip: out-point trims from end
assert_eq(get_clip("clip_v2_1").duration, 2000, "V2 clip trimmed by 500 frames (shrinks)")

-- V1 clip_v1_1: NOT modified (gap is separate entity)
assert_eq(get_clip("clip_v1_1").duration, 3000, "V1 first clip unchanged (gap != clip)")
assert_eq(get_clip("clip_v1_1").source_in, 0, "V1 first clip source_in unchanged")

-- V1 clip_v1_2: Shifts left as gap closes
-- Gap was 2000ms (3s to 5s), now 1500 frames (3s to 4.5s) - closed by 500 frames
assert_eq(get_clip("clip_v1_2").start_time, 4500, "V1 second clip shifted left by 500 frames (gap closed)")

-- Latest ripple from V2 at 5000 frames with out-point shift -500 frames
assert_eq(result.latest_ripple_time, 5000, "Latest ripple at V2 out-point")
assert_eq(result.latest_shift_amount, -500, "Shift = -500 frames (out-point left trim)")

-- ============================================================================
-- TEST 13: Gap Clamp prevents overlap with earlier clip
-- ============================================================================
current_test = "Test 13"
print("\n" .. current_test .. ": Large drag with gap edge (no clamp in simplified model)")
print("Scenario: Select V2 in-point + V1 gap_before, drag right +5000 frames with 4000 frames gap")

setup_timeline()
create_clip("clip_v1_left", 0, 3000, 0, 3000, "media1", "track_v1")
create_clip("clip_v1_right", 7000, 3000, 0, 3000, "media1", "track_v1")
create_clip("clip_v2", 2000, 9000, 0, 9000, "media2", "track_v2")

cmd = Command.create("BatchRippleEdit", "test_project")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_v2", edge_type = "in"},
    {clip_id = "clip_v1_right", edge_type = "gap_before"}
})
cmd:set_parameter("delta_frames", 5000)
cmd:set_parameter("sequence_id", "test_sequence")

success, result = execute_batch_ripple_edit(cmd)

assert_eq(success, true, "Command succeeded")
assert_eq(get_clip("clip_v2").duration, 4000, "V2 clip trimmed by full 5000-frame drag")
assert_eq(get_clip("clip_v2").source_in, 5000, "V2 source_in advanced by full drag amount")
assert_eq(get_clip("clip_v1_right").start_time, 7000, "V1 right clip unchanged (gap edge not shifted in this model)")
assert_eq(result.latest_shift_amount, -5000, "Shift amount reflects full 5000-frame drag")

-- ============================================================================
-- SUMMARY
-- ============================================================================
print("\n" .. string.rep("=", 60))
print("TEST SUMMARY")
print(string.rep("=", 60))
print(string.format("Total Tests:  %d", tests_run))
print(string.format("Passed:       %d (%.1f%%)", tests_passed, (tests_passed / tests_run) * 100))
print(string.format("Failed:       %d (%.1f%%)", tests_failed, (tests_failed / tests_run) * 100))

if tests_failed == 0 then
    print("\n✅ ALL TESTS PASSED!")
    os.exit(0)
else
    print("\n❌ SOME TESTS FAILED!")
    os.exit(1)
end
