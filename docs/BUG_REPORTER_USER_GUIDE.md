# Bug Reporter User Guide

**Complete workflow from bug capture to regression test**

## Overview

The JVE bug reporter automatically captures the last 5 minutes of user interaction (gestures, commands, screenshots) and exports it as a JSON test that can be replayed to reproduce bugs exactly.

## Table of Contents

1. [Capturing Bugs](#capturing-bugs)
2. [Reviewing Captures](#reviewing-captures)
3. [Converting to Regression Tests](#converting-to-regression-tests)
4. [Replaying Tests](#replaying-tests)
5. [CI Integration](#ci-integration)

---

## Capturing Bugs

### Automatic Capture (On Errors)

When a Lua error occurs, the bug reporter automatically:
1. ✅ Captures the last 5 minutes of activity
2. ✅ Saves to `tests/captures/capture-TIMESTAMP/`
3. ✅ Prints the capture path to console
4. 💡 Reminds you to press F12 to review

**Console Output:**
```
❌ FATAL ERROR: attempt to index nil value
stack traceback:
    src/lua/core/command_manager.lua:123: in function 'execute'
    ...
📸 Bug report auto-captured: tests/captures/capture-1733430276/capture.json
💡 Press F12 to review and submit
```

### Manual Capture (F12)

Press **F12** anytime to manually capture:
1. 🎬 Captures last 5 minutes (or less if app just started)
2. 📋 Shows submission dialog (if Qt bindings available)
3. 💾 Exports to `tests/captures/capture-TIMESTAMP/`

**Use Cases:**
- Something looks wrong but no error occurred
- Demonstrating a workflow for a teammate
- Creating a test case for a feature
- Reproducing an intermittent issue

---

## Reviewing Captures

### Directory Structure

Each capture creates a timestamped directory:
```
tests/captures/capture-1733430276/
├── capture.json          # Complete test data (THIS IS THE TEST)
├── screenshot-0001.png   # Screenshots every 1 second
├── screenshot-0002.png
├── screenshot-0003.png
└── ...
```

### capture.json Format

The JSON file contains everything needed to replay the bug:

```json
{
  "metadata": {
    "title": "User pressed F12 - Manual bug report capture",
    "description": "Captured after timeline corruption",
    "timestamp": 1733430276000,
    "duration_ms": 12500,
    "jve_version": "0.1.0",
    "platform": "macOS",
    "database_snapshot_before": "/tmp/snapshot-before.db",
    "database_snapshot_after": "/tmp/snapshot-after.db"
  },

  "gesture_log": [
    {
      "id": "g1",
      "timestamp_ms": 0,
      "gesture": {
        "type": "mouse_press",
        "screen_x": 500,
        "screen_y": 300,
        "button": "left",
        "modifiers": []
      }
    },
    {
      "id": "g2",
      "timestamp_ms": 150,
      "gesture": {
        "type": "mouse_move",
        "screen_x": 520,
        "screen_y": 310,
        "buttons": ["left"],
        "modifiers": []
      }
    }
  ],

  "command_log": [
    {
      "id": "c1",
      "timestamp_ms": 1250,
      "command": "Insert",
      "parameters": {
        "media_id": "media1",
        "track_id": "video1",
        "insert_time": 5000,
        "duration": 2000
      },
      "result": {
        "success": true
      },
      "triggered_by_gesture": "g45"
    }
  ],

  "log_output": [
    {
      "timestamp_ms": 1260,
      "level": "error",
      "message": "Assertion failed: clip.start_time >= 0"
    }
  ]
}
```

**Key Fields:**
- `gesture_log`: Every mouse/keyboard event with precise timing
- `command_log`: Every command executed (Insert, Delete, Undo, etc.)
- `log_output`: All console output (errors, warnings, info)
- `database_snapshot_before/after`: SQLite database state before/after

---

## Converting to Regression Tests

### Step 1: Rename the Capture

Give it a descriptive name:
```bash
cd tests/captures

# Rename from timestamp to descriptive name
mv capture-1733430276 repro-timeline-corruption-after-undo

# Or just rename the JSON file
mv capture-1733430276/capture.json ../test_timeline_corruption.json
```

### Step 2: Create Test Runner

Create a Lua test that loads and replays the capture:

**tests/test_timeline_corruption.lua:**
```lua
#!/usr/bin/env luajit

require("test_env")

local json_test_loader = require("bug_reporter.json_test_loader")
local gesture_replay = require("bug_reporter.gesture_replay_engine")
local differential_validator = require("bug_reporter.differential_validator")

-- Load the captured bug reproduction
local test_data, err = json_test_loader.load("test_timeline_corruption.json")
assert(test_data, "Failed to load test: " .. tostring(err))

print("🎬 Replaying: " .. test_data.metadata.title)

-- Setup database from snapshot (if available)
if test_data.metadata.database_snapshot_before then
    local database = require("core.database")
    database.restore_from_snapshot(test_data.metadata.database_snapshot_before)
end

-- Replay gestures at 10x speed
local replay_ok, replay_err = gesture_replay.replay_gestures(
    test_data.gesture_log,
    {
        speed_multiplier = 10.0,  -- 10x faster for tests
        max_delay_ms = 1000       -- Cap delays at 1 second
    }
)

assert(replay_ok, "Gesture replay failed: " .. tostring(replay_err))

-- Get actual command log from replay
local actual_commands = get_executed_commands()  -- From test environment

-- Validate results match original capture
local validation = differential_validator.validate(test_data, {
    command_log = actual_commands,
    log_output = get_log_output()
})

if not validation.overall_success then
    print("❌ REGRESSION: Bug behavior changed!")
    print(differential_validator.generate_diff_report(validation))
    os.exit(1)
end

print("✅ Bug reproduces correctly (test passing)")
```

### Step 3: Simplify (Optional)

Once you understand the bug, create a minimal reproduction:

**tests/test_timeline_corruption_minimal.lua:**
```lua
#!/usr/bin/env luajit

-- Minimal reproduction extracted from capture-1733430276
-- Bug: Timeline corruption after Insert→Undo→Insert sequence

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

-- Setup
assert(database.init(":memory:"))

-- Create test data
setup_test_project()
setup_test_sequence()

command_manager.init(database.get_connection(), "default_sequence", "default_project")

-- Reproduce the exact sequence that triggered the bug
local insert1 = Command.create("Insert", "default_project")
insert1:set_parameter("media_id", "media1")
insert1:set_parameter("track_id", "video1")
insert1:set_parameter("insert_time", 5000)
insert1:set_parameter("duration", 2000)

command_manager.execute(insert1)
command_manager.undo()
command_manager.execute(insert1)  -- Second insert triggers corruption

-- Assert the bug is fixed (or still exists)
local clips = database.load_clips("default_sequence")
assert(#clips == 1, "Expected 1 clip, got " .. #clips .. " (bug still present)")

print("✅ Timeline corruption bug fixed")
```

---

## Replaying Tests

### Single Test

```bash
cd tests
./test_timeline_corruption.lua
```

### All Regression Tests

```bash
cd tests
./run_all_tests.sh  # Includes regression tests
```

### Replay Specific Capture

```bash
cd tests

# Load and replay any capture.json
luajit -e '
local loader = require("bug_reporter.json_test_loader")
local replay = require("bug_reporter.gesture_replay_engine")
local test = loader.load("captures/repro-undo-bug/capture.json")
replay.replay_gestures(test.gesture_log)
'
```

### Debugging Failed Replays

If a replay fails, check:

1. **Database state**: Did the snapshot restore correctly?
2. **Timing**: Try slower replay (speed_multiplier = 1.0)
3. **Screenshots**: Compare replay screenshots to originals
4. **Logs**: Check console output for differences

---

## CI Integration

### GitHub Actions

Add bug regression tests to CI:

**.github/workflows/bug-regressions.yml:**
```yaml
name: Bug Regression Tests

on: [push, pull_request]

jobs:
  test-regressions:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install LuaJIT
        run: sudo apt-get install -y luajit

      - name: Install dependencies
        run: luarocks install dkjson

      - name: Run bug regression tests
        run: |
          cd tests
          for test in test_bug_*.lua; do
            echo "Running $test..."
            ./"$test" || echo "::warning::Bug not yet fixed: $test"
          done

      - name: Replay all captures
        run: |
          cd tests/captures
          for capture in */capture.json; do
            echo "Replaying $capture..."
            ../../replay_capture.lua "$capture"
          done
```

### Test Status Tracking

Use exit codes to distinguish:
- **0**: Bug fixed (test passes)
- **1**: Bug still exists (expected failure)
- **2**: Regression (test now fails differently)

```lua
-- At end of test
if validation.overall_success then
    print("✅ Bug reproduces as expected")
    os.exit(1)  -- Bug not fixed yet
else
    if bug_is_fixed(validation) then
        print("🎉 Bug is fixed!")
        os.exit(0)  -- Success!
    else
        print("❌ REGRESSION: Different failure")
        os.exit(2)  -- Regression detected
    end
end
```

---

## File Organization

Recommended structure:
```
tests/
├── test_core_features.lua           # Core functionality tests
├── test_edge_cases.lua              # Edge case handling
├── test_bug_timeline_corruption.lua # Bug regression test
├── test_bug_undo_crash.lua          # Another regression test
├── captures/
│   ├── repro-timeline-corruption/   # Full capture (kept for reference)
│   │   ├── capture.json
│   │   └── screenshots/
│   └── repro-undo-crash/            # Another capture
│       ├── capture.json
│       └── screenshots/
└── run_all_tests.sh                 # Master test runner
```

---

## Best Practices

### DO ✅

- **Rename captures** with descriptive names immediately
- **Add comments** to test files explaining what bug they reproduce
- **Keep original captures** in `captures/` directory for reference
- **Create minimal reproductions** once you understand the bug
- **Run regression tests** before every commit
- **Archive fixed bugs** (move to `captures/fixed/` subdirectory)

### DON'T ❌

- **Don't delete captures** - they're valuable historical record
- **Don't modify capture.json** - it's a verbatim recording
- **Don't skip validation** - always use differential_validator
- **Don't rely on timing alone** - validate command sequence matches

---

## Troubleshooting

### "Gesture replay failed"

**Cause**: Qt event system not responding
**Fix**: Add `process_events()` calls between gestures

### "Command sequence mismatch"

**Cause**: Replay produced different commands than original
**Fix**: Check database snapshot restored correctly

### "Screenshots don't match"

**Cause**: Timing differences or window size changes
**Fix**: This is normal - screenshots are for human review only

### "Test passes but bug still exists"

**Cause**: Test validates reproduction, not fix
**Fix**: Add assertions for expected correct behavior

---

## Advanced Usage

### Custom Validation

```lua
-- Custom validation logic
local function validate_bug_is_fixed(test_data, actual_result)
    -- Check specific fix criteria
    if actual_result.clips_count == 1 then
        return true, "Bug fixed: Correct clip count"
    else
        return false, "Bug still present: Found " .. actual_result.clips_count .. " clips"
    end
end
```

### Parametric Tests

```lua
-- Run same bug with different parameters
for _, duration in ipairs({1000, 2000, 5000}) do
    print("Testing with duration=" .. duration)
    test_data.command_log[1].parameters.duration = duration
    replay_and_validate(test_data)
end
```

### Differential Debugging

```lua
-- Compare two versions of the bug
local capture_v1 = json_test_loader.load("bug_v1.json")
local capture_v2 = json_test_loader.load("bug_v2.json")

local diff = differential_validator.compare(capture_v1, capture_v2)
print("Differences between v1 and v2:")
print(diff.report)
```

---

## Summary

1. **Bug occurs** → Automatic capture or press F12
2. **Review** → Check `tests/captures/capture-*/capture.json`
3. **Rename** → `mv capture-123 repro-descriptive-name`
4. **Create test** → Load JSON, replay, validate
5. **Run test** → Verify reproduction works
6. **Fix bug** → Modify code
7. **Verify fix** → Test should now pass
8. **Keep test** → Prevents regressions

The bug reporter turns every bug into an executable test automatically! 🎉
