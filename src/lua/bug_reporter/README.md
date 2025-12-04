# Bug Reporter System

**Status**: Phase 0 Complete (Foundation)
**Created**: 2025-12-03
**Implementation**: Mostly Lua, minimal C++ bindings needed

## Overview

Continuous capture system for automatic bug reporting and regression testing. Captures gestures, commands, logs, and screenshots in memory with minimal overhead.

## What's Implemented (Phase 0)

### ✅ capture_manager.lua
Core ring buffer system with:
- **Gesture logging**: Stores last 200 gestures OR 5 minutes
- **Command logging**: Records all command executions with parameters and results
- **Log message capture**: Captures info/warning/error messages
- **Screenshot buffer**: Framework for screenshot storage (Qt binding pending)
- **Memory-efficient trimming**: Automatic cleanup based on time and count limits
- **Enable/disable flag**: User can turn off capture via preferences
- **Statistics tracking**: Real-time memory usage and buffer stats

### ✅ Test Suite
Comprehensive test coverage (27 tests, all passing):
- Ring buffer operations
- Time-based trimming
- Count-based limiting
- Enable/disable functionality
- Memory estimation
- Statistics reporting

### ✅ Integration Guide
Clear documentation showing how to wire into main application (3 integration points).

## Directory Structure

```
src/lua/bug_reporter/
  ├── capture_manager.lua       # Core ring buffer system (DONE)
  ├── INTEGRATION.md             # Integration guide (DONE)
  ├── README.md                  # This file
  └── [Phase 1+ modules here]

tests/
  └── test_capture_manager.lua   # Test suite (27/27 passing)
```

## Memory Usage

Current implementation: **~30MB** for full 5-minute buffer
- 200 gestures × 200 bytes = ~40KB
- 100 commands × 500 bytes = ~50KB
- 500 log messages × 150 bytes = ~75KB
- 300 screenshots × 100KB = ~30MB (dominant factor)

## Next Steps (Phase 1)

### Required C++ Bindings

**1. Gesture Logging (C++)**
```cpp
// gesture_logger.h
class GestureLogger : public QObject {
    Q_OBJECT
public:
    bool eventFilter(QObject* obj, QEvent* event) override;
};
```

**2. Screenshot Capture (Qt binding)**
```cpp
// In qt_bindings_testing.cpp
static int lua_grab_window(lua_State* L) {
    QWidget* widget = ...; // Get widget from Lua
    QPixmap pixmap = widget->grab();
    // Return QPixmap userdata to Lua
}
```

**3. Timer Creation (Qt binding)**
```cpp
static int lua_create_timer(lua_State* L) {
    int interval_ms = lua_tointeger(L, 1);
    // Create QTimer, store callback in registry
    // Return timer userdata to Lua
}
```

### Lua Modules to Create

**1. JSON Test Export** (Phase 2)
```lua
-- bug_reporter/json_exporter.lua
function export_capture_to_json(capture_data, output_dir)
    -- Generate JSON test format
    -- Save screenshots to disk
    -- Return path to JSON file
end
```

**2. Slideshow Generator** (Phase 3)
```lua
-- bug_reporter/slideshow_generator.lua
function generate_slideshow_video(screenshot_dir)
    -- Call ffmpeg to create MP4
    -- Return video path
end
```

**3. Test Runner** (Phase 4)
```lua
-- bug_reporter/test_runner_mocked.lua
function run_test(json_path)
    -- Load test JSON
    -- Execute commands
    -- Validate results
end
```

## Usage (When Integrated)

### Enable Capture
```bash
# Via environment variable
JVE_BUG_REPORTER=1 ./jve

# Or via command line flag (to be implemented)
./jve --enable-bug-reporter
```

### Check Stats
```lua
local br = require("bug_reporter.capture_manager")
local stats = br:get_stats()
print("Gestures:", stats.gesture_count)
print("Commands:", stats.command_count)
print("Memory:", stats.memory_estimate_mb, "MB")
```

### Manual Export (Phase 2+)
```lua
local br = require("bug_reporter.capture_manager")
local json_path = br:export_capture("user_submitted")
print("Capture saved to:", json_path)
```

## Design Principles

1. **Isolated**: Bug reporter doesn't modify editor behavior
2. **Optional**: Can be disabled via feature flag
3. **Efficient**: Ring buffers with automatic trimming
4. **Observable**: Real-time statistics for monitoring
5. **Testable**: Comprehensive test suite (all Lua, no Qt required)
6. **Lua-first**: Minimize C++ code, maximize flexibility

## Testing

Run the test suite:
```bash
cd tests
lua test_capture_manager.lua
```

Expected output: `✓ All tests passed! (27/27)`

## Performance Impact

**Target**: <1% CPU overhead, <50MB memory

**Current (Phase 0 - partial):**
- Memory: ~6KB (no screenshots yet)
- CPU: Negligible (no event filter or timer yet)

**Expected (Phase 1 - full system):**
- Memory: ~30MB (5 min of screenshots)
- CPU: ~0.5% (event filter + screenshot capture)

## Related Documents

- **Specification**: `TESTING-SYSTEM-SPECIFICATION.md` (complete design)
- **Implementation Plan**: `TESTING-SYSTEM-IMPLEMENTATION-PLAN.md` (8-phase roadmap)
- **Integration Guide**: `INTEGRATION.md` (how to wire into main app)

## Questions?

This is a self-contained module. Feel free to:
- Continue editor development without worrying about conflicts
- Test the capture_manager in isolation
- Integrate when ready (3 simple integration points)
- Enable/disable via feature flag anytime
