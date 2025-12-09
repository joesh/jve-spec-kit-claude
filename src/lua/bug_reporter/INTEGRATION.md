# Bug Reporter Integration Guide

This document shows how to integrate the bug reporter system with the main JVE application when ready.

## Current Status

✅ **Phase 0 Complete**: Core capture_manager module implemented and tested
- Ring buffer system works (5 min OR 200 gestures)
- Gesture, command, log, screenshot buffers functional
- Memory-efficient trimming
- Enable/disable flag
- Statistics tracking

⚠️ **Not Yet Integrated**: The bug reporter runs in isolation and doesn't affect the main application yet.

## Integration Steps (When Ready)

### Step 1: Initialize in main.lua

Add one line to start the capture system:

```lua
-- In main.lua, after core systems initialized
local bug_reporter = require("bug_reporter.capture_manager")
bug_reporter:init()
```

### Step 2: Log Commands in command_manager.lua

Add one function call after command executes:

```lua
-- In command_manager.lua execute() function
function CommandManager:execute(command_name, parameters)
    -- ... existing execute logic ...

    local success, result = pcall(executor, parameters)

    -- NEW: Log to bug reporter
    local bug_reporter = require("bug_reporter.capture_manager")
    bug_reporter:log_command(command_name, parameters, result, nil)

    return result
end
```

### Step 3: Log Messages (Optional Enhancement)

Intercept print/warn/error calls:

```lua
-- In main.lua or logging module
local bug_reporter = require("bug_reporter.capture_manager")
local original_print = print

function print(...)
    original_print(...)
    local message = table.concat({...}, " ")
    bug_reporter:log_message("info", message)
end
```

### Step 4: Screenshot Timer (Phase 1)

Will need Qt binding and timer - not yet implemented:

```lua
-- In main.lua, after Qt window created
local timer = qt_create_timer({
    interval_ms = 1000,
    repeat_mode = true,
    callback = function()
        require("bug_reporter.capture_manager"):capture_screenshot()
    end
})
timer:start()
```

### Step 5: Gesture Logging (Phase 1)

Will need C++ event filter - not yet implemented:

```cpp
// In main.cpp or similar
GestureLogger* gesture_logger = new GestureLogger();
qApp->installEventFilter(gesture_logger);
```

## Feature Flag (Recommended)

Use an environment variable or command-line flag to enable/disable:

```lua
-- In main.lua
local ENABLE_BUG_REPORTER = os.getenv("JVE_BUG_REPORTER") == "1"

if ENABLE_BUG_REPORTER then
    local bug_reporter = require("bug_reporter.capture_manager")
    bug_reporter:init()
end
```

Then run:
```bash
# Normal mode (bug reporter disabled)
./jve

# With bug reporter enabled
JVE_BUG_REPORTER=1 ./jve
```

## Testing Integration

Once integrated, verify it works:

```bash
# 1. Enable bug reporter
JVE_BUG_REPORTER=1 ./jve

# 2. Perform some actions in JVE (edit clips, etc.)

# 3. Check capture stats via Lua console
> local br = require("bug_reporter.capture_manager")
> local stats = br:get_stats()
> print(stats.gesture_count, stats.command_count)
```

## Next Steps (Phase 1)

1. Implement screenshot capture (Qt binding)
2. Implement gesture logging (C++ event filter)
3. Add screenshot timer
4. Test memory usage under real workload
5. Add preferences UI

## Notes

- The bug reporter is designed to be completely isolated
- It observes the application without modifying behavior
- If it crashes or has bugs, it won't affect the editor
- Can be disabled via feature flag at any time
