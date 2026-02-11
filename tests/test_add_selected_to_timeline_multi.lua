#!/usr/bin/env luajit

-- Test add_selected_to_timeline with multiple clips selected
-- This tests the UI layer, not just AddClipsToSequence directly

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Media = require('models.media')
local command_manager = require('core.command_manager')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== add_selected_to_timeline Multi-Clip Test ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_add_selected_multi.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence (24fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a2', 'sequence', 'A2', 'AUDIO', 2, 1);
]])

command_manager.init('sequence', 'project')

-- Create 3 media items with masterclip sequences (IS-a refactor)
for i = 1, 3 do
    local duration = 50 + (i * 25)  -- 75, 100, 125 frames

    local media = Media.create({
        id = "media_" .. i,
        project_id = "project",
        file_path = "/tmp/jve/video" .. i .. ".mov",
        name = "Video " .. i,
        duration_frames = duration,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        audio_channels = 0,  -- No audio to simplify test
    })
    media:save(db)

    -- IS-a refactor: create masterclip sequence (not clip with clip_kind='master')
    db:exec(string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
        VALUES ('master_%d', 'project', 'Video %d', 'masterclip', 24, 1, 48000, 1920, 1080, %d, %d);
    ]], i, i, now, now))

    -- Create video track in masterclip sequence
    db:exec(string.format([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('master_%d_v1', 'master_%d', 'V1', 'VIDEO', 1, 1);
    ]], i, i))

    -- Create stream clip in masterclip sequence
    db:exec(string.format([[
        INSERT INTO clips (id, project_id, track_id, owner_sequence_id, name, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, created_at, modified_at)
        VALUES ('stream_%d', 'project', 'master_%d_v1', 'master_%d', 'Video %d', 'media_%d', 0, %d, 0, %d, 24, 1, 1, %d, %d);
    ]], i, i, i, i, i, duration, duration, now, now))
end

-- Mock dependencies
package.loaded["core.logger"] = {
    info = function() end, debug = function() end,
    warn = function() end, error = function() end,
    trace = function() end,
}
package.loaded["core.focus_manager"] = {
    set_focused_panel = function() end,
    focus_panel = function() end,
}
package.loaded["ui.source_viewer_state"] = {
    current_clip_id = nil,
    mark_in = nil,
    mark_out = nil,
}

-- Load project_browser
local project_browser = require("ui.project_browser")

-- Mock timeline_panel
local mock_timeline_state = {
    get_sequence_id = function() return "sequence" end,
    get_project_id = function() return "project" end,
    get_playhead_position = function() return 0 end,
}
project_browser.timeline_panel = {
    get_state = function() return mock_timeline_state end,
}

-- Load master clips from DB to populate maps (simulating what populate_tree does)
local master_clips = database.load_master_clips("project")
project_browser.master_clip_map = {}
project_browser.media_map = {}
for _, clip in ipairs(master_clips) do
    project_browser.master_clip_map[clip.clip_id] = clip
    if clip.media then
        project_browser.media_map[clip.media_id] = clip.media
    end
end

-- Helper: count timeline clips
local function count_timeline_clips()
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = 'track_v1' AND clip_kind != 'master'")
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- =============================================================================
-- TEST: Select 3 clips and call add_selected_to_timeline
-- =============================================================================
print("Test: add_selected_to_timeline with 3 clips selected")

-- Set up selection with 3 master clips
project_browser.selected_items = {
    { type = "master_clip", clip_id = "master_1" },
    { type = "master_clip", clip_id = "master_2" },
    { type = "master_clip", clip_id = "master_3" },
}

print(string.format("  Selected %d items", #project_browser.selected_items))

-- Verify we have 3 clips in the map
local found_clips = 0
for _, item in ipairs(project_browser.selected_items) do
    if project_browser.master_clip_map[item.clip_id] then
        found_clips = found_clips + 1
    end
end
print(string.format("  Found %d clips in master_clip_map", found_clips))
assert(found_clips == 3, "Should find all 3 clips in master_clip_map")

-- Call add_selected_to_timeline
local ok, err = pcall(function()
    project_browser.add_selected_to_timeline("Insert", {advance_playhead = true})
end)

if not ok then
    print("ERROR: " .. tostring(err))
    error(err)
end

-- Verify 3 clips were added to timeline
local clip_count = count_timeline_clips()
print(string.format("  Timeline clips after insert: %d", clip_count))
assert(clip_count == 3, string.format("Should have 3 clips on timeline, got %d", clip_count))

print("\n✅ test_add_selected_to_timeline_multi.lua passed")
