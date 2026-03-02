--- UI test environment for end-to-end tests that launch the full application.
--
-- Runs via `JVEEditor --test`. Creates a test database with known content,
-- sets JVE_PROJECT_PATH, then requires layout.lua to create the full window
-- with all panels. Provides assertion helpers for widget state.
--
-- Usage:
--   local ui = require("integration.ui_test_env")
--   local app = ui.launch({ project_name = "Test", num_sequences = 3 })
--   ui.assert_size_in_range(app.main_window, "main_window", 800, 3000, 400, 2000)
--   ui.assert_no_panel_dominates(app)
--   print("✅ test passed")
--
-- These tests auto-discover via run_integration_tests.sh alongside other
-- integration tests. They require a display (not headless CI).

local M = {}

-- Verify we're running inside JVEEditor with real Qt bindings
assert(type(qt_constants) == "table",
    "ui_test_env: must run via JVEEditor --test")
assert(type(qt_constants.WIDGET) == "table",
    "ui_test_env: qt_constants.WIDGET not found")
assert(type(qt_constants.PROPERTIES) == "table",
    "ui_test_env: qt_constants.PROPERTIES not found")
assert(type(qt_constants.CONTROL) == "table",
    "ui_test_env: qt_constants.CONTROL not found")
assert(type(qt_constants.LAYOUT) == "table",
    "ui_test_env: qt_constants.LAYOUT not found")

--------------------------------------------------------------------------------
-- FFI env var helpers (POSIX setenv/unsetenv via LuaJIT FFI)
--------------------------------------------------------------------------------

local ffi = require("ffi")
ffi.cdef[[
    int setenv(const char *name, const char *value, int overwrite);
    int unsetenv(const char *name);
]]

local function setenv(name, value)
    local rc = ffi.C.setenv(name, value, 1)
    assert(rc == 0, "ui_test_env: setenv failed for " .. name)
end

local saved_home = nil

--------------------------------------------------------------------------------
-- Test project creation
--------------------------------------------------------------------------------

--- Create a test project database with known content.
-- @param opts table:
--   db_path        string  — SQLite path (default: /tmp/jve/test_ui.jvp)
--   project_name   string  — project display name (default: "UI Test Project")
--   num_sequences  number  — how many sequences to create (default: 1)
--   sequence_names table   — names for each sequence (optional)
--   active_sequence number — 1-based index of active sequence (default: 1)
-- @return table { db_path, project, sequences }
function M.create_test_project(opts)
    opts = opts or {}
    local db_path = opts.db_path or "/tmp/jve/test_ui.jvp"

    -- Clean up previous test database
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    os.execute("mkdir -p /tmp/jve")

    -- Initialize database
    local db = require("core.database")
    db.init(db_path)

    -- Create project
    local Project = require("models.project")
    local project = Project.create(opts.project_name or "UI Test Project")
    project:save()

    -- Create sequences with tracks
    local Sequence = require("models.sequence")
    local Track = require("models.track")
    local sequences = {}
    local num = opts.num_sequences or 1

    for i = 1, num do
        local name = (opts.sequence_names and opts.sequence_names[i])
            or ("Sequence " .. i)
        local seq = Sequence.create(name, project.id,
            { fps_numerator = 24, fps_denominator = 1 },
            1920, 1080)
        seq:save()

        -- Each sequence needs at least one video track for timeline_panel
        local track = Track.create_video("V1", seq.id, { index = 1 })
        track:save()

        sequences[i] = seq
    end

    -- Set active sequence
    local active_idx = opts.active_sequence or 1
    if sequences[active_idx] then
        db.set_project_setting(project.id, "last_open_sequence_id",
            sequences[active_idx].id)
    end

    return {
        db_path = db_path,
        project = project,
        sequences = sequences,
    }
end

--------------------------------------------------------------------------------
-- App launch
--------------------------------------------------------------------------------

--- Launch the full application UI.
-- Creates a test project, sets env vars, requires layout.lua.
-- @param opts same as create_test_project
-- @return app table (widget references from layout.lua), project_info table
function M.launch(opts)
    -- Capture real HOME for luarocks paths BEFORE we change HOME
    saved_home = os.getenv("HOME")

    -- Pre-load luarocks cpath using real HOME (layout.lua will try with fake HOME)
    package.cpath = package.cpath .. ';' .. saved_home .. '/.luarocks/lib/lua/5.1/?.so'
    package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?.lua'
    package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?/init.lua'

    -- Isolate test from user's home directory (prevents overwriting ~/.jve/last_project_path)
    local test_home = "/tmp/jve_test_home"
    os.execute("mkdir -p " .. test_home .. "/.jve")
    setenv("HOME", test_home)

    -- Create test project
    local project_info = M.create_test_project(opts)

    -- Set project path so layout.lua skips welcome screen
    setenv("JVE_PROJECT_PATH", project_info.db_path)

    -- Launch the full UI (creates window, panels, menus, everything)
    local app = require("ui.layout")
    assert(type(app) == "table",
        "ui_test_env: layout.lua must return a table (got " .. type(app) .. ")")
    assert(app.main_window,
        "ui_test_env: layout.lua did not return main_window")
    assert(app.top_splitter,
        "ui_test_env: layout.lua did not return top_splitter")
    assert(app.main_splitter,
        "ui_test_env: layout.lua did not return main_splitter")

    -- Let layout settle: pump events to fire the 50ms splitter-size timer
    M.pump(200)

    return app, project_info
end

--------------------------------------------------------------------------------
-- Event loop helpers
--------------------------------------------------------------------------------

--- Pump Qt event loop for at least `ms` milliseconds.
-- Ensures timers and deferred callbacks fire.
function M.pump(ms)
    ms = ms or 100
    local start = os.clock()
    local target = start + (ms / 1000.0)
    while os.clock() < target do
        qt_constants.CONTROL.PROCESS_EVENTS()
    end
end

--------------------------------------------------------------------------------
-- Assertion helpers
--------------------------------------------------------------------------------

--- Assert widget dimensions are within bounds.
-- @return width, height (for chaining)
function M.assert_size_in_range(widget, label, min_w, max_w, min_h, max_h)
    local w, h = qt_constants.PROPERTIES.GET_SIZE(widget)
    assert(w >= min_w,
        string.format("%s: width %d < min %d", label, w, min_w))
    assert(w <= max_w,
        string.format("%s: width %d > max %d", label, w, max_w))
    assert(h >= min_h,
        string.format("%s: height %d < min %d", label, h, min_h))
    assert(h <= max_h,
        string.format("%s: height %d > max %d", label, h, max_h))
    return w, h
end

--- Assert no single top panel takes more than max_fraction of the window width.
-- Catches the exact regression where project_browser was 22300px wide.
function M.assert_no_panel_dominates(app, max_fraction)
    max_fraction = max_fraction or 0.6
    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(app.top_splitter)
    assert(#sizes == 4,
        string.format("top splitter: expected 4 panels, got %d", #sizes))

    local total = 0
    for _, s in ipairs(sizes) do total = total + s end
    assert(total > 0, "top splitter total width is zero")

    local panel_names = {"project_browser", "source_monitor", "timeline_monitor", "inspector"}
    for i, s in ipairs(sizes) do
        local fraction = s / total
        assert(fraction <= max_fraction,
            string.format("%s takes %.0f%% of width (max %.0f%%)",
                panel_names[i], fraction * 100, max_fraction * 100))
        assert(s > 0,
            string.format("%s has zero width", panel_names[i]))
    end
end

--- Assert splitter has expected panel count. Returns the sizes table.
function M.assert_splitter_count(splitter, label, expected)
    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(splitter)
    assert(#sizes == expected,
        string.format("%s: expected %d panels, got %d", label, expected, #sizes))
    return sizes
end

--- Assert two values are equal with context.
function M.assert_eq(actual, expected, label)
    assert(actual == expected,
        string.format("%s: expected %s, got %s",
            label, tostring(expected), tostring(actual)))
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

--- Restore environment after test.
function M.cleanup()
    ffi.C.unsetenv("JVE_PROJECT_PATH")
    if saved_home then
        setenv("HOME", saved_home)
    end
end

return M
