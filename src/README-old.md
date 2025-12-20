# JVE Editor Source Code Structure

## Architecture Overview
This project implements a hackable, script-forward video editor using C++/Qt6 + Lua architecture.

## Directory Structure

### C++ Core (`src/*.{cpp,h}`)
Minimal C++ layer for Qt integration and performance-critical operations:
- **main.cpp**: Application entry point
- **qt_bindings.{cpp,h}**: Qt widget bindings exposed to Lua
- **simple_lua_engine.{cpp,h}**: LuaJIT runtime initialization
- **timeline_renderer.{cpp,h}**: High-performance timeline rendering widget
- **resource_paths.{cpp,h}**: Asset path resolution

### Bug Reporter (`src/bug_reporter/`)
Standalone module for capturing reproduction cases:
- **gesture_logger.cpp**: User interaction recording
- **qt_bindings_bug_reporter.cpp**: Bug reporting UI bindings

### Lua Application Layer (`src/lua/`)
All application logic, UI layouts, and business rules in Lua:
- **core/**: Command system, database access, keyboard shortcuts, clipboard
- **models/**: Entity models (Project, Sequence, Clip, Track, Media)
- **ui/**: Panel layouts, inspector, project browser, timeline view
- **importers/**: FCP7 XML, Resolve .drp, media file import
- **media/**: FFprobe integration for media metadata
- **qt_bindings/**: Widget creation and manipulation bindings
- **bug_reporter/**: Bug capture manager integration

## Testing Structure (`tests/`)
- **contract/**: API contract tests (TDD first)
- **integration/**: End-to-end workflow tests
- **unit/**: C++ component tests (Qt bindings, timeline renderer)
- **test_*.lua**: 220+ Lua tests for command system, timeline operations, importers

## Design Principles
- **Library-First**: Each component is a testable, standalone library
- **Script-Forward**: Lua for logic/policy, C++ for performance
- **Test-First**: All tests written before implementation (TDD)
- **Single-File Projects**: .jve files are self-contained with no sidecars