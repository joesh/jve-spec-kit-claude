-- Test SelectEdges command with Option modifier expands to linked clips
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_select_edges_option_linked.db"
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
local mock_edges = {}
local mock_clips = {
    { id = "clip_v", track_id = "trk_v" },
    { id = "clip_a", track_id = "trk_a" },
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

-- Clear any existing selection
mock_edges = {}

-- Test 1: Select video edge WITHOUT Option - should only select video edge
print("\n--- Test 1: SelectEdges without Option modifier ---")
local result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = { { clip_id = "clip_v", edge_type = "out", trim_type = "ripple" } },
    modifiers = {},  -- no Option
})
assert(result.success, "SelectEdges should succeed: " .. (result.error_message or ""))

local selected = mock_edges
assert(#selected == 1, string.format("Should have 1 selected edge, got %d", #selected))
assert(selected[1].clip_id == "clip_v", "Should have video clip edge selected")
assert(selected[1].edge_type == "out", "Should be out edge")
print("✓ Without Option: only clicked edge selected")

-- Clear selection
mock_edges = {}

-- Test 2: Select video edge WITH Option - should select video AND audio edges
print("\n--- Test 2: SelectEdges with Option modifier ---")
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = { { clip_id = "clip_v", edge_type = "out", trim_type = "ripple" } },
    modifiers = { alt = true },  -- Option held
})
assert(result.success, "SelectEdges should succeed: " .. (result.error_message or ""))

selected = mock_edges
assert(#selected == 2, string.format("Should have 2 selected edges (linked), got %d", #selected))

local has_video, has_audio = false, false
for _, edge in ipairs(selected) do
    if edge.clip_id == "clip_v" then has_video = true end
    if edge.clip_id == "clip_a" then has_audio = true end
    assert(edge.edge_type == "out", "All edges should be 'out' type")
end
assert(has_video, "Should have video clip edge selected")
assert(has_audio, "Should have audio clip edge selected (linked)")
print("✓ With Option: same edge on all linked clips selected")

-- Test 3: Option+Cmd on already-selected should deselect all linked
print("\n--- Test 3: Option+Cmd toggle on linked edges ---")
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = { { clip_id = "clip_v", edge_type = "out", trim_type = "ripple" } },
    modifiers = { alt = true, command = true },  -- Option+Cmd
})
assert(result.success, "SelectEdges should succeed")

selected = mock_edges
assert(#selected == 0, string.format("Should have 0 selected edges after toggle, got %d", #selected))
print("✓ Option+Cmd toggle: all linked edges deselected")

-- Test 4: In-edge selection also works
print("\n--- Test 4: In-edge with Option modifier ---")
mock_edges = {}
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = { { clip_id = "clip_a", edge_type = "in", trim_type = "ripple" } },
    modifiers = { alt = true },
})
assert(result.success, "SelectEdges should succeed")

selected = mock_edges
assert(#selected == 2, string.format("Should have 2 selected edges, got %d", #selected))
for _, edge in ipairs(selected) do
    assert(edge.edge_type == "in", "All edges should be 'in' type")
end
print("✓ In-edge with Option: propagates in-edge to linked clips")

-- Test 5: Roll trim_type is preserved during expansion
print("\n--- Test 5: Roll trim_type preserved with Option ---")
mock_edges = {}
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = { { clip_id = "clip_v", edge_type = "out", trim_type = "roll" } },
    modifiers = { alt = true },
})
assert(result.success, "SelectEdges should succeed")

selected = mock_edges
assert(#selected == 2, string.format("Should have 2 selected edges, got %d", #selected))
for _, edge in ipairs(selected) do
    assert(edge.trim_type == "roll", string.format(
        "Edge %s should have trim_type='roll', got '%s'",
        edge.clip_id, tostring(edge.trim_type)))
end
print("✓ Roll trim_type preserved on linked clips")

-- Test 6: Roll between clip edge and gap_after expands both edges to linked clips
-- Regression: processed_groups optimization skipped second edge from same clip
print("\n--- Test 6: Roll with gap_after expands both edges ---")
mock_edges = {}
result = command_manager.execute("SelectEdges", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_edges = {
        { clip_id = "clip_v", edge_type = "out", trim_type = "roll" },
        { clip_id = "clip_v", edge_type = "gap_after", trim_type = "roll" },
    },
    modifiers = { alt = true },
})
assert(result.success, "SelectEdges should succeed")

selected = mock_edges
-- Should have 4 edges: clip_v out, clip_v gap_after, clip_a out, clip_a gap_after
assert(#selected == 4, string.format("Should have 4 edges (2 per linked clip), got %d", #selected))

local found = { clip_v_out = false, clip_v_gap = false, clip_a_out = false, clip_a_gap = false }
for _, edge in ipairs(selected) do
    if edge.clip_id == "clip_v" and edge.edge_type == "out" then found.clip_v_out = true end
    if edge.clip_id == "clip_v" and edge.edge_type == "gap_after" then found.clip_v_gap = true end
    if edge.clip_id == "clip_a" and edge.edge_type == "out" then found.clip_a_out = true end
    if edge.clip_id == "clip_a" and edge.edge_type == "gap_after" then found.clip_a_gap = true end
    assert(edge.trim_type == "roll", string.format("Edge %s:%s should be roll", edge.clip_id, edge.edge_type))
end
assert(found.clip_v_out, "Missing clip_v out edge")
assert(found.clip_v_gap, "Missing clip_v gap_after edge")
assert(found.clip_a_out, "Missing clip_a out edge")
assert(found.clip_a_gap, "Missing clip_a gap_after edge")
print("✓ Roll with gap_after: both edges expanded to linked clips")

print("\n✅ test_select_edges_option_linked.lua passed")
