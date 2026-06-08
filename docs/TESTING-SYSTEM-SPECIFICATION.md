# Testing System Specification - JVE

**Status**: Specification (Not Implemented)
**Created**: 2025-12-03
**Last Updated**: 2025-12-03
**Purpose**: Define dual test environments and automatic bug capture for JVE

## Overview

JVE requires two test environments with a unified JSON test format:

1. **Fast Mocked Tests** - Run in milliseconds without Qt/GUI, using stub implementations
2. **GUI Integration Tests** - Run on actual JVE application with pixel-perfect gesture replay

Both environments execute the same JSON test specifications, enabling:
- Rapid iteration during development (mocked)
- End-to-end validation before release (GUI)
- Automatic bug capture from production failures
- User-initiated anomaly reports

## Core Design Decisions

**Capture Strategy:**
- ✅ Screenshot every 1 second (ring buffer: last 5 minutes OR 200 gestures, whichever limit hits first)
- ✅ Full window screenshots (captures everything including dialogs)
- ✅ Raw pixel coordinates for gestures (no widget path resolution needed at capture time)
- ✅ User can enable/disable automatic capture in preferences
- ✅ Always capture: gesture log + command log + log output + database snapshots

**Widget Identification:**
- ✅ Not needed for capture - gestures are just raw pixels
- ✅ Lazy resolution via command correlation at replay time
- ✅ Commands know what they operated on - correlation tells us "gesture at (x,y) modified clip C"

**Video Generation:**
- ✅ Construct slideshow MP4 from screenshots at 2x speed (5 min capture → 2.5 min video)
- ✅ User reviews video before submission

**YouTube Integration:**
- ✅ OAuth flow - user authenticates with their own YouTube account
- ✅ Upload as unlisted video
- ✅ Distributed quota (not single JVE account)

**Validation Strategy:**
- ✅ Differential testing - compare original capture vs replay
- ✅ Command sequence must match (timestamps correlated)
- ✅ Command results must match (success/failure/error messages)
- ✅ Database state must match (before/after snapshots)
- ✅ Log output must match (warnings/errors)

**User Control:**
- ✅ Menu command: "Capture Bug Report" (user-bindable via keyboard customization)
- ✅ Show complete submission package before upload
- ✅ Trust user to redact sensitive information
- ✅ User can save locally or submit to GitHub

**Dialog UI:**
- ⚠️ TBD - requires implementation and user review

## Architecture Principles

Following ENGINEERING.md rules:
- **Event sourcing first**: Tests replay command sequences, not direct state manipulation
- **No fallbacks**: Tests either pass or fail explicitly - no silent degradation
- **Frame-accurate**: All timing operations use frame-aligned values
- **Evidence-based**: Tests verify observable outcomes (database state, log output, command correlation)
- **Differential testing**: Compare replay vs original, no manual assertions needed

## JSON Test Format

### Schema v1.0 - Capture Format

This is the format for captured bug reports. Tests are validated via differential comparison (replay vs original) rather than explicit assertions.

```json
{
  "test_format_version": "1.0",
  "test_id": "capture-2025-12-03-1234567890",
  "test_name": "Ripple trim creates clip overlap",
  "category": "timeline/ripple_edit",
  "tags": ["user-submitted", "regression"],

  "capture_metadata": {
    "capture_type": "user_submitted",
    "capture_timestamp": "2025-12-03T10:30:45Z",
    "jve_version": "0.1.0-dev",
    "platform": "macOS 14.1",
    "user_description": "Clip overlaps with next clip after ripple trim",
    "user_expected_behavior": "Clips should maintain separation"
  },

  "window_geometry": {
    "x": 100,
    "y": 100,
    "width": 1920,
    "height": 1080,
    "panel_layout": {
      "timeline": {"x": 0, "y": 600, "width": 1920, "height": 480},
      "inspector": {"x": 1500, "y": 0, "width": 420, "height": 600},
      "media_browser": {"x": 0, "y": 0, "width": 400, "height": 600}
    }
  },

  "gesture_log": [
    {
      "id": "g1",
      "timestamp_ms": 1000,
      "type": "mouse_move",
      "screen_x": 500,
      "screen_y": 700,
      "window_x": 400,
      "window_y": 600
    },
    {
      "id": "g2",
      "timestamp_ms": 1100,
      "type": "mouse_press",
      "screen_x": 500,
      "screen_y": 700,
      "window_x": 400,
      "window_y": 600,
      "button": "left",
      "modifiers": []
    },
    {
      "id": "g3",
      "timestamp_ms": 1150,
      "type": "mouse_drag",
      "start_x": 500,
      "start_y": 700,
      "end_x": 800,
      "end_y": 700,
      "button": "left",
      "modifiers": [],
      "duration_ms": 250
    },
    {
      "id": "g4",
      "timestamp_ms": 1400,
      "type": "mouse_release",
      "screen_x": 800,
      "screen_y": 700,
      "button": "left"
    }
  ],

  "command_log": [
    {
      "id": "c1",
      "timestamp_ms": 1105,
      "command": "SelectClip",
      "parameters": {
        "clip_id": "uuid-clip-123",
        "track_id": "uuid-track-1"
      },
      "result": {
        "success": true
      },
      "triggered_by_gesture": "g2"
    },
    {
      "id": "c2",
      "timestamp_ms": 1405,
      "command": "RippleEdit",
      "parameters": {
        "clip_id": "uuid-clip-123",
        "edge": "out",
        "delta_ms": 1500,
        "clamped_delta_ms": 966.67
      },
      "result": {
        "success": false,
        "error_message": "Collision with downstream clip",
        "error_code": "CONSTRAINT_VIOLATION"
      },
      "triggered_by_gesture": "g3"
    }
  ],

  "log_output": [
    {
      "timestamp_ms": 1105,
      "level": "info",
      "message": "Selected clip 'Interview_01.mov' on track V1"
    },
    {
      "timestamp_ms": 1405,
      "level": "warning",
      "message": "Clamped ripple delta from 1500ms to 966.67ms due to downstream collision"
    },
    {
      "timestamp_ms": 1406,
      "level": "error",
      "message": "RippleEdit failed: Collision with downstream clip at 1966ms"
    }
  ],

  "database_snapshots": {
    "before": "captures/capture-123-before.db",
    "after": "captures/capture-123-after.db"
  },

  "screenshots": {
    "ring_buffer": "captures/capture-123-screenshots/",
    "screenshot_count": 300,
    "screenshot_interval_ms": 1000,
    "slideshow_video": "captures/capture-123-slideshow.mp4"
  },

  "video_recording": {
    "youtube_url": "https://youtube.com/watch?v=dQw4w9WgXcQ",
    "youtube_uploaded": true,
    "local_file": "captures/capture-123-demo.mp4",
    "duration_seconds": 30
  }
}
```

### Test Format Field Definitions

**capture_metadata:**
- `capture_type`: "automatic" (error-triggered) or "user_submitted" (manual Cmd+Shift+B)
- `capture_timestamp`: ISO 8601 timestamp when capture occurred
- `jve_version`: Build version for compatibility tracking
- `platform`: OS and version
- `user_description`: User's explanation of the bug (user_submitted only)
- `user_expected_behavior`: What user thought should happen (user_submitted only)

**window_geometry:**
- Exact window position and size for pixel-perfect replay
- `panel_layout`: Position/size of each major UI panel (timeline, inspector, browser)
- Required for GUI replay to match original environment

**gesture_log:**
- Raw user input events at pixel coordinates
- Each gesture has:
  - `id`: Unique gesture identifier for correlation
  - `timestamp_ms`: Milliseconds since capture start
  - `type`: mouse_move, mouse_press, mouse_release, mouse_drag, key_press, key_release, wheel_scroll
  - `screen_x/y`: Absolute screen coordinates
  - `window_x/y`: Coordinates relative to JVE window (for portability)
  - `button`: left, right, middle (for mouse events)
  - `modifiers`: Array of Shift, Cmd, Alt, Ctrl
- No widget identification needed - just raw pixels

**command_log:**
- Commands that executed in response to gestures
- Each command has:
  - `id`: Unique command identifier
  - `timestamp_ms`: When command executed (typically 5-50ms after gesture)
  - `command`: Name from CommandDispatcher registry
  - `parameters`: Exact parameters passed to executor (includes clip_ids, track_ids, etc.)
  - `result`: Return value from executor (success/failure, error messages, clamped values)
  - `triggered_by_gesture`: ID of gesture that triggered this command
- This is the "ground truth" for validation - replay must produce identical command log

**log_output:**
- All log messages during capture period
- Each entry has:
  - `timestamp_ms`: When message was logged
  - `level`: info, warning, error, critical
  - `message`: The log message text
- Used for validation - replay should produce identical warnings/errors

**database_snapshots:**
- SQLite database dumps before and after captured gestures
- Used for differential validation - replay must produce identical final state
- `before`: Initial state (before first gesture)
- `after`: Final state (after last command completed)

**screenshots:**
- Ring buffer of screenshots captured during session
- `ring_buffer`: Directory containing screenshot_001.png through screenshot_300.png
- `screenshot_count`: Number of screenshots in buffer (typically 300 for 5 minutes @ 1/sec)
- `screenshot_interval_ms`: Time between screenshots (1000ms = 1 second)
- `slideshow_video`: MP4 generated from screenshots at 2x speed (5 min → 2.5 min)

**video_recording:**
- Optional user-recorded demonstration video
- `youtube_url`: Unlisted YouTube video URL (if user uploaded)
- `youtube_uploaded`: Boolean flag
- `local_file`: Path to local MP4 file
- `duration_seconds`: Length of video

## Test Environment 1: Fast Mocked Tests

### Architecture

```
test_runner_mocked.lua
  ├─> json_test_loader.lua (parse JSON into Lua tables)
  ├─> mock_database.lua (in-memory SQLite :memory:)
  ├─> mock_timeline.lua (lightweight clip/track data structures)
  └─> command_executor_mocked.lua (execute commands against mocks)
      └─> assertion_engine.lua (validate expected outcomes)
```

### Implementation Strategy

**Mock Database** (mock_database.lua):
- Uses SQLite `:memory:` database with real schema
- Bypasses Qt widgets and rendering
- Command executors operate on pure data structures
- Fast enough to run hundreds of tests per second

**Mock Timeline** (mock_timeline.lua):
- Simplified Timeline/Track/Clip objects
- Implements only data manipulation (no rendering)
- Reuses actual command executors from command_manager.lua
- Validation logic identical to production

**Command Execution**:
- Loads actual command executors from src/lua/core/command_manager.lua
- Executors operate on mock database
- Return values validated against `expected_result` in JSON

**Assertion Engine** (assertion_engine.lua):
- Executes each assertion in `assertions` array
- Supports all assertion types except `visual_render`
- Reports pass/fail with detailed context
- Generates diff output for failures

### Limitations

**Cannot test:**
- Qt widget rendering
- User input event handling
- Visual layout calculations
- Performance characteristics
- Race conditions in async operations

**Best for:**
- Command executor logic
- Constraint calculations
- Database operations
- State transitions
- Undo/redo correctness

## Test Environment 2: GUI Integration Tests

### Architecture

```
test_runner_gui.lua
  ├─> json_test_loader.lua (same parser as mocked)
  ├─> jve_puppeteer.lua (control running JVE instance)
  ├─> command_executor_gui.lua (send commands via IPC)
  ├─> screenshot_comparator.lua (visual regression testing)
  └─> assertion_engine_gui.lua (extended assertions for GUI)
```

### Implementation Strategy

**JVE Puppeteer** (jve_puppeteer.lua):
- Launches JVE with `--test-mode` flag
- Communicates via Unix socket or named pipe
- Sends commands as JSON-RPC messages
- Receives responses including success/failure and state snapshots

**Test Mode Flag**:
```lua
-- In main.lua
if args["--test-mode"] then
    require("core.test_mode_server").start()
end
```

**Test Mode Server** (test_mode_server.lua):
- Listens on Unix socket `/tmp/jve-test-{pid}.sock`
- Accepts JSON-RPC commands:
  - `execute_command`: Run timeline command
  - `get_database_state`: Query arbitrary SQL
  - `get_clip_properties`: Fetch clip by ID
  - `take_screenshot`: Capture current frame to PNG
  - `get_log_tail`: Retrieve recent log lines
  - `shutdown`: Graceful exit

**Screenshot Comparison**:
- Takes PNG snapshot of timeline viewport
- Compares pixel-by-pixel against reference image
- Reports percentage difference
- Generates visual diff highlighting changed regions
- Stores failed screenshots for manual review

**Timing Control**:
- Test runner waits for "ready" signal after each command
- JVE signals when rendering complete and database flushed
- Prevents flaky tests from timing races

### Limitations

**Slower than mocked tests:**
- Launch overhead: ~2-3 seconds per test suite
- Rendering time: ~16ms per frame at 60fps
- Screenshot comparison: ~50ms per image

**Platform-specific:**
- Screenshot rendering differs across macOS/Linux/Windows
- Reference images must be per-platform
- Font rendering affects pixel comparison

**Best for:**
- Visual regression testing
- Real-world workflow validation
- End-to-end feature testing
- Performance profiling
- User-reported bugs requiring full context

## Automatic Capture System (Always Running)

### Continuous Ring Buffer

JVE continuously captures context in memory (user can disable in preferences):

```lua
-- capture_manager.lua (runs in background)
local CaptureManager = {
    gesture_ring_buffer = {},
    command_ring_buffer = {},
    log_ring_buffer = {},
    screenshot_ring_buffer = {},

    max_gestures = 200,
    max_time_ms = 300000,  -- 5 minutes
    screenshot_interval_ms = 1000,  -- 1 second

    capture_enabled = true  -- User preference
}

function CaptureManager:log_gesture(gesture)
    if not self.capture_enabled then return end

    -- Add to ring buffer
    table.insert(self.gesture_ring_buffer, {
        timestamp_ms = get_elapsed_ms(),
        gesture = gesture
    })

    -- Trim by count and time
    self:trim_buffers()
end

function CaptureManager:log_command(command, result, triggered_by_gesture)
    if not self.capture_enabled then return end

    table.insert(self.command_ring_buffer, {
        timestamp_ms = get_elapsed_ms(),
        command = command,
        parameters = parameters,
        result = result,
        triggered_by_gesture = triggered_by_gesture
    })

    self:trim_buffers()
end

function CaptureManager:log_message(level, message)
    if not self.capture_enabled then return end

    table.insert(self.log_ring_buffer, {
        timestamp_ms = get_elapsed_ms(),
        level = level,
        message = message
    })

    self:trim_buffers()
end

function CaptureManager:capture_screenshot()
    if not self.capture_enabled then return end

    -- Capture full window screenshot
    local screenshot = qt_grab_window(main_window)

    table.insert(self.screenshot_ring_buffer, {
        timestamp_ms = get_elapsed_ms(),
        image = screenshot  -- QPixmap in memory
    })

    self:trim_buffers()
end

function CaptureManager:trim_buffers()
    local current_time = get_elapsed_ms()
    local cutoff_time = current_time - self.max_time_ms

    -- Trim gestures by count AND time
    while #self.gesture_ring_buffer > self.max_gestures do
        table.remove(self.gesture_ring_buffer, 1)
    end
    while #self.gesture_ring_buffer > 0 and
          self.gesture_ring_buffer[1].timestamp_ms < cutoff_time do
        table.remove(self.gesture_ring_buffer, 1)
    end

    -- Trim commands, logs, screenshots by time only
    -- (Commands/logs are sparse, screenshots are dense)
    -- Similar logic for other buffers...
end
```

### Screenshot Timer

```lua
-- In main.lua initialization
timer = create_timer({
    interval_ms = 1000,
    repeat = true,
    callback = function()
        capture_manager.capture_screenshot()
    end
})
```

### Trigger Conditions

Automatically creates JSON test case when:

1. **Uncaught Lua Error**
   - `pcall()` returns false in command executor
   - Stack trace captured
   - Ring buffers frozen and exported

2. **Database Constraint Violation**
   - SQLite UNIQUE, FOREIGN KEY, CHECK constraint failure
   - Database snapshot taken before rollback

3. **Assertion Failure in Production**
   - `assert()` call fails in non-test mode
   - Context variables captured

4. **Undo/Redo Mismatch**
   - Replay produces different state than expected
   - Before/after database snapshots saved

5. **Frame Alignment Violation**
   - Clip timing not frame-aligned
   - Validation detects fractional frame

### Capture Process

**Phase 1: Freeze Ring Buffers**
```lua
function capture_bug_context()
    -- Stop all background operations
    timeline_panel.pause_playback()

    -- Freeze ring buffers (stop accepting new entries)
    capture_manager.capture_enabled = false

    -- Take database snapshot
    local snapshot_path = "tests/captures/bug-" .. os.time() .. ".db"
    database.backup_to_file(snapshot_path)

    -- Export ring buffers to disk
    local screenshot_dir = "tests/captures/bug-" .. os.time() .. "-screenshots/"
    os.execute("mkdir -p " .. screenshot_dir)

    for i, entry in ipairs(capture_manager.screenshot_ring_buffer) do
        local path = string.format("%s/screenshot_%03d.png", screenshot_dir, i)
        entry.image:save(path)
    end

    return {
        snapshot_db = snapshot_path,
        gestures = capture_manager.gesture_ring_buffer,
        commands = capture_manager.command_ring_buffer,
        logs = capture_manager.log_ring_buffer,
        screenshot_dir = screenshot_dir,
        screenshot_count = #capture_manager.screenshot_ring_buffer,
        stack_trace = debug.traceback(),
        timestamp = os.time()
    }
end
```

**Phase 2: Generate Slideshow Video**
```lua
function generate_slideshow_video(screenshot_dir, screenshot_count)
    local slideshow_path = screenshot_dir:gsub("-screenshots/$", "-slideshow.mp4")

    -- Use ffmpeg to create 2x speed slideshow (1 image = 0.5 seconds)
    local cmd = string.format([[
        ffmpeg -framerate 2 \
               -i "%s/screenshot_%%03d.png" \
               -c:v libx264 \
               -pix_fmt yuv420p \
               -y \
               "%s"
    ]], screenshot_dir, slideshow_path)

    local result = os.execute(cmd)
    if result ~= 0 then
        return nil, "ffmpeg failed to generate slideshow"
    end

    return slideshow_path
end
```

**Phase 3: Generate JSON Test**
```lua
function generate_test_from_capture(context, error_info)
    -- Generate slideshow video from screenshots
    local slideshow_path = generate_slideshow_video(
        context.screenshot_dir,
        context.screenshot_count
    )

    local test = {
        test_format_version = "1.0",
        test_id = "auto-capture-" .. context.timestamp,
        test_name = "Automatic capture: " .. error_info.message,
        category = infer_category(error_info),
        tags = {"auto-capture", "regression"},

        capture_metadata = {
            capture_type = "automatic",
            capture_timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", context.timestamp),
            jve_version = get_version(),
            platform = get_platform_info(),
            error_message = error_info.message,
            lua_stack_trace = context.stack_trace
        },

        window_geometry = get_window_geometry(),

        gesture_log = context.gestures,
        command_log = context.commands,
        log_output = context.logs,

        database_snapshots = {
            before = context.snapshot_db,  -- Note: we only have "after" for automatic captures
            after = context.snapshot_db
        },

        screenshots = {
            ring_buffer = context.screenshot_dir,
            screenshot_count = context.screenshot_count,
            screenshot_interval_ms = 1000,
            slideshow_video = slideshow_path
        }
    }

    local json_path = "tests/captures/test-" .. context.timestamp .. ".json"
    file.write(json_path, json.encode(test))

    return json_path, test
end
```

**Phase 4: Notify User**
```lua
function show_bug_capture_dialog(test_path)
    local dialog = {
        title = "JVE Bug Captured",
        message = [[
A test case has been automatically generated:

  ]] .. test_path .. [[

This test documents what just went wrong and will
help prevent this bug from recurring.

Would you like to:
- Submit bug report (opens GitHub with test attached)
- Review test file (opens in editor)
- Run test now (launches test runner)
- Dismiss
]],
        buttons = {"Submit", "Review", "Run Test", "Dismiss"}
    }

    return show_dialog(dialog)
end
```

### Integration Points

**Error Handler Wrapper**:
```lua
-- In command_manager.lua execute()
local success, result = pcall(executor, params)
if not success then
    local context = capture_bug_context()
    local test_path = generate_test_from_capture(context, {
        message = result,
        command = command_name
    })
    show_bug_capture_dialog(test_path)
    return {success = false, error_message = result}
end
```

**Database Trigger**:
```sql
-- In schema.sql
CREATE TRIGGER validate_frame_alignment
BEFORE INSERT ON clips
FOR EACH ROW
WHEN NEW.start_time_ms % 33.33333 != 0
BEGIN
    SELECT RAISE(ABORT, 'Frame alignment violation');
END;
```

## Manual Bug Report Capture

### Menu Command

```lua
-- In keyboard_shortcut_registry.lua
keyboard_shortcut_registry.register_command({
    id = "capture_bug_report",
    name = "Capture Bug Report",
    category = "Help",
    description = "Create bug report from current state with screenshots and video",
    default_shortcut = "",  -- User can bind via keyboard customization dialog
    execute = function()
        show_bug_report_capture_dialog()
    end
})
```

Note: User can assign any keyboard shortcut via the existing keyboard customization system.

### Capture Dialog (UI TBD - Requires Implementation Review)

```lua
function show_anomaly_capture_dialog()
    local dialog = create_dialog({
        title = "Capture Anomaly Report",
        width = 600,
        height = 400
    })

    add_label(dialog, "Describe what looks wrong:")
    local description_field = add_text_edit(dialog, {
        placeholder = "Example: Clip overlaps with next clip after ripple trim"
    })

    add_label(dialog, "Expected behavior:")
    local expected_field = add_text_edit(dialog, {
        placeholder = "Example: Clips should maintain separation"
    })

    add_label(dialog, "Steps to reproduce:")
    local steps_field = add_text_edit(dialog, {
        placeholder = "1. Create two clips with gap\n2. Ripple trim first clip outward\n3. Observe overlap"
    })

    add_buttons(dialog, {
        {
            text = "Capture & Save Test",
            callback = function()
                local context = capture_bug_context()
                local test = generate_test_from_manual_capture({
                    description = get_text(description_field),
                    expected = get_text(expected_field),
                    steps = get_text(steps_field),
                    context = context
                })
                show_message("Test saved to: " .. test.path)
            end
        },
        {text = "Cancel", callback = close_dialog}
    })
end
```

### Manual Capture JSON

Differs from automatic captures:
- User-provided description/steps
- No error message or stack trace
- Test assertions may be empty (user defines what's wrong)
- Marked with `capture_type: "user_submitted"`

## Bug Report Submission System

### Submission Review Dialog (UI TBD - Requires Implementation Review)

Before submission, user reviews complete package:

```lua
function show_bug_submission_review_dialog(capture_json, slideshow_video)
    -- Dialog shows:
    -- 1. Video player with slideshow (full window screenshots at 2x speed)
    -- 2. Summary: X gestures, Y commands, Z log entries
    -- 3. User's description (editable)
    -- 4. Command history list
    -- 5. Checkboxes:
    --    - Include database snapshots (may contain sensitive data)
    --    - Upload video to YouTube (unlisted)
    -- 6. Buttons: Submit to GitHub | Save Locally | Cancel

    -- User can:
    -- - Review slideshow video showing exactly what was captured
    -- - Edit their description
    -- - Decide whether to include database
    -- - Choose to upload video or not
    -- - Submit or save locally without submitting
end
```

### YouTube Upload Integration

**OAuth Flow:**

```lua
function youtube_oauth_flow()
    -- 1. Open browser to YouTube OAuth consent screen
    local auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" ..
                     "client_id=" .. YOUTUBE_CLIENT_ID ..
                     "&redirect_uri=http://localhost:8080" ..
                     "&response_type=code" ..
                     "&scope=https://www.googleapis.com/auth/youtube.upload"

    open_browser(auth_url)

    -- 2. Start local web server to receive callback
    local server = start_local_server(8080)

    -- 3. Wait for OAuth callback with authorization code
    local auth_code = server:wait_for_callback()

    -- 4. Exchange authorization code for access token
    local token_response = http_post("https://oauth2.googleapis.com/token", {
        code = auth_code,
        client_id = YOUTUBE_CLIENT_ID,
        client_secret = YOUTUBE_CLIENT_SECRET,
        redirect_uri = "http://localhost:8080",
        grant_type = "authorization_code"
    })

    -- 5. Store access token and refresh token
    local tokens = json.decode(token_response)
    settings.set("youtube_access_token", tokens.access_token)
    settings.set("youtube_refresh_token", tokens.refresh_token)
    settings.set("youtube_token_expires", os.time() + tokens.expires_in)

    return tokens.access_token
end
```

**Video Upload:**

```lua
function youtube_upload_video(video_path, metadata)
    -- Check if authenticated
    local access_token = settings.get("youtube_access_token")
    if not access_token or youtube_token_expired() then
        access_token = youtube_oauth_flow()
    end

    -- Upload video to YouTube
    local upload_url = "https://www.googleapis.com/upload/youtube/v3/videos"
    local video_metadata = {
        snippet = {
            title = "JVE Bug Report: " .. metadata.test_id,
            description = metadata.user_description,
            tags = {"jve", "bug-report", "video-editor"},
            categoryId = "28"  -- Science & Technology
        },
        status = {
            privacyStatus = "unlisted",  -- Not public, but shareable via link
            selfDeclaredMadeForKids = false
        }
    }

    -- Multipart upload (metadata + video file)
    local response = http_multipart_post(upload_url, {
        headers = {
            Authorization = "Bearer " .. access_token,
            ["Content-Type"] = "multipart/related"
        },
        parts = {
            {
                content_type = "application/json",
                body = json.encode(video_metadata)
            },
            {
                content_type = "video/mp4",
                file = video_path
            }
        }
    })

    local result = json.decode(response)
    local video_url = "https://youtube.com/watch?v=" .. result.id

    return video_url
end
```

### GitHub Issue Creation

```lua
function github_create_issue(bug_report)
    -- Upload artifacts to GitHub release attachments or gist
    local artifact_urls = upload_bug_report_artifacts(bug_report)

    -- Create GitHub issue with markdown template
    local issue_body = string.format([[
## Bug Description
%s

## Expected Behavior
%s

## JVE Version
%s

## Platform
%s

## Video Demonstration
%s

## Captured Data
- Gesture Log: %d events
- Command Log: %d commands
- Log Output: %d messages
- Screenshots: %d images (5 minutes)

## Artifacts
- [Capture JSON](%s)
- [Slideshow Video (Local)](%s)
- [Database Snapshot](%s)

## Command History
```
%s
```

---
*This bug report was automatically generated by JVE's capture system.*
]],
        bug_report.capture_metadata.user_description,
        bug_report.capture_metadata.user_expected_behavior,
        bug_report.capture_metadata.jve_version,
        bug_report.capture_metadata.platform,
        bug_report.video_recording.youtube_url or "No video uploaded",
        #bug_report.gesture_log,
        #bug_report.command_log,
        #bug_report.log_output,
        bug_report.screenshots.screenshot_count,
        artifact_urls.capture_json,
        artifact_urls.slideshow_video,
        artifact_urls.database_snapshot,
        format_command_history(bug_report.command_log)
    )

    -- Create issue via GitHub API
    local response = http_post("https://api.github.com/repos/joe/jve/issues", {
        headers = {
            Authorization = "Bearer " .. GITHUB_TOKEN,
            Accept = "application/vnd.github.v3+json"
        },
        body = json.encode({
            title = "Bug: " .. bug_report.test_name,
            body = issue_body,
            labels = {"bug", "auto-capture"}
        })
    })

    local issue = json.decode(response)
    return issue.html_url
end
```

## Differential Testing & Validation

### Validation Strategy

Tests are validated by comparing replay vs original capture, not explicit assertions.

**What We Compare:**

1. **Command Sequence**
   - Same commands executed in same order
   - Command parameters match (clip_ids may differ if recreated from database snapshot)
   - Timing deltas similar (within reasonable tolerance for performance variations)

2. **Command Results**
   - Success/failure matches
   - Error messages match
   - Clamped values match (e.g., constrained ripple trim delta)

3. **Database State**
   - Before snapshot → replay gestures → After snapshot
   - SQL diff shows identical timeline state
   - Clip positions, durations, track assignments match

4. **Log Output**
   - Warning/error messages match
   - Info messages may vary slightly (timestamps, internal IDs)

### Validation Implementation

```lua
function validate_replay(original_capture, replay_capture)
    local results = {
        command_sequence_match = false,
        command_results_match = false,
        database_state_match = false,
        log_output_match = false,
        overall_success = false
    }

    -- 1. Compare command sequences
    if #original_capture.command_log ~= #replay_capture.command_log then
        results.command_sequence_error = string.format(
            "Command count mismatch: original=%d, replay=%d",
            #original_capture.command_log,
            #replay_capture.command_log
        )
    else
        local command_match = true
        for i, orig_cmd in ipairs(original_capture.command_log) do
            local replay_cmd = replay_capture.command_log[i]
            if orig_cmd.command ~= replay_cmd.command then
                command_match = false
                results.command_sequence_error = string.format(
                    "Command #%d mismatch: original=%s, replay=%s",
                    i, orig_cmd.command, replay_cmd.command
                )
                break
            end
        end
        results.command_sequence_match = command_match
    end

    -- 2. Compare command results
    results.command_results_match = compare_command_results(
        original_capture.command_log,
        replay_capture.command_log
    )

    -- 3. Compare database states
    results.database_state_match = compare_database_snapshots(
        original_capture.database_snapshots.after,
        replay_capture.database_snapshots.after
    )

    -- 4. Compare log output (warnings/errors only)
    results.log_output_match = compare_log_output(
        original_capture.log_output,
        replay_capture.log_output
    )

    -- Overall success: all validations pass
    results.overall_success =
        results.command_sequence_match and
        results.command_results_match and
        results.database_state_match and
        results.log_output_match

    return results
end
```

### Gesture-to-Command Correlation

Used for debugging test failures and understanding what gestures triggered which commands:

```lua
function correlate_gestures_to_clips(gesture_log, command_log)
    local correlations = {}

    for _, command in ipairs(command_log) do
        -- Find gesture(s) that triggered this command (within 100ms window)
        local triggering_gestures = {}
        for _, gesture in ipairs(gesture_log) do
            if math.abs(gesture.timestamp_ms - command.timestamp_ms) < 100 and
               gesture.timestamp_ms <= command.timestamp_ms then
                table.insert(triggering_gestures, gesture)
            end
        end

        -- Extract affected clips from command parameters
        local affected_clips = extract_clip_ids_from_command(command)

        table.insert(correlations, {
            command = command.command,
            command_timestamp = command.timestamp_ms,
            gestures = triggering_gestures,
            clip_ids = affected_clips,

            -- Derived semantic information (generated at analysis time)
            derived = {
                gesture_description = describe_gestures(triggering_gestures),
                clip_descriptions = describe_clips(affected_clips)
            }
        })
    end

    return correlations
end
```

This correlation is used for:
- Test failure diagnosis ("which gesture caused the wrong command?")
- Documentation ("dragging at (x,y) triggered RippleEdit on clip C")
- Future conversion to semantic widget paths (if needed)

## Converting Existing Tests

### Current Test Structure

Existing tests in `tests/` directory:
- Hand-coded Lua files
- Direct function calls to command executors
- Inline assertions with print statements
- Example: `test_ripple_operations.lua`

### Conversion Strategy

**Phase 1: Extract Test Data**

Parse existing test file to identify:
- Setup code (creating clips, tracks, sequences)
- Command execution calls
- Assertion checks

**Phase 2: Generate JSON**

Transform Lua code into JSON test format:

```lua
-- Original test
local clip1 = create_clip({start_time = 0, duration = 1000})
local result = execute_command("RippleEdit", {
    clip_id = clip1.id,
    edge = "out",
    delta_ms = 500
})
assert(clip1.duration == 1500, "Duration should be 1500ms")

-- Converted JSON
{
  "setup": {
    "clips": [
      {
        "id": "clip1",
        "start_time_ms": 0,
        "duration_ms": 1000
      }
    ]
  },
  "commands": [
    {
      "command": "RippleEdit",
      "parameters": {
        "clip_id": "clip1",
        "edge": "out",
        "delta_ms": 500
      }
    }
  ],
  "assertions": [
    {
      "type": "clip_property",
      "clip_id": "clip1",
      "property": "duration_ms",
      "expected": 1500
    }
  ]
}
```

**Phase 3: Automated Converter**

```lua
-- test_converter.lua
function convert_lua_test_to_json(lua_file_path)
    local lua_code = file.read(lua_file_path)
    local ast = parse_lua(lua_code)

    local test = {
        test_format_version = "1.0",
        test_id = extract_test_id(lua_file_path),
        test_name = extract_test_name(ast),
        setup = extract_setup(ast),
        commands = extract_commands(ast),
        assertions = extract_assertions(ast)
    }

    local json_path = lua_file_path:gsub("%.lua$", ".json")
    file.write(json_path, json.encode(test))

    return json_path
end
```

**Phase 4: Validation**

Run both old Lua test and new JSON test, verify identical results:

```bash
./test_runner_mocked.lua tests/test_ripple_operations.lua
./test_runner_mocked.lua tests/test_ripple_operations.json
diff <(cat test_results_lua.txt) <(cat test_results_json.txt)
```

## Implementation Roadmap

### Phase 1: JSON Format & Mocked Tests (Week 1-2)

- [ ] Define JSON schema v1.0 (this document)
- [ ] Implement `json_test_loader.lua` (parse JSON into Lua tables)
- [ ] Implement `mock_database.lua` (in-memory SQLite setup)
- [ ] Implement `test_runner_mocked.lua` (core test execution)
- [ ] Implement `assertion_engine.lua` (validate outcomes)
- [ ] Convert 3 existing tests to JSON as proof-of-concept
- [ ] Run converted tests and verify results match

### Phase 2: Automatic Bug Capture (Week 3)

- [ ] Implement `capture_bug_context()` in error handlers
- [ ] Implement `generate_test_from_capture()`
- [ ] Add database snapshot functionality
- [ ] Create bug capture notification dialog
- [ ] Test by intentionally triggering assertion failure
- [ ] Verify generated JSON test runs in mocked environment

### Phase 3: Manual Anomaly Capture (Week 4)

- [ ] Implement menu command and keyboard shortcut (Cmd+Shift+B)
- [ ] Create anomaly capture dialog with description fields
- [ ] Implement `generate_test_from_manual_capture()`
- [ ] Test workflow: notice bug → capture → run test → verify

### Phase 4: GUI Test Environment (Week 5-6)

- [ ] Implement `--test-mode` flag in main.lua
- [ ] Implement `test_mode_server.lua` (Unix socket RPC server)
- [ ] Implement `jve_puppeteer.lua` (client to control JVE)
- [ ] Implement `test_runner_gui.lua` (orchestrates GUI tests)
- [ ] Add screenshot capture and comparison
- [ ] Run same JSON tests in both mocked and GUI environments

### Phase 5: Test Conversion & CI Integration (Week 7)

- [ ] Write automated converter for existing Lua tests
- [ ] Convert all 21 existing tests to JSON format
- [ ] Validate converted tests pass in mocked environment
- [ ] Integrate test runner into CMake build system
- [ ] Add CI job: run all mocked tests on every commit
- [ ] Add CI job: run all GUI tests nightly

## Success Criteria

### Mocked Test Environment
- ✅ Runs 100+ tests in < 5 seconds
- ✅ No Qt dependencies (can run headless in CI)
- ✅ 100% of existing test functionality preserved
- ✅ Clear pass/fail reporting with diffs

### GUI Test Environment
- ✅ Executes same JSON tests as mocked environment
- ✅ Screenshot comparison with <1% false positive rate
- ✅ Complete end-to-end workflow validation
- ✅ Detects visual regressions in timeline rendering

### Automatic Bug Capture
- ✅ Captures context within 100ms of error
- ✅ Generated tests run without modification
- ✅ Database snapshots preserve exact failure state
- ✅ User can submit bug report with one click

### Manual Anomaly Capture
- ✅ Dialog opens in <200ms
- ✅ Captures full timeline state and command history
- ✅ Generated tests document user's concern
- ✅ Developer can reproduce issue from JSON test alone

### Test Conversion
- ✅ All 21 existing tests converted to JSON
- ✅ Converted tests produce identical results
- ✅ Legacy Lua tests deprecated and removed
- ✅ Future tests written in JSON format only

## Open Questions

1. **Database snapshot strategy**: Full copy or incremental delta?
   - Full copy: Simple but large files
   - Incremental: Complex but efficient
   - **Recommendation**: Full copy for now, optimize later

2. **Screenshot storage**: Store reference images in git or external?
   - Git: Simple but repo bloat
   - External (S3/CDN): Complex but scalable
   - **Recommendation**: Git with LFS for images >100KB

3. **Test isolation**: Should tests share database or create fresh each time?
   - Shared: Fast but risk of contamination
   - Fresh: Slow but guaranteed isolation
   - **Recommendation**: Fresh database per test, use `:memory:` for speed

4. **Visual diff threshold**: What percentage difference triggers failure?
   - Too strict: Font rendering differences cause false positives
   - Too loose: Real bugs slip through
   - **Recommendation**: 0.1% for pixel-perfect regions, 2% for text/AA

5. **Command replay determinism**: Can we guarantee exact replay?
   - Challenge: Timestamps, random UUIDs, system time
   - Solution: Seed RNG deterministically, mock system time
   - **Recommendation**: Add `--deterministic` flag for test mode

## Alignment with ENGINEERING.md

This spec follows all key rules:

- **Rule 0**: TodoWrite for implementation tracking ✅
- **Rule 0.1**: No aspirational language, only "Specification (Not Implemented)" ✅
- **Rule 2.2**: Zero-tolerance testing with clear pass/fail ✅
- **Rule 2.13**: No fallbacks - tests fail explicitly ✅
- **Rule 2.20**: Regression tests first - auto-capture enforces this ✅
- **Architecture**: Extends command system, doesn't replace ✅
- **Event sourcing**: Tests replay commands, not direct state mutation ✅
