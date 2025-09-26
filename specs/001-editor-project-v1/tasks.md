# Tasks: Video Editor M1 Foundation

**Input**: Design documents from `/Users/joe/Local/jve-spec-kit-claude/specs/001-editor-project-v1/`
**Prerequisites**: plan.md (required), research.md, data-model.md, contracts/, ui-layout-spec.md, quickstart.md

## Format: `[ID] [P?] Description`
- **[P]**: Can run in parallel (different files, no dependencies)
- Include exact file paths in descriptions

## Path Conventions
**Single project**: `src/`, `tests/` at repository root
Paths shown below assume single project structure from plan.md

## Phase 3.1: Setup & Infrastructure
- [ ] T001 Create project structure per implementation plan in src/ and tests/ directories
- [ ] T002 Initialize C++ project with Qt6, LuaJIT, and SQLite dependencies using CMake/qmake
- [ ] T003 [P] Configure testing framework with Qt Test and establish CI pipeline for constitutional compliance
- [ ] T004 [P] Set up SQLite schema initialization script with all core entities from data-model.md

## Phase 3.2: Contract Tests First (TDD) ⚠️ MUST COMPLETE BEFORE 3.3
**CRITICAL: These tests MUST be written and MUST FAIL before ANY implementation**

### Command API Contract Tests
- [ ] T005 [P] Contract test POST /commands/execute in tests/contract/test_command_execute.cpp
- [ ] T006 [P] Contract test POST /commands/undo in tests/contract/test_command_undo.cpp  
- [ ] T007 [P] Contract test POST /commands/redo in tests/contract/test_command_redo.cpp

### Project API Contract Tests
- [ ] T008 [P] Contract test POST /projects in tests/contract/test_project_create.cpp
- [ ] T009 [P] Contract test GET /projects/{id} in tests/contract/test_project_load.cpp
- [ ] T010 [P] Contract test POST /projects/{id}/sequences in tests/contract/test_sequence_create.cpp
- [ ] T011 [P] Contract test POST /projects/{id}/media in tests/contract/test_media_import.cpp

### Selection API Contract Tests  
- [ ] T012 [P] Contract test GET/POST /selection/clips in tests/contract/test_clip_selection.cpp
- [ ] T013 [P] Contract test GET/POST /selection/edges in tests/contract/test_edge_selection.cpp
- [ ] T014 [P] Contract test GET/POST /selection/properties in tests/contract/test_selection_properties.cpp

## Phase 3.3: Core Model Implementation (ONLY after contract tests are failing)

### Entity Models (All can run in parallel - different files)
- [ ] T015 [P] Project model class in src/core/models/project.cpp with SQLite persistence
- [ ] T016 [P] Sequence model class in src/core/models/sequence.cpp with frame rate validation  
- [ ] T017 [P] Track model class in src/core/models/track.cpp with video/audio type support
- [ ] T018 [P] Clip model class in src/core/models/clip.cpp with timeline positioning
- [ ] T019 [P] Media model class in src/core/models/media.cpp with metadata support
- [ ] T020 [P] Property model class in src/core/models/property.cpp with schema validation
- [ ] T021 [P] Command model class in src/core/models/command.cpp with deterministic replay
- [ ] T022 [P] Snapshot model class in src/core/models/snapshot.cpp with compression

### Model Relationships & Validation
- [ ] T023 SQLite schema implementation in src/core/persistence/schema.sql with foreign key constraints
- [ ] T024 Model validation framework in src/core/models/validation.cpp for all entity rules
- [ ] T025 Database migration system in src/core/persistence/migrations.cpp for schema evolution

## Phase 3.4: Command System Implementation

### Core Command Infrastructure  
- [ ] T026 Command dispatcher in src/core/commands/dispatcher.cpp implementing apply_command(cmd,args) → delta|error pattern
- [ ] T027 Command registry in src/core/commands/registry.cpp for all editing operations
- [ ] T028 Deterministic replay engine in src/core/commands/replay.cpp with hash verification

### Editing Commands (Sequential - depend on command infrastructure)
- [ ] T029 Create clip command in src/core/commands/create_clip.cpp
- [ ] T030 Delete clip command in src/core/commands/delete_clip.cpp  
- [ ] T031 Split clip command in src/core/commands/split_clip.cpp for blade operation
- [ ] T032 Ripple delete command in src/core/commands/ripple_delete.cpp with gap closure
- [ ] T033 Ripple trim command in src/core/commands/ripple_trim.cpp for head/tail editing
- [ ] T034 Roll edit command in src/core/commands/roll_edit.cpp for boundary adjustment

### Undo/Redo System
- [ ] T035 Undo/redo manager in src/core/commands/undo_manager.cpp with inverse delta chains
- [ ] T036 Per-property undo implementation in src/core/commands/property_undo.cpp for granular control

## Phase 3.5: UI Panel Implementation

### Core UI Framework
- [ ] T037 Main window with 4-panel layout in src/ui/main_window.cpp following ui-layout-spec.md proportions
- [ ] T038 Professional dark theme in src/ui/theme/dark_theme.cpp with color scheme from ui-layout-spec.md
- [ ] T039 [P] Custom widgets library in src/ui/widgets/ for tri-state controls and timeline elements

### Panel Implementation (Based on ui-layout-spec.md)
- [ ] T040 Project Browser panel in src/ui/panels/project_browser.cpp with dual-column layout and media list
- [ ] T041 Timeline panel in src/ui/panels/timeline.cpp with track headers, clip visualization, and playhead
- [ ] T042 Inspector panel in src/ui/panels/inspector.cpp with Properties/Metadata tabs and expandable sections
- [ ] T043 Viewer panels in src/ui/panels/viewer.cpp with timecode overlays (non-playing for M1)

### UI Integration & Selection
- [ ] T044 Selection manager in src/ui/selection/selection_manager.cpp supporting clips and edges
- [ ] T045 Multi-selection with tri-state controls in src/ui/selection/multi_selection.cpp
- [ ] T046 Inspector property binding in src/ui/panels/inspector_binding.cpp for real-time updates

## Phase 3.6: Keyboard Shortcuts & Interaction

### Input Handling
- [ ] T047 Keyboard shortcut system in src/ui/input/shortcuts.cpp with J,K,L and Cmd+B support
- [ ] T048 Edge selection with Cmd+click in src/ui/timeline/edge_selection.cpp following Avid/FCP7/Resolve patterns
- [ ] T049 Playhead control integration in src/ui/timeline/playhead_controller.cpp

## Phase 3.7: Persistence & File Operations

### SQLite Integration
- [ ] T050 Atomic save system in src/core/persistence/atomic_save.cpp for single .jve files
- [ ] T051 Project loading with state restoration in src/core/persistence/project_loader.cpp
- [ ] T052 Command log persistence in src/core/persistence/command_log.cpp with deterministic replay

### Lua Integration (Script-Forward Architecture)
- [ ] T053 LuaJIT runtime initialization in src/lua/runtime/lua_runtime.cpp
- [ ] T054 [P] Lua-to-C++ API bindings in src/lua/api/bindings.cpp for command system access
- [ ] T055 [P] Default panel behaviors in src/lua/scripts/panel_behaviors.lua for extensibility

## Phase 3.8: Integration Testing (Based on quickstart.md scenarios)

### Workflow Integration Tests
- [ ] T056 [P] Project creation and media import test in tests/integration/test_project_workflow.cpp
- [ ] T057 [P] Sequence creation and clip placement test in tests/integration/test_sequence_workflow.cpp  
- [ ] T058 [P] Clip selection and property editing test in tests/integration/test_inspector_workflow.cpp
- [ ] T059 [P] Editing commands workflow test in tests/integration/test_editing_workflow.cpp
- [ ] T060 [P] Save/load with state preservation test in tests/integration/test_persistence_workflow.cpp
- [ ] T061 [P] Keyboard shortcuts integration test in tests/integration/test_shortcuts_workflow.cpp
- [ ] T062 [P] Multi-selection and tri-state controls test in tests/integration/test_multiselection_workflow.cpp

## Phase 3.9: Polish & Validation

### Performance & Quality
- [ ] T063 Timeline rendering optimization for <16ms redraws in src/ui/timeline/renderer.cpp
- [ ] T064 Memory management and leak detection across all components
- [ ] T065 Error handling with structured logging per constitutional requirements
- [ ] T066 CLI debugging tools in src/cli/ for jve-validate, jve-dump, jve-replay commands

### Final Integration
- [ ] T067 End-to-end quickstart validation executing complete workflow from quickstart.md
- [ ] T068 Constitutional compliance verification (TDD, library-first, CLI tools)
- [ ] T069 Performance benchmarking and optimization for professional editor responsiveness

## Dependencies

**TDD Order**:
- Contract Tests (T005-T014) before ALL implementation
- Integration Tests (T056-T062) before final validation
- Implementation follows: Models → Commands → UI → Integration

**Core Dependencies**:
- T023-T025 (schema/validation) before T015-T022 (models)
- T015-T022 (models) before T026-T036 (commands)  
- T026-T036 (commands) before T040-T043 (UI panels)
- T037-T039 (UI framework) before T040-T043 (panels)
- T053-T055 (Lua) can run parallel with UI development

**UI Dependencies**:
- T037 (main window) before T040-T043 (panels)
- T044-T046 (selection) before T042 (inspector)
- T047-T049 (input) requires T041 (timeline)

## Parallel Execution Examples

```bash
# Setup phase - all parallel
T003 & T004 &

# Contract tests - all parallel  
T005 & T006 & T007 & T008 & T009 & T010 & T011 & T012 & T013 & T014 &

# Model implementation - all parallel
T015 & T016 & T017 & T018 & T019 & T020 & T021 & T022 &

# UI framework setup - parallel where noted
T038 & T039 &

# Integration tests - all parallel
T056 & T057 & T058 & T059 & T060 & T061 & T062 &
```

## Validation Checklist

**Task Completeness**:
- [x] All contracts (3 APIs) have corresponding tests (T005-T014)
- [x] All entities (8 models) have implementation tasks (T015-T022)
- [x] All quickstart scenarios (7 workflows) have integration tests (T056-T062)
- [x] UI panels match ui-layout-spec.md requirements (T040-T043)
- [x] Constitutional requirements covered (TDD, CLI tools, library-first)

**Dependency Validation**:
- [x] Tests come before implementation throughout
- [x] Models before commands before UI
- [x] Parallel tasks use different files with no dependencies
- [x] Each task specifies exact file path
- [x] Sequential dependencies clearly documented

**Professional Editor Requirements**:
- [x] 4-panel layout with professional proportions
- [x] Multi-selection with tri-state controls  
- [x] Edge selection with professional interaction patterns
- [x] Keyboard shortcuts (J,K,L, Cmd+B)
- [x] Deterministic command system with replay
- [x] Single-file (.jve) project persistence

---

**Total Tasks**: 69 numbered tasks
**Parallel Opportunities**: 32 tasks marked [P] for concurrent execution
**Estimated Timeline**: 4-6 weeks with proper parallelization
**Constitutional Compliance**: ✅ TDD, Library-First, CLI Tools, Template-Based