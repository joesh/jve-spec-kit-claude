#!/usr/bin/env luajit

-- Test: Edge selection expansion works correctly for split clips
-- After splitting linked clips, selecting an edge and expanding should include all linked clips

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_edge_selection_split_clips.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Setup: project, sequence, tracks
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 3000, 500, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq1', 'A1', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'media.mov', '/tmp/media.mov', 3000,
        24000, 1001, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now, now, now, now, now))

-- Create linked clips: V1 [video 0..1000] linked to A1 [audio 0..1000]
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_video', 'proj1', 'timeline', 'Video', 'trk_v', 'med1',
        0, 1000, 0, 1000, 24000, 1001, 1, 0, %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_audio', 'proj1', 'timeline', 'Audio', 'trk_a', 'med1',
        0, 1000, 0, 1000, 24000, 1001, 1, 0, %d, %d);
]], now, now))

-- Link them
ClipLink.create_link_group({
    { clip_id = "clip_video", role = "video", time_offset = 0 },
    { clip_id = "clip_audio", role = "audio", time_offset = 0 },
}, db)

-- Initialize command manager
command_manager.init("seq1", "proj1")

-- Mock timeline_state for the Split wrapper to find clips at playhead
local all_test_clips = {
    { id = "clip_video", track_id = "trk_v", timeline_start = 0, duration = 1000 },
    { id = "clip_audio", track_id = "trk_a", timeline_start = 0, duration = 1000 },
}

timeline_state.get_playhead_position = function() return 500 end
timeline_state.get_clips_at_time = function(time)
    local result = {}
    for _, clip in ipairs(all_test_clips) do
        if clip.timeline_start <= time and (clip.timeline_start + clip.duration) > time then
            table.insert(result, clip)
        end
    end
    return result
end
timeline_state.get_clips = function() return all_test_clips end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_project_id = function() return "proj1" end
timeline_state.get_sequence_id = function() return "seq1" end

-- Split both clips using the interactive Split command (links second halves)
print("--- Setup: Split both clips at frame 500 using Split wrapper ---")

local result = command_manager.execute("Split", {
    project_id = "proj1",
    sequence_id = "seq1",
})
assert(result == true or (result and result.success), "Split should succeed")

-- Find the second half clip IDs
local video_second_id, audio_second_id
local stmt = db:prepare([[SELECT id FROM clips WHERE track_id = 'trk_v' AND timeline_start_frame = 500]])
if stmt:exec() and stmt:next() then video_second_id = stmt:value(0) end
stmt:finalize()

stmt = db:prepare([[SELECT id FROM clips WHERE track_id = 'trk_a' AND timeline_start_frame = 500]])
if stmt:exec() and stmt:next() then audio_second_id = stmt:value(0) end
stmt:finalize()

assert(video_second_id, "Should find second video clip")
assert(audio_second_id, "Should find second audio clip")
print(string.format("  Video second half: %s", video_second_id))
print(string.format("  Audio second half: %s", audio_second_id))

-- First halves should be linked to each other (original link group preserved)
local first_half_links = ClipLink.get_link_group("clip_video", db)
assert(first_half_links and #first_half_links == 2, string.format(
    "First halves should be linked (2 clips), got %s",
    first_half_links and #first_half_links or "nil"))
print(string.format("  First halves link group: %d clips", #first_half_links))

-- Second halves should be linked to each other (NEW link group)
local second_half_links = ClipLink.get_link_group(video_second_id, db)
assert(second_half_links and #second_half_links == 2, string.format(
    "Second halves should be linked (2 clips), got %s",
    second_half_links and #second_half_links or "nil"))
print(string.format("  Second halves link group: %d clips", #second_half_links))

-- Verify second halves are NOT in first halves' group
local video_second_in_first = false
for _, link in ipairs(first_half_links) do
    if link.clip_id == video_second_id then video_second_in_first = true end
end
assert(not video_second_in_first, "Second halves should NOT be in first halves' link group")

-- Mock timeline_state for testing
local mock_edges = {}
local mock_clips = {
    { id = "clip_video", track_id = "trk_v", timeline_start = 0, duration = 500 },
    { id = video_second_id, track_id = "trk_v", timeline_start = 500, duration = 500 },
    { id = "clip_audio", track_id = "trk_a", timeline_start = 0, duration = 500 },
    { id = audio_second_id, track_id = "trk_a", timeline_start = 500, duration = 500 },
}

timeline_state.get_selected_edges = function() return mock_edges end
timeline_state.set_edge_selection = function(edges) mock_edges = edges or {} end
timeline_state.get_clip_by_id = function(clip_id)
    for _, clip in ipairs(mock_clips) do
        if clip.id == clip_id then return clip end
    end
    return nil
end
timeline_state.get_clips_for_track = function(track_id)
    local track_clips = {}
    for _, clip in ipairs(mock_clips) do
        if clip.track_id == track_id then table.insert(track_clips, clip) end
    end
    return track_clips
end

-- Test: Select edge on second video clip and expand to linked
-- Second halves are in their own link group, so expansion only finds the other second half
print("\n--- Test: Edge expansion on split clip's second half ---")
mock_edges = {}

result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = {
        {clip_id = video_second_id, edge_type = "out", trim_type = "ripple"},
    },
    modifiers = { alt = true },  -- Option held = expand to linked
})
assert(result.success, "SelectEdges should succeed")

-- Second halves are linked together (separate from first halves)
-- Expansion gives 2 edges: video_second:out, audio_second:out
assert(#mock_edges == 2, string.format(
    "Expansion should give 2 edges (second halves only), got %d", #mock_edges))

local found_v2 = false
local found_a2 = false
for _, edge in ipairs(mock_edges) do
    if edge.clip_id == video_second_id and edge.edge_type == "out" then found_v2 = true end
    if edge.clip_id == audio_second_id and edge.edge_type == "out" then found_a2 = true end
end

assert(found_v2, "Should have video_second:out")
assert(found_a2, "Should have audio_second:out")

print("✓ Edge expansion on split clip expands to linked second half only")

-- Test: Roll at the split boundary (frame 500)
-- This tests selecting edges at the edit point between first and second halves
print("\n--- Test: Roll at split boundary ---")
mock_edges = {}

-- Select both edges of the roll at the split boundary on video track
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = {
        {clip_id = "clip_video", edge_type = "out", trim_type = "roll"},
        {clip_id = video_second_id, edge_type = "in", trim_type = "roll"},
    },
    modifiers = { alt = true },
})
assert(result.success, "SelectEdges should succeed")

-- clip_video is linked to clip_audio (first halves)
-- video_second is linked to audio_second (second halves)
-- Expansion from clip_video:out finds clip_audio's downstream boundary
-- Expansion from video_second:in finds audio_second's upstream boundary
-- Result: 4 edges forming complete roll on both tracks
assert(#mock_edges == 4, string.format(
    "Roll expansion should give 4 edges, got %d", #mock_edges))

local found = { v_out = false, v_in = false, a_out = false, a_in = false }
for _, edge in ipairs(mock_edges) do
    if edge.clip_id == "clip_video" and edge.edge_type == "out" then found.v_out = true end
    if edge.clip_id == video_second_id and edge.edge_type == "in" then found.v_in = true end
    if edge.clip_id == "clip_audio" and edge.edge_type == "out" then found.a_out = true end
    if edge.clip_id == audio_second_id and edge.edge_type == "in" then found.a_in = true end
end

assert(found.v_out, "Should have clip_video:out")
assert(found.v_in, "Should have video_second:in")
assert(found.a_out, "Should have clip_audio:out")
assert(found.a_in, "Should have audio_second:in")

print("✓ Roll at split boundary expands correctly (both link groups involved)")

-- Cleanup
database.shutdown()
os.remove(db_path)

print("\n✅ test_edge_selection_split_clips.lua passed")
