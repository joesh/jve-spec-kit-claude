#!/usr/bin/env luajit

-- Test: Roll edge selection properly expands to linked clips
-- When you Option+click a roll (both edges at boundary), linked tracks should
-- get BOTH edges of their corresponding boundary, not just the one edge.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_edge_selection_roll_expansion.db"
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
        1920, 1080, 0, 3000, 0, '[]', '[]', %d, %d);
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

-- Create clips:
-- V1: [clip_v1_left 0..1000] [clip_v1_right 1000..2000]
-- A1: [clip_a1_left 0..1000] [clip_a1_right 1000..2000]
db:exec(string.format([[
    -- V13 master sequence + track + media_ref for med1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_med1', 'proj1', 'med1_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_med1', 'master_med1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_med1' WHERE id = 'master_med1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_med1', 'proj1', 'master_med1', 'master_v_med1', 'med1', 0, 3000, 0, 3000, 48000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES ('clip_v1_left', 'proj1', 'V Left', 'trk_v', 'master_med1', 'seq1', 0, 1000, 0, 1000, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES ('clip_v1_right', 'proj1', 'V Right', 'trk_v', 'master_med1', 'seq1', 1000, 1000, 1000, 2000, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES ('clip_a1_left', 'proj1', 'A Left', 'trk_a', 'master_med1', 'seq1', 0, 1000, 0, 1000, 0, 0, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES ('clip_a1_right', 'proj1', 'A Right', 'trk_a', 'master_med1', 'seq1', 1000, 1000, 1000, 2000, 0, 0, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now))

-- Link left clips together, right clips together
ClipLink.create_link_group({
    { clip_id = "clip_v1_left", role = "video", time_offset = 0 },
    { clip_id = "clip_a1_left", role = "audio", time_offset = 0 },
}, db)

ClipLink.create_link_group({
    { clip_id = "clip_v1_right", role = "video", time_offset = 0 },
    { clip_id = "clip_a1_right", role = "audio", time_offset = 0 },
}, db)

-- Initialize command manager
command_manager.init("seq1", "proj1")

-- Mock timeline_state for testing
local mock_edges = {}
local mock_clips = {
    { id = "clip_v1_left", track_id = "trk_v", sequence_start = 0, duration = 1000 },
    { id = "clip_v1_right", track_id = "trk_v", sequence_start = 1000, duration = 1000 },
    { id = "clip_a1_left", track_id = "trk_a", sequence_start = 0, duration = 1000 },
    { id = "clip_a1_right", track_id = "trk_a", sequence_start = 1000, duration = 1000 },
}

timeline_state.get_selected_edges = function()
    return mock_edges
end

timeline_state.set_edge_selection = function(edges)
    mock_edges = edges or {}
end

timeline_state.get_clip_by_id = function(clip_id)
    for _, clip in ipairs(mock_clips) do
        if clip.id == clip_id then return clip end
    end
    return nil
end

timeline_state.get_clips_for_track = function(track_id)
    local result = {}
    for _, clip in ipairs(mock_clips) do
        if clip.track_id == track_id then
            table.insert(result, clip)
        end
    end
    return result
end

-- Test 1: Roll expansion gives complete rolls on all linked tracks
print("\n--- Test 1: Roll expansion to linked tracks ---")

-- Clear any existing selection
mock_edges = {}

-- Simulate a roll click at the V1 edit point (out of left + in of right)
local result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = {
        {clip_id = "clip_v1_left", edge_type = "out", trim_type = "roll"},
        {clip_id = "clip_v1_right", edge_type = "in", trim_type = "roll"},
    },
    modifiers = { alt = true },  -- Option held
})
assert(result.success, "SelectEdges should succeed")

local selected = mock_edges
assert(#selected == 4, string.format(
    "Roll expansion should give 4 edges (2 per track), got %d", #selected))

-- Verify we have both edges on both tracks
local found = {
    v1_out = false, v1_in = false,
    a1_out = false, a1_in = false
}
for _, edge in ipairs(selected) do
    if edge.clip_id == "clip_v1_left" and edge.edge_type == "out" then found.v1_out = true end
    if edge.clip_id == "clip_v1_right" and edge.edge_type == "in" then found.v1_in = true end
    if edge.clip_id == "clip_a1_left" and edge.edge_type == "out" then found.a1_out = true end
    if edge.clip_id == "clip_a1_right" and edge.edge_type == "in" then found.a1_in = true end

    -- All edges should have trim_type="roll"
    assert(edge.trim_type == "roll", string.format(
        "Edge %s:%s should have trim_type='roll', got '%s'",
        edge.clip_id, edge.edge_type, tostring(edge.trim_type)))
end

assert(found.v1_out, "Should have clip_v1_left:out")
assert(found.v1_in, "Should have clip_v1_right:in")
assert(found.a1_out, "Should have clip_a1_left:out")
assert(found.a1_in, "Should have clip_a1_right:in")

print("✓ Roll expansion: both edges on both tracks selected")

-- Test 2: Roll expansion when linked clip's adjacent is NOT linked
print("\n--- Test 2: Roll expansion with unlinked adjacent ---")

-- Unlink right clips for this test
ClipLink.unlink_clip("clip_v1_right", db)
ClipLink.unlink_clip("clip_a1_right", db)

-- Clear selection
mock_edges = {}

-- Roll at V1 edit point
-- v1_left is linked to a1_left
-- v1_right is NOT linked to anything
-- The roll expansion from v1_left→a1_left should still find a1_right as the adjacent clip
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = {
        {clip_id = "clip_v1_left", edge_type = "out", trim_type = "roll"},
        {clip_id = "clip_v1_right", edge_type = "in", trim_type = "roll"},
    },
    modifiers = { alt = true },
})
assert(result.success, "SelectEdges should succeed")

selected = mock_edges
-- Should have: v1_left:out, v1_right:in, a1_left:out, a1_right:in
-- a1_right is NOT linked to v1_right, but it IS adjacent to a1_left
assert(#selected == 4, string.format(
    "Roll expansion should still give 4 edges (a1_right is adjacent to a1_left), got %d", #selected))

-- Verify a1_right:in is included even though it's not linked to anything
local found_a1_right_in = false
for _, edge in ipairs(selected) do
    if edge.clip_id == "clip_a1_right" and edge.edge_type == "in" then
        found_a1_right_in = true
        break
    end
end
assert(found_a1_right_in, "Should have clip_a1_right:in (adjacent to linked clip)")

print("✓ Roll expansion with unlinked adjacent: found adjacent clip on linked track")

-- Test 3: Single edge expansion preserves trim_type
print("\n--- Test 3: Single edge expansion ---")

mock_edges = {}

result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = {
        {clip_id = "clip_v1_left", edge_type = "out", trim_type = "roll"},
    },
    modifiers = { alt = true },
})
assert(result.success, "SelectEdges should succeed")

selected = mock_edges
-- Single edge expansion: should get v1_left:out and a1_left:out only
assert(#selected == 2, string.format(
    "Single edge expansion should give 2 edges (one per linked clip), got %d", #selected))

for _, edge in ipairs(selected) do
    assert(edge.edge_type == "out", "All edges should be 'out' type")
    assert(edge.trim_type == "roll", "trim_type should be preserved as 'roll'")
end

print("✓ Single edge expansion: correct count and trim_type preserved")

-- Test 4: Roll expansion with gap (no adjacent clip)
print("\n--- Test 4: Roll expansion with gap ---")

-- Re-link the clips for this test
ClipLink.create_link_group({
    { clip_id = "clip_v1_left", role = "video", time_offset = 0 },
    { clip_id = "clip_a1_left", role = "audio", time_offset = 0 },
}, db)

-- Delete the right clips to create a gap scenario (gap extends to end of timeline)
db:exec([[DELETE FROM clips WHERE id = 'clip_v1_right']])
db:exec([[DELETE FROM clips WHERE id = 'clip_a1_right']])

-- Update mock data - now there's no adjacent media clip, but gap-as-clip means
-- there are no gap clips either since there's nothing after the left clips
-- (gap_lifecycle only creates gaps between clips, not trailing gaps)
mock_clips = {
    { id = "clip_v1_left", track_id = "trk_v", sequence_start = 0, duration = 1000 },
    { id = "clip_a1_left", track_id = "trk_a", sequence_start = 0, duration = 1000 },
}

mock_edges = {}

-- With gap-as-clip, there's no adjacent clip after left clips — no gap clip
-- to roll against. The single-edge expansion should just give out edges.
-- (A roll requires two clips at a boundary; at end-of-timeline there's nothing.)
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = {
        {clip_id = "clip_v1_left", edge_type = "out", trim_type = "roll"},
    },
    modifiers = { alt = true },
})
assert(result.success, "SelectEdges should succeed")

selected = mock_edges
-- Single edge expansion: v1_left:out + a1_left:out
assert(#selected == 2, string.format(
    "End-of-timeline roll should give 2 out edges (one per linked clip), got %d", #selected))

local found_v1_out = false
local found_a1_out = false
for _, edge in ipairs(selected) do
    if edge.clip_id == "clip_v1_left" and edge.edge_type == "out" then found_v1_out = true end
    if edge.clip_id == "clip_a1_left" and edge.edge_type == "out" then found_a1_out = true end
end
assert(found_v1_out, "Should have clip_v1_left:out")
assert(found_a1_out, "Should have clip_a1_left:out")

print("✓ End-of-timeline: out edges expanded to linked tracks")

-- Cleanup
database.shutdown()
os.remove(db_path)

print("\n✅ test_edge_selection_roll_expansion.lua passed")
