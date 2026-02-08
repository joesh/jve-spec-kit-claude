-- Test SelectClips command with Option modifier expands to linked clips
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_select_clips_option_linked.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Setup: project, sequence, tracks, media
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq1', 'A1', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'media.mov', '/tmp/media.mov', 1000,
        24000, 1001, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now, now, now, now, now))

-- Create video clip
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_v', 'proj1', 'timeline', 'Video Clip', 'trk_v', 'med1',
        0, 100, 0, 100, 24000, 1001, 1, 0, %d, %d);
]], now, now))

-- Create audio clip
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_a', 'proj1', 'timeline', 'Audio Clip', 'trk_a', 'med1',
        0, 100, 0, 100, 24000, 1001, 1, 0, %d, %d);
]], now, now))

-- Link the clips
ClipLink.create_link_group({
    { clip_id = "clip_v", role = "video", time_offset = 0 },
    { clip_id = "clip_a", role = "audio", time_offset = 0 },
}, db)

-- Initialize command manager
command_manager.init("seq1", "proj1")

-- Mock timeline_state for testing
local mock_selection = {}
local mock_clips = {
    { id = "clip_v", track_id = "trk_v" },
    { id = "clip_a", track_id = "trk_a" },
}

timeline_state.get_selected_clips = function()
    return mock_selection
end

timeline_state.set_selection = function(clips)
    mock_selection = clips
end

timeline_state.get_clip_by_id = function(clip_id)
    for _, clip in ipairs(mock_clips) do
        if clip.id == clip_id then return clip end
    end
    return nil
end

timeline_state.clear_edge_selection = function() end

-- Clear any existing selection
mock_selection = {}

-- Test 1: Select video clip WITHOUT Option - should only select video
print("\n--- Test 1: SelectClips without Option modifier ---")
local result = command_manager.execute("SelectClips", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_clip_ids = { "clip_v" },
    modifiers = {},  -- no Option
})
assert(result.success, "SelectClips should succeed: " .. (result.error_message or ""))

local selected = mock_selection
assert(#selected == 1, string.format("Should have 1 selected clip, got %d", #selected))
assert(selected[1].id == "clip_v", "Should have video clip selected")
print("✓ Without Option: only clicked clip selected")

-- Clear selection
mock_selection = {}

-- Test 2: Select video clip WITH Option - should select video AND audio
print("\n--- Test 2: SelectClips with Option modifier ---")
result = command_manager.execute("SelectClips", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_clip_ids = { "clip_v" },
    modifiers = { alt = true },  -- Option held
})
assert(result.success, "SelectClips should succeed: " .. (result.error_message or ""))

selected = mock_selection
assert(#selected == 2, string.format("Should have 2 selected clips (linked), got %d", #selected))

local has_video, has_audio = false, false
for _, clip in ipairs(selected) do
    if clip.id == "clip_v" then has_video = true end
    if clip.id == "clip_a" then has_audio = true end
end
assert(has_video, "Should have video clip selected")
assert(has_audio, "Should have audio clip selected (linked)")
print("✓ With Option: both linked clips selected")

-- Test 3: Option+Cmd on already-selected should deselect all linked
print("\n--- Test 3: Option+Cmd toggle on linked clips ---")
result = command_manager.execute("SelectClips", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_clip_ids = { "clip_v" },
    modifiers = { alt = true, command = true },  -- Option+Cmd
})
assert(result.success, "SelectClips should succeed")

selected = mock_selection
assert(#selected == 0, string.format("Should have 0 selected clips after toggle, got %d", #selected))
print("✓ Option+Cmd toggle: all linked clips deselected")

print("\n✅ test_select_clips_option_linked.lua passed")
