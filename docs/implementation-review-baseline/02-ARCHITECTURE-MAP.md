# 02-ARCHITECTURE-MAP

## Layering (Enforced by ENGINEERING.md §1.10, §2.18)

```
┌─────────────────────────────────────────────────────────┐
│ Lua Application Layer                                   │
│ - Business logic, state management, commands            │
│ - src/lua/core/, src/lua/models/, src/lua/ui/          │
│ - NEVER calls Qt directly                               │
└───────────────┬─────────────────────────────────────────┘
                │
                ↓ (Lua → C FFI calls only)
┌─────────────────────────────────────────────────────────┐
│ FFI Bindings Layer (C++)                                │
│ - Pure interface to Qt6                                 │
│ - Parameter validation ONLY (no business logic)         │
│ - src/qt_bindings.cpp (1300+ LOC)                       │
└───────────────┬─────────────────────────────────────────┘
                │
                ↓ (Direct Qt API calls)
┌─────────────────────────────────────────────────────────┐
│ Qt6 Framework                                           │
│ - Widgets, layouts, signals/slots                       │
│ - Event loop (QApplication::exec)                       │
└─────────────────────────────────────────────────────────┘
```

**Critical Rule**: Lua NEVER bypasses FFI to call Qt. FFI NEVER contains business logic.

## Module Boundaries

### Core Domain (src/lua/core/)
**Responsibility**: Timeline editing primitives, no UI dependencies

Key modules:
- `command_manager.lua` - Command execution orchestration (1474 LOC)
- `command_registry.lua` - Command type registration
- `command_history.lua` - Undo/redo stack management (342 LOC)
- `command_state.lua` - Selection/playhead snapshots
- `database.lua` - SQLite wrapper
- `rational.lua` - Timebase arithmetic (380 LOC)
- `clip_mutator.lua` - Low-level clip operations
- `timeline_constraints.lua` - Collision detection

Dependencies: ONLY other core modules + FFI + SQLite

### Ripple Subsystem (src/lua/core/ripple/)
**Responsibility**: Batch timeline shifts with gap handling

Pipeline:
```
batch/pipeline.lua (orchestrator)
  → batch/prepare.lua (snapshot edges, validate delta)
  → batch/context.lua (operation state)
  → edge_info.lua (edge type classification)
  → track_index.lua (spatial queries)
  → undo_hydrator.lua (reverse operations)
```

**Input**: `BatchRippleEdit` command with edge selection
**Output**: Planned mutations (shift/trim/delete) + undo data

Key algorithm (pipeline.lua):
1. Resolve sequence timebase
2. Snapshot edge infos
3. Materialize gap edges (implied boundaries)
4. Assign lead edge (determines ripple direction)
5. Compute constraints (media limits, collisions)
6. Process edge trims
7. Compute downstream shifts
8. Finalize mutations

Dependencies: Core primitives only

### Command Implementations (src/lua/core/commands/)
**Responsibility**: 45 command types (Insert, Delete, Split, etc.)

Pattern:
```lua
local M = {}
function M.execute(cmd, db)
  -- Mutate database
  -- Return mutations for undo
end
function M.undo(cmd, db, mutations)
  -- Reverse mutations
end
function M.redo(cmd, db)
  -- Replay forward
end
return M
```

Examples:
- `add_clip.lua` - Insert timeline clip
- `ripple_edit.lua` - Single-edge ripple
- `batch_ripple_edit.lua` - Multi-edge ripple (calls ripple subsystem)
- `split_clip.lua` - Blade tool
- `delete_clip.lua` - Remove with optional ripple

Dependencies: Core + specific helpers (e.g., ripple pipeline)

### Data Models (src/lua/models/)
**Responsibility**: Database schema accessors

Modules:
- `project.lua` - Top-level project CRUD
- `sequence.lua` - Timeline operations
- `track.lua` - Track CRUD
- `clip.lua` - Clip queries/updates
- `media.lua` - Media file management

Pattern: Thin wrappers over SQLite prepared statements. No complex logic.

Dependencies: Core database module only

### Timeline UI (src/lua/ui/timeline/)
**Responsibility**: Timeline visualization and interaction

State Management:
```
timeline_state.lua (facade)
  ├── state/timeline_core_state.lua - DB persistence
  ├── state/viewport_state.lua - Pan/zoom
  ├── state/selection_state.lua - Clip/edge/gap selection
  ├── state/clip_state.lua - Clip cache
  └── state/track_state.lua - Track metadata
```

Rendering:
```
timeline_view.lua (main widget)
  ├── view/timeline_view_renderer.lua - Paint loop
  ├── view/timeline_view_input.lua - Mouse/keyboard
  └── view/timeline_view_drag_handler.lua - Drag operations
```

Edge Tools:
- `edge_picker.lua` - Hit testing
- `edge_drag_renderer.lua` - Preview during drag
- `roll_detector.lua` - Roll vs ripple disambiguation

Dependencies: Core + UI helpers + FFI

### Project Browser (src/lua/ui/project_browser/)
**Responsibility**: Media pool and bin management

Modules:
- `project_browser.lua` - Tree view
- `browser_state.lua` - Selection state
- `keymap.lua` - Keyboard shortcuts

Dependencies: Models + UI helpers + FFI

### UI Infrastructure (src/lua/ui/)
**Responsibility**: Shared UI primitives

Key modules:
- `layout.lua` - Main window creation (entry point)
- `panel_manager.lua` - Floating panel system
- `main_window.lua` - Menu bar setup
- `focus_manager.lua` - Keyboard routing
- `selection_hub.lua` - Cross-panel selection

Dependencies: FFI

### Importers (src/lua/importers/)
**Responsibility**: External format parsing

Modules:
- `fcp7_xml_importer.lua` - Final Cut Pro 7 XML (28k LOC test)
- `drp_importer.lua` - DaVinci Resolve .drp SQLite
- `resolve_database_importer.lua` - Direct DB access

Pattern: Parse → validate → batch commands → commit

Dependencies: Core + models + xml2/json libraries

### Bug Reporter (src/lua/bug_reporter/)
**Responsibility**: Test case generation from user gestures

Flow:
```
gesture_logger.cpp (C++ captures input)
  → capture_manager.lua (orchestrates)
    → json_exporter.lua (serializes state)
      → test_runner_gui.lua (replay + validation)
        → github_issue_creator.lua (bug submission)
```

Dependencies: Core + UI + external APIs

## Data Flow

### Edit Lifecycle
```
User gesture (mouse/keyboard)
  ↓
UI event handler (timeline_view_input.lua)
  ↓
Command creation (command_manager.execute)
  ↓
Command implementation (commands/*.lua)
  ↓
SQLite mutation (clips/tracks/sequences tables)
  ↓
Command persistence (commands table)
  ↓
State reload (timeline_core_state.reload_clips)
  ↓
UI update (timeline_view_renderer.paint)
```

### Undo/Redo Flow
```
Undo request (Cmd+Z)
  ↓
command_history.undo()
  ↓
Load command from DB (commands table)
  ↓
Execute command.undo(mutations)
  ↓
Restore prior DB state
  ↓
Reload UI state
```

### Ripple Edit Flow
```
Edge drag gesture
  ↓
edge_picker.lua (identify edges)
  ↓
BatchRippleEdit command
  ↓
ripple/batch/pipeline.lua
  ├── Snapshot edge states
  ├── Materialize gap edges
  ├── Compute constraints
  ├── Process trims
  └── Compute shifts
  ↓
Planned mutations (shift/trim/delete)
  ↓
Apply mutations (clip_mutator.lua)
  ↓
Reload clips
```

## Key Design Patterns

### Event Sourcing
All state changes are commands in `commands` table:
```sql
CREATE TABLE commands (
    id TEXT PRIMARY KEY,
    sequence_number INTEGER UNIQUE,
    command_type TEXT,        -- "AddClip", "RippleEdit", etc.
    command_args TEXT,        -- JSON parameters
    parent_sequence_number,   -- For undo tree
    timestamp INTEGER
);
```

Replay: Load commands in sequence order, re-execute.

### Command Pattern
```lua
Command = {
  type = "AddClip",
  project_id = "...",
  sequence_id = "...",
  parameters = { track_id, media_id, timeline_start, ... }
}

function command:execute() end
function command:undo(mutations) end
function command:redo() end
```

### Observer Pattern
State modules emit change notifications:
```lua
timeline_state.add_listener(function(event)
  if event.type == "clips_changed" then
    timeline_view:repaint()
  end
end)
```

### Rational Timebase
No floats, only integers:
```lua
{frames=100, fps_numerator=24000, fps_denominator=1001}
-- Represents 100 frames @ 23.976 fps
```

Comparison:
```lua
function rational:to_seconds()
  return frames * fps_denominator / fps_numerator
end
```

Rescaling:
```lua
function rational:rescale(new_num, new_den)
  local new_frames = math.floor(
    self.frames * new_num * self.fps_denominator /
    (self.fps_numerator * new_den) + 0.5
  )
  return Rational.new(new_frames, new_num, new_den)
end
```

### Gap Materialization
Timeline operations treat gaps as first-class edges:
- Explicit gaps: User-selected empty regions
- Implied gaps: Boundaries between clips
- Temporary gaps: Created during multi-clip shifts

Ripple algorithm converts all gap types to edge infos for uniform processing.

## Performance Critical Paths

### Timeline Rendering
```
timeline_view_renderer.paint()
  → clip_state.get_all_in_range(start, end)  # Spatial query
    → SQLite with index: idx_clips_track_start
  → Paint loop (iterate clips)
    → timeline_renderer.cpp (C++ QPainter)
```

Optimization: Clip cache invalidated only on mutations.

### Edge Picking
```
edge_picker.pick(x, y)
  → clip_state.get_clips_at_pixel(x)
  → Iterate clip boundaries (±5px tolerance)
  → Return edge_info {clip_id, edge_type, track_id}
```

Optimization: Spatial index in clip_state.

### Command Replay
```
command_manager.replay_from(sequence_number)
  → Load commands WHERE sequence_number >= N
  → For each: command:execute()
```

Optimization: Batch DB writes, single reload at end.

## Extension Points

### Adding Commands
1. Create `src/lua/core/commands/my_command.lua`
2. Implement `execute`, `undo`, `redo`
3. Register in `command_registry.lua`
4. Add to menu/shortcut in `main_window.lua`

### Adding Importers
1. Create `src/lua/importers/my_format_importer.lua`
2. Parse format → generate commands
3. Execute commands in batch
4. Wire to menu in `main_window.lua`

### Adding UI Panels
1. Create `src/lua/ui/my_panel.lua`
2. Implement `create_panel()` returning Qt widget
3. Register in `panel_manager.lua`
4. Add to layout in `layout.lua`

## Testing Strategy
- **Unit tests**: Mock database, verify command logic
- **Integration tests**: Real SQLite, verify end-to-end flow
- **Regression tests**: Captured gestures replayed, validate final state
- **Fixtures**: Real media files, FCP7 XMLs, DRP files

Test pattern:
```lua
local test = require("tests/test_env")
test.init()  -- In-memory SQLite

-- Setup
local cmd = Command.create("AddClip", project_id)
cmd:set_parameter("track_id", track_id)

-- Execute
local ok, err = command_manager.execute(cmd)

-- Verify
assert(ok, err)
local clips = database.get_clips(sequence_id)
assert(#clips == 1)
```
