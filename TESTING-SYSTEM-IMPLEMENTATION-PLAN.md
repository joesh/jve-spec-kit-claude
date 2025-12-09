# Testing System Implementation Plan

**Status**: Implementation Roadmap
**Created**: 2025-12-03
**Purpose**: Phased implementation plan for dual test environment and bug capture system

## Overview

This plan breaks down the testing system specification into implementable phases with clear milestones, dependencies, and deliverables.

## Phase 0: Prerequisites & Foundation (Week 1)

**Goal**: Establish foundation infrastructure needed by all subsequent phases.

### Tasks

**0.1 - Event Filter Infrastructure (C++)**
- [ ] Create `GestureLogger` class with Qt event filter
- [ ] Hook into `qApp->installEventFilter()` to capture all events
- [ ] Filter interesting events: mouse (press/move/release/wheel), keyboard (press/release)
- [ ] Extract window-relative coordinates from screen coordinates
- [ ] Extract modifier keys from QKeyEvent/QMouseEvent
- [ ] Add enable/disable flag (respects user preference)
- [ ] Qt binding: `lua_install_gesture_logger()` callable from Lua

**0.2 - Elapsed Time Tracking**
- [ ] Add `get_elapsed_ms()` function to Lua environment
- [ ] Tracks milliseconds since app start (not wall clock time)
- [ ] Used for all timestamp_ms fields in logs
- [ ] Monotonic, never goes backwards

**0.3 - Window Geometry Capture**
- [ ] Implement `get_window_geometry()` in Lua
- [ ] Returns: x, y, width, height, panel positions
- [ ] Captures main window and all major panels (timeline, inspector, browser)
- [ ] Qt bindings: `lua_get_window_geometry()`

**0.4 - Database Backup**
- [ ] Implement `database.backup_to_file(path)` in Lua
- [ ] Uses SQLite VACUUM INTO for clean snapshot
- [ ] Returns success/failure and file size

**0.5 - Screenshot Capture**
- [ ] Qt binding: `lua_grab_window(widget)` → QPixmap userdata
- [ ] QPixmap:save(path) method exposed to Lua
- [ ] Captures full main window, not just timeline

**Deliverable**: Foundation functions callable from Lua, basic capture infrastructure works.

**Testing**: Manual verification that each function works independently.

---

## Phase 1: Continuous Ring Buffer Capture (Week 1-2)

**Goal**: JVE continuously captures gestures, commands, logs, screenshots in memory.

### Tasks

**1.1 - CaptureManager Module (Lua)**
- [ ] Create `src/lua/core/capture_manager.lua`
- [ ] Implement ring buffer data structures (4 buffers)
- [ ] Implement `log_gesture(gesture)` - adds to gesture ring buffer
- [ ] Implement `log_command(command, result, triggered_by_gesture)` - adds to command buffer
- [ ] Implement `log_message(level, message)` - adds to log buffer
- [ ] Implement `capture_screenshot()` - adds QPixmap to screenshot buffer
- [ ] Implement `trim_buffers()` - enforces 5 min OR 200 gesture limit
- [ ] Add `capture_enabled` flag (default true)

**1.2 - Gesture Logging Integration**
- [ ] Wire `GestureLogger` C++ events to `capture_manager.log_gesture()`
- [ ] Map Qt event types to gesture types (mouse_press, mouse_move, etc.)
- [ ] Include both screen coordinates and window-relative coordinates
- [ ] Include button and modifiers

**1.3 - Command Logging Integration**
- [ ] Modify `command_manager.lua execute()` to call `capture_manager.log_command()`
- [ ] Pass command name, parameters, result, timestamp
- [ ] Link to triggering gesture (match by timestamp within 100ms window)
- [ ] Store gesture ID in command log entry

**1.4 - Log Output Integration**
- [ ] Intercept all log messages (print, warning, error)
- [ ] Call `capture_manager.log_message(level, message)` for each
- [ ] Include timestamp

**1.5 - Screenshot Timer**
- [ ] Create QTimer in main.lua that fires every 1000ms
- [ ] Timer callback calls `capture_manager.capture_screenshot()`
- [ ] Screenshots stored as QPixmap in memory (not written to disk yet)

**1.6 - Preferences Integration**
- [ ] Add "Enable Automatic Capture" checkbox to preferences
- [ ] Checkbox sets `capture_manager.capture_enabled` flag
- [ ] Saving preferences persists setting to database
- [ ] Loading preferences on startup restores setting

**Deliverable**: JVE continuously captures last 5 minutes of activity in memory. Memory usage ~30MB.

**Testing**:
- Run JVE for 10 minutes, verify ring buffers contain only last 5 minutes
- Verify gesture count never exceeds 200
- Disable capture in preferences, verify buffers stop growing
- Check memory usage with Activity Monitor/Task Manager

---

## Phase 2: JSON Test Export (Week 2)

**Goal**: Convert in-memory ring buffers to JSON test format on disk.

### Tasks

**2.1 - JSON Encoder**
- [ ] Add `dkjson.lua` library to `src/lua/` (already exists for ffprobe)
- [ ] Wrapper functions for encoding complex tables

**2.2 - Capture Export Function**
- [ ] Implement `capture_manager.export_capture(reason)` → returns JSON path
- [ ] Freezes ring buffers (stops accepting new entries)
- [ ] Takes database snapshot with `database.backup_to_file()`
- [ ] Creates `tests/captures/bug-{timestamp}/` directory structure
- [ ] Exports screenshots to disk: `screenshot_001.png` through `screenshot_NNN.png`
- [ ] Builds JSON structure matching specification schema v1.0
- [ ] Writes JSON file: `tests/captures/bug-{timestamp}/capture.json`
- [ ] Returns path to JSON file

**2.3 - Automatic Capture Triggers**
- [ ] Wrap command executor in pcall, call export on error
- [ ] Hook database constraint violations (if possible via Lua)
- [ ] Hook assertion failures (`assert()` override)
- [ ] Show notification dialog after capture: "Bug captured, would you like to submit?"

**2.4 - Manual Capture Command**
- [ ] Register "Capture Bug Report" command in keyboard_shortcut_registry
- [ ] Command shows simple dialog: "Describe the issue" (single text box)
- [ ] Dialog has "Capture" and "Cancel" buttons
- [ ] "Capture" calls `capture_manager.export_capture("user_submitted")`
- [ ] Includes user description in JSON metadata
- [ ] Shows success message with path to JSON file

**Deliverable**: Bugs (automatic or manual) create complete JSON test files on disk.

**Testing**:
- Trigger intentional error (divide by zero in command executor)
- Verify JSON file created in `tests/captures/`
- Verify all fields populated (gestures, commands, logs, screenshots)
- Verify database snapshot exists and is valid SQLite file
- Manual capture via command, verify user description included

---

## Phase 3: Slideshow Video Generation (Week 2-3)

**Goal**: Generate MP4 slideshow from captured screenshots for easy review.

### Tasks

**3.1 - ffmpeg Integration**
- [ ] Verify ffmpeg available on system (check `which ffmpeg`)
- [ ] Implement `generate_slideshow_video(screenshot_dir)` in Lua
- [ ] Constructs ffmpeg command: `-framerate 2 -i screenshot_%03d.png -c:v libx264 -pix_fmt yuv420p`
- [ ] Executes via `os.execute()` or `io.popen()`
- [ ] Captures ffmpeg output for error reporting
- [ ] Returns path to generated MP4 or nil + error message

**3.2 - Integration with Export**
- [ ] Call `generate_slideshow_video()` automatically after screenshot export
- [ ] Add `slideshow_video` field to JSON capture file
- [ ] Handle ffmpeg failures gracefully (continue without video)

**3.3 - Video Playback Test**
- [ ] Generate test slideshow from 10 sample screenshots
- [ ] Verify MP4 plays in QuickTime/VLC/browser
- [ ] Verify frame rate (should be 2fps = 2x speed)

**Deliverable**: Every capture includes MP4 slideshow video for quick review.

**Testing**:
- Trigger capture with 300 screenshots
- Verify slideshow.mp4 created (should be ~2.5 minutes long)
- Play video, verify screenshots transition smoothly
- Verify video size reasonable (~5-10MB for 300 frames)

---

## Phase 4: Mocked Test Runner (Week 3-4)

**Goal**: Fast test execution without Qt/GUI, pure command replay against in-memory database.

### Tasks

**4.1 - JSON Test Loader**
- [ ] Create `src/lua/testing/json_test_loader.lua`
- [ ] Implements `load_test(json_path)` → returns test table
- [ ] Parses JSON using dkjson
- [ ] Validates schema version
- [ ] Returns structured test object

**4.2 - Mock Database Setup**
- [ ] Create `src/lua/testing/mock_database.lua`
- [ ] Opens SQLite `:memory:` database
- [ ] Loads schema from `schema.sql`
- [ ] Implements setup from JSON: creates sequences, media, tracks, clips
- [ ] Maps symbolic IDs from JSON to actual database IDs
- [ ] Stores ID mapping for assertions

**4.3 - Command Executor**
- [ ] Reuse actual command executors from `command_manager.lua`
- [ ] Execute each command from JSON `command_log` in sequence
- [ ] Record results: success/failure, return values, timing
- [ ] Stop on first command failure (unless test specifies continue)

**4.4 - Differential Validator**
- [ ] Create `src/lua/testing/differential_validator.lua`
- [ ] Implements `validate_replay(original_json, replay_capture)`
- [ ] Compare command sequences (names, order, count)
- [ ] Compare command results (success/failure, error messages, clamped values)
- [ ] Compare database states (SQL diff of before/after snapshots)
- [ ] Compare log output (warning/error messages)
- [ ] Generate detailed diff report

**4.5 - Test Runner**
- [ ] Create `src/lua/testing/test_runner_mocked.lua`
- [ ] Accepts test file path or directory
- [ ] Loads test JSON
- [ ] Sets up mock database from test setup
- [ ] Executes commands
- [ ] Validates results (differential comparison)
- [ ] Prints pass/fail with detailed report
- [ ] Returns exit code (0 = pass, 1 = fail)

**4.6 - CLI Integration**
- [ ] Add `--run-tests <path>` command line flag
- [ ] Launches headless (no Qt GUI)
- [ ] Runs all tests in specified directory
- [ ] Prints summary: X passed, Y failed
- [ ] Exits with appropriate code

**Deliverable**: Can run captured bug reports as regression tests in <1 second each.

**Testing**:
- Convert 3 existing hand-coded tests to JSON format
- Run with mocked test runner
- Verify tests pass
- Introduce intentional bug, verify test fails with clear diff
- Run 100 tests, verify completes in <10 seconds

---

## Phase 5: GUI Test Runner (Week 4-6)

**Goal**: Pixel-perfect gesture replay on actual running JVE instance.

### Tasks

**5.1 - Test Mode Server (Lua)**
- [ ] Create `src/lua/core/test_mode_server.lua`
- [ ] Opens Unix socket `/tmp/jve-test-{pid}.sock`
- [ ] Implements JSON-RPC protocol
- [ ] Commands: `execute_command`, `get_database_state`, `take_screenshot`, `get_log_tail`, `shutdown`
- [ ] Integrates with Qt event loop (non-blocking)
- [ ] Sends "ready" signal after each command completes

**5.2 - Test Mode Flag**
- [ ] Add `--test-mode` command line flag
- [ ] Launches JVE normally but starts test_mode_server
- [ ] Prints socket path to stdout for client to connect
- [ ] Waits for commands instead of accepting user input

**5.3 - Gesture Replay Engine (Lua)**
- [ ] Create `src/lua/testing/gesture_replay_engine.lua`
- [ ] Implements `replay_gesture(gesture)` → sends Qt events
- [ ] Maps gesture types to Qt events (QMouseEvent, QKeyEvent)
- [ ] Uses window-relative coordinates from JSON
- [ ] Respects timing (delays between gestures)
- [ ] Qt binding: `lua_post_mouse_event(x, y, button, modifiers)`
- [ ] Qt binding: `lua_post_key_event(key, modifiers, press_or_release)`

**5.4 - JVE Puppeteer (Lua)**
- [ ] Create `src/lua/testing/jve_puppeteer.lua`
- [ ] Launches JVE in `--test-mode`
- [ ] Parses socket path from stdout
- [ ] Connects to Unix socket
- [ ] Implements RPC client: send command, wait for response
- [ ] Implements `restore_window_geometry(geometry)` - positions window exactly
- [ ] Implements `replay_gestures(gesture_log)` - replays all gestures with timing
- [ ] Implements `wait_for_ready()` - blocks until JVE signals ready
- [ ] Implements `get_capture()` - retrieves gesture/command/log from JVE
- [ ] Implements `shutdown()` - gracefully closes JVE

**5.5 - Test Runner GUI**
- [ ] Create `src/lua/testing/test_runner_gui.lua`
- [ ] Loads test JSON
- [ ] Launches JVE via puppeteer
- [ ] Restores window geometry from JSON
- [ ] Loads database snapshot as starting state
- [ ] Replays gesture log pixel-by-pixel
- [ ] Retrieves resulting capture from JVE
- [ ] Compares replay vs original (differential validation)
- [ ] Shuts down JVE
- [ ] Prints pass/fail report

**5.6 - Screenshot Comparison (Optional)**
- [ ] Implement pixel-by-pixel comparison of final screenshot
- [ ] Generate visual diff (highlight changed pixels)
- [ ] Set threshold (0.1% difference = pass)
- [ ] Store failed screenshots for manual review

**Deliverable**: Can replay captured bug reports on actual JVE GUI, verify identical results.

**Testing**:
- Create simple test: click, drag clip, verify result
- Run in GUI mode, verify gestures replay correctly
- Verify command log matches original
- Verify database state matches original
- Test with 10-minute capture (300 screenshots, 50 gestures)

---

## Phase 6: YouTube & GitHub Integration (Week 6-7)

**Goal**: One-click bug submission to GitHub with YouTube video.

### Tasks

**6.1 - HTTP Client (Lua)**
- [ ] Choose HTTP library (LuaSocket, curl via luasec, or ffi bindings)
- [ ] Implement `http_get(url, headers)`
- [ ] Implement `http_post(url, headers, body)`
- [ ] Implement `http_multipart_post(url, headers, parts)` for file uploads
- [ ] Handle OAuth2 redirects and response parsing

**6.2 - Local Web Server (Lua)**
- [ ] Implement `start_local_server(port)` for OAuth callback
- [ ] Listens on `http://localhost:8080`
- [ ] Waits for GET request with `?code=...` parameter
- [ ] Extracts authorization code
- [ ] Returns simple HTML: "Authorization successful, you can close this window"
- [ ] Shuts down server after receiving callback

**6.3 - YouTube OAuth Flow**
- [ ] Implement `youtube_oauth_flow()` in `src/lua/integrations/youtube.lua`
- [ ] Opens browser to Google OAuth consent screen
- [ ] Starts local server on port 8080
- [ ] Waits for callback with authorization code
- [ ] Exchanges code for access token and refresh token
- [ ] Stores tokens in settings/database
- [ ] Returns access token

**6.4 - YouTube Upload**
- [ ] Implement `youtube_upload_video(video_path, metadata)`
- [ ] Checks if access token valid (not expired)
- [ ] Refreshes token if needed
- [ ] Uploads video via YouTube Data API v3
- [ ] Sets privacy to "unlisted"
- [ ] Sets title, description, tags from metadata
- [ ] Returns YouTube URL or error message
- [ ] Handles rate limits and upload failures gracefully

**6.5 - GitHub Issue Creation**
- [ ] Implement `github_create_issue(bug_report)` in `src/lua/integrations/github.lua`
- [ ] Requires GitHub personal access token (stored in settings)
- [ ] Uploads capture JSON as gist (or GitHub release attachment)
- [ ] Creates issue via GitHub API
- [ ] Formats issue body with markdown template
- [ ] Includes YouTube video link, artifact links, command history
- [ ] Returns issue URL

**6.6 - Bug Submission Dialog**
- [ ] Create dialog with video player (shows slideshow)
- [ ] Show summary stats (gesture count, command count, etc.)
- [ ] Editable text field for user description
- [ ] Checkboxes: "Include database snapshots", "Upload video to YouTube"
- [ ] Buttons: "Submit to GitHub", "Save Locally", "Cancel"
- [ ] Progress indicator during upload (YouTube upload can take minutes)
- [ ] Success message with issue URL
- [ ] Error handling with actionable messages

**Deliverable**: Users can submit bug reports to GitHub with one click, including YouTube video.

**Testing**:
- Create test YouTube account
- Run OAuth flow, verify browser opens and callback works
- Upload test video (30 seconds), verify appears on YouTube as unlisted
- Create GitHub issue with all artifacts
- Verify issue contains: description, video link, JSON artifact, command history
- Test failure cases: network down, token expired, upload failed

---

## Phase 7: UI Polish & Preferences (Week 7)

**Goal**: Professional UI for capture preferences and bug submission.

### Tasks

**7.1 - Preferences Panel**
- [ ] Add "Bug Reporting" section to preferences dialog
- [ ] Checkbox: "Enable automatic capture" (default: true)
- [ ] Slider: "Capture interval" (1-10 seconds, default: 1)
- [ ] Slider: "Capture duration" (1-15 minutes, default: 5)
- [ ] Label: "Estimated memory usage: 15-30 MB"
- [ ] Checkbox: "Show notification when bug captured" (default: true)
- [ ] Text field: "GitHub personal access token" (for issue creation)
- [ ] Button: "Authenticate with YouTube" (runs OAuth flow)
- [ ] Status indicator: "YouTube: Connected as user@example.com"

**7.2 - Notification Dialog**
- [ ] Show when automatic capture triggers
- [ ] Title: "JVE Bug Captured"
- [ ] Message: "A test case has been generated from this error"
- [ ] Buttons: "Submit Report", "Review Capture", "Dismiss"
- [ ] "Submit Report" → opens bug submission dialog
- [ ] "Review Capture" → opens JSON file and slideshow in external apps
- [ ] "Dismiss" → closes dialog

**7.3 - Bug Submission Dialog Polish**
- [ ] Better layout (1200x800 window)
- [ ] Left panel: Video player (800x600)
  - Play/pause controls
  - Seek bar
  - Speed control (0.5x, 1x, 2x)
- [ ] Right panel: Details (400x600)
  - Summary stats (read-only)
  - User description (editable multi-line)
  - Expected behavior (editable multi-line)
  - Checkboxes (database, YouTube)
  - Action buttons
- [ ] Progress bar during upload
- [ ] Disable buttons during upload (prevent double-click)
- [ ] Error messages as inline alerts (not dialogs)

**7.4 - Documentation**
- [ ] User guide: "How to Report Bugs"
- [ ] Developer guide: "How to Write Tests"
- [ ] FAQ: Common issues and solutions
- [ ] Add help links to dialogs

**Deliverable**: Professional, polished user experience for bug reporting.

**Testing**:
- User testing: give to 3-5 users, observe workflow
- Verify all edge cases handled gracefully
- Verify error messages are actionable
- Verify progress indicators work correctly

---

## Phase 8: Test Conversion & CI Integration (Week 8)

**Goal**: Convert existing tests, integrate with CI pipeline.

### Tasks

**8.1 - Test Converter**
- [ ] Create `convert_lua_test_to_json.lua` script
- [ ] Parses existing Lua test files
- [ ] Extracts setup code (clips, tracks)
- [ ] Extracts command execution calls
- [ ] Extracts assertions
- [ ] Generates equivalent JSON test
- [ ] Validates converted test runs and passes

**8.2 - Batch Conversion**
- [ ] Identify all existing tests in `tests/` directory (21 files)
- [ ] Run converter on each test
- [ ] Verify each converted test passes in mocked environment
- [ ] Compare results: original Lua test vs converted JSON test
- [ ] Fix any conversion issues
- [ ] Store JSON tests in `tests/json/`

**8.3 - CMake Integration**
- [ ] Add custom target `make test-mocked`
- [ ] Runs test_runner_mocked on all tests in `tests/json/`
- [ ] Reports pass/fail summary
- [ ] Fails build if any test fails

**8.4 - CI Pipeline**
- [ ] Add GitHub Actions workflow
- [ ] Runs on every commit to main branch
- [ ] Builds JVE
- [ ] Runs all mocked tests
- [ ] Fails CI if any test fails
- [ ] Posts test results as comment on PR

**8.5 - Nightly GUI Tests**
- [ ] Add GitHub Actions workflow (scheduled nightly)
- [ ] Runs GUI test runner on subset of critical tests
- [ ] Takes longer (5-10 minutes) so not on every commit
- [ ] Stores screenshots on failure
- [ ] Sends notification if failures detected

**8.6 - Deprecate Legacy Tests**
- [ ] Move old Lua test files to `tests/legacy/`
- [ ] Update documentation to point to JSON tests
- [ ] Add deprecation warning to old test files
- [ ] Plan for eventual removal (after 1-2 releases of stability)

**Deliverable**: All existing tests converted to JSON format, running in CI on every commit.

**Testing**:
- Run full test suite locally, verify all pass
- Trigger CI on test branch, verify tests run
- Introduce intentional regression, verify CI catches it
- Check CI run time (<5 minutes for mocked tests)

---

## Summary Timeline

| Phase | Description | Duration | Dependencies |
|-------|-------------|----------|--------------|
| 0 | Prerequisites & Foundation | 1 week | None |
| 1 | Continuous Ring Buffer Capture | 1-2 weeks | Phase 0 |
| 2 | JSON Test Export | 1 week | Phase 1 |
| 3 | Slideshow Video Generation | 1 week | Phase 2 |
| 4 | Mocked Test Runner | 1-2 weeks | Phase 2 |
| 5 | GUI Test Runner | 2-3 weeks | Phase 2, 4 |
| 6 | YouTube & GitHub Integration | 1-2 weeks | Phase 3 |
| 7 | UI Polish & Preferences | 1 week | Phase 6 |
| 8 | Test Conversion & CI | 1 week | Phase 4, 5 |

**Total Estimated Duration**: 8-10 weeks (2-2.5 months)

**Critical Path**: Phase 0 → 1 → 2 → 4 → 5 → 8

**Parallelizable Work**:
- Phase 3 (slideshow) can happen in parallel with Phase 4 (mocked tests)
- Phase 6 (YouTube/GitHub) can happen in parallel with Phase 5 (GUI tests)
- Phase 7 (UI polish) can happen last, in parallel with Phase 8 (CI integration)

---

## Quick Wins (First 2 Weeks)

Prioritize these for early value:

1. **Week 1**: Phase 0 + Phase 1 → Continuous capture works
   - Immediate benefit: When bug occurs, we have context
   - Can manually inspect ring buffers even without export

2. **Week 2**: Phase 2 → JSON export works
   - Immediate benefit: Automatic bug reports captured to disk
   - Can manually send JSON files in bug reports

3. **Week 2**: Phase 3 → Slideshow videos
   - Immediate benefit: Easy visual review of what happened
   - Better than clicking through 300 screenshots

After these 3 phases (2 weeks), the system is already valuable:
- ✅ Automatic capture when errors occur
- ✅ Complete context: gestures, commands, logs, database, screenshots
- ✅ Slideshow video for quick review
- ✅ Manual capture on demand
- ⚠️ No automated testing yet (comes in Phase 4-5)
- ⚠️ Manual submission to GitHub (comes in Phase 6)

---

## Risk Mitigation

**Risk 1: Qt Event Injection Doesn't Work**
- **Mitigation**: Test early in Phase 5.1, have fallback plan
- **Fallback**: Use platform-specific automation (macOS: CGEventPost, Linux: XTest, Windows: SendInput)

**Risk 2: YouTube Upload Quota Limits**
- **Mitigation**: Users upload with their own accounts (distributed quota)
- **Fallback**: Support direct file attachment or alternative hosts (Vimeo, S3)

**Risk 3: Differential Testing False Positives**
- **Mitigation**: Start with loose tolerances, tighten over time
- **Fallback**: Allow tests to specify tolerance levels per assertion

**Risk 4: Memory Usage Too High**
- **Mitigation**: Monitor in Phase 1, adjust buffer sizes if needed
- **Fallback**: Reduce screenshot frequency or resolution, compress earlier

**Risk 5: ffmpeg Not Available**
- **Mitigation**: Check during Phase 3, provide installation instructions
- **Fallback**: Bundle ffmpeg binary with JVE distribution

---

## Success Metrics

**Phase 1-3** (Capture System):
- ✅ Captures last 5 minutes of activity continuously
- ✅ Memory usage <50MB
- ✅ No performance impact on normal editing
- ✅ Automatic capture on all errors
- ✅ Manual capture works on demand
- ✅ Slideshow videos viewable in standard players

**Phase 4-5** (Test Runners):
- ✅ Mocked tests run at >10 tests/second
- ✅ GUI tests replay pixel-perfectly
- ✅ Differential validation catches regressions
- ✅ Clear, actionable failure reports

**Phase 6-7** (Integration & Polish):
- ✅ YouTube upload works reliably
- ✅ One-click GitHub issue creation
- ✅ Professional, polished UI
- ✅ Users can submit bug reports in <2 minutes

**Phase 8** (CI):
- ✅ All 21 existing tests converted
- ✅ Tests run on every commit
- ✅ CI run time <5 minutes
- ✅ Zero false positives in first month

---

## Post-Launch Improvements (Future)

After initial 8-10 week implementation:

1. **Test Coverage Dashboard**
   - Visual display of which code paths are covered by tests
   - Identify gaps in test coverage

2. **Automatic Test Generation**
   - Record user workflows during beta testing
   - Convert to regression tests automatically

3. **Performance Regression Detection**
   - Track command execution timing over time
   - Alert when operations get slower

4. **Cross-Platform Testing**
   - Run GUI tests on macOS, Linux, Windows
   - Detect platform-specific bugs

5. **Fuzzing Integration**
   - Generate random gesture sequences
   - Catch edge cases and crashes

6. **Test Minimization**
   - Reduce captured tests to minimal reproduction steps
   - Shorter tests = faster debugging

---

## Implementation Strategy

**Recommended Approach**: Linear phases with early testing integration.

**Week 1**: Foundation (Phase 0)
- Build C++ infrastructure
- Test each component independently
- Verify memory management

**Week 2-3**: Capture System (Phase 1-3)
- Build ring buffer system
- Wire into existing code
- Generate first bug reports manually
- Verify JSON format correctness

**Week 4-5**: Mocked Tests (Phase 4)
- Build test runner
- Convert 3 sample tests
- Verify differential validation works
- Iterate on validator logic

**Week 6-8**: GUI Tests (Phase 5)
- Build puppeteer system
- Test gesture replay on simple cases
- Add complex multi-gesture tests
- Handle timing and synchronization issues

**Week 9**: Integration (Phase 6)
- YouTube OAuth and upload
- GitHub issue creation
- Test end-to-end workflow

**Week 10**: Polish (Phase 7-8)
- UI improvements
- Convert all tests
- Set up CI
- Documentation

This creates continuous value delivery: useful partial system after 2 weeks, complete system after 10 weeks.
