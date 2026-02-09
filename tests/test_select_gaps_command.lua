-- Test SelectGaps command with modifier semantics
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_select_gaps_command.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

command_manager.init("seq1", "proj1")

-- Mock timeline_state for testing
local mock_gaps = {}

timeline_state.get_selected_gaps = function() return mock_gaps end
timeline_state.set_gap_selection = function(gaps) mock_gaps = gaps or {} end

-- Test gaps
local gap_a = { track_id = "trk1", start_value = 0, duration = 100 }
local gap_b = { track_id = "trk1", start_value = 200, duration = 50 }

-- Test 1: Select gap without modifier - should replace selection
print("\n--- Test 1: SelectGaps without modifier ---")
mock_gaps = {}
local result = command_manager.execute("SelectGaps", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_gaps = { gap_a },
    modifiers = {},
})
assert(result.success, "SelectGaps should succeed")
assert(#mock_gaps == 1, "Should have 1 selected gap")
assert(mock_gaps[1].start_value == 0, "Should be gap_a")
print("✓ Without modifier: gap selected")

-- Test 2: Select different gap without modifier - should replace
print("\n--- Test 2: SelectGaps replace selection ---")
result = command_manager.execute("SelectGaps", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_gaps = { gap_b },
    modifiers = {},
})
assert(result.success, "SelectGaps should succeed")
assert(#mock_gaps == 1, "Should have 1 selected gap")
assert(mock_gaps[1].start_value == 200, "Should be gap_b")
print("✓ Replace: new gap replaces old")

-- Test 3: Cmd-click adds to selection
print("\n--- Test 3: SelectGaps with Cmd adds gap ---")
result = command_manager.execute("SelectGaps", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_gaps = { gap_a },
    modifiers = { command = true },
})
assert(result.success, "SelectGaps should succeed")
assert(#mock_gaps == 2, string.format("Should have 2 selected gaps, got %d", #mock_gaps))
print("✓ Cmd-click: gap added to selection")

-- Test 4: Cmd-click on selected gap removes it
print("\n--- Test 4: SelectGaps Cmd toggle removes ---")
result = command_manager.execute("SelectGaps", {
    project_id = "proj1",
    sequence_id = "seq1",
    target_gaps = { gap_a },
    modifiers = { command = true },
})
assert(result.success, "SelectGaps should succeed")
assert(#mock_gaps == 1, string.format("Should have 1 selected gap, got %d", #mock_gaps))
assert(mock_gaps[1].start_value == 200, "Should be gap_b remaining")
print("✓ Cmd-click on selected: gap removed")

print("\n✅ test_select_gaps_command.lua passed")
