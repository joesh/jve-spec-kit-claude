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
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'sequence', 24000, 1001, 48000,
        1920, 1080, 0, 3000, 500, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq1', 'A1', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

require("test_env").create_test_media({
    id = "med1",
    project_id = "proj1",
    name = "media.mov",
    file_path = "/tmp/media.mov",
    duration_frames = 3000,
    fps_numerator = 24000,
    fps_denominator = 1001,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    codec = "prores",
    audio_sample_rate = 48000,
})

-- V13 master sequence wrapping med1.
local _Sequence = require("models.sequence")
local _MC = _Sequence.ensure_master("med1", "proj1")

-- Create linked clips: V1 [video 0..1000] linked to A1 [audio 0..1000]
db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id,
        owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('clip_video', 'proj1', 'Video', 'trk_v', 'seq1', '%s', 0, 1000, 0, 1000, NULL, NULL, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);
]], _MC, now, now))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id,
        owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('clip_audio', 'proj1', 'Audio', 'trk_a', 'seq1', '%s', 0, 1000, 0, 1000, 0, 0, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);
]], _MC, now, now))

-- Link them
ClipLink.create_link_group({
    { clip_id = "clip_video", role = "video", time_offset = 0 },
    { clip_id = "clip_audio", role = "audio", time_offset = 0 },
}, db)

-- Initialize command manager
command_manager.init("seq1", "proj1")

-- Mock timeline_state state for the Blade wrapper. The Blade command reads
-- clips from the real DB rows we inserted above; only playhead + selection
-- need stubbing here.
timeline_state.get_playhead_position = function() return 500 end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_project_id = function() return "proj1" end

-- Split both clips using the interactive Split command (links second halves)
print("--- Setup: Split both clips at frame 500 using Split wrapper ---")

-- V13: razor-at-playhead-across-armed-tracks is the Blade command.
local result = command_manager.execute("Blade", {
    project_id = "proj1",
    sequence_id = "seq1",
    blade_frame = 500,
    track_ids = { "trk_v", "trk_a" },
})
assert(result == true or (result and result.success), "Blade should succeed")

-- Find the second half clip IDs
local video_second_id, audio_second_id
local stmt = db:prepare([[SELECT id FROM clips WHERE track_id = 'trk_v' AND sequence_start_frame = 500]])
if stmt:exec() and stmt:next() then video_second_id = stmt:value(0) end
stmt:finalize()

stmt = db:prepare([[SELECT id FROM clips WHERE track_id = 'trk_a' AND sequence_start_frame = 500]])
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
    { id = "clip_video", track_id = "trk_v", sequence_start = 0, duration = 500 },
    { id = video_second_id, track_id = "trk_v", sequence_start = 500, duration = 500 },
    { id = "clip_audio", track_id = "trk_a", sequence_start = 0, duration = 500 },
    { id = audio_second_id, track_id = "trk_a", sequence_start = 500, duration = 500 },
}

timeline_state.get_selected_edges = function() return mock_edges end
timeline_state.set_edge_selection = function(edges) mock_edges = edges or {} end
-- 022/1.3e: re-wire strip to expose the second-scenario mock_clips set
-- (the linked-split test uses a different clip layout than the first).
timeline_state.get_tab_strip = function()
    return require("test_env").make_strip_stub({ displayed_clips = mock_clips })
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
