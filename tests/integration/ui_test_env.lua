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
    -- Each test gets a unique DB path to avoid collisions under parallel runners.
    -- Derive from project_name (sanitized) for uniqueness across tests.
    local db_path = opts.db_path
    if not db_path then
        local name = (opts.project_name or "ui_test"):gsub("[^%w_-]", "_"):lower()
        db_path = string.format("/tmp/jve/test_%s.jvp", name)
    end

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
    local project = Project.create(opts.project_name or "UI Test Project",
        { fps_mismatch_policy = "passthrough" })
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
            1920, 1080,
            { kind = "sequence", audio_sample_rate = 48000 })
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
--
-- Builds the test .jvp on disk via `project_templates.create_project_from_template`
-- (the same primitive NewProject uses non-interactively), then sets
-- JVE_PROJECT_PATH and requires `ui.layout` — that single layout.lua
-- startup is the only DB open, so the full `project_changed` signal
-- cascade fires exactly once. Customization (rename default sequence,
-- add more, switch active) happens AFTER the UI is up, via commands
-- (`SetSequenceMetadata` / `CreateSequence` / `OpenSequenceInTimeline`)
-- — the same path a real user takes. Replaces the prior
-- `database.init` + raw `Project/Sequence.create():save()` bootstrap
-- which bypassed signals and was the cascade source breaking batched
-- runs (see todo_tests_migrate_to_openproject memory).
--
-- @param opts table:
--   db_path         string  — SQLite path (default: derived from project_name)
--   project_name    string  — default: "UI Test Project"
--   num_sequences   number  — default: 1 (the template's default counts as #1)
--   sequence_names  table   — names for each sequence (optional; defaults to
--                             template default for #1, "Sequence N" for extras)
--   active_sequence number  — 1-based active sequence index (default: 1)
-- @return app table (from layout.lua), project_info table {db_path, project, sequences}
function M.launch(opts)
    opts = opts or {}

    -- Capture real HOME for luarocks paths BEFORE we change HOME
    saved_home = os.getenv("HOME")
    package.cpath = package.cpath .. ';' .. saved_home .. '/.luarocks/lib/lua/5.1/?.so'
    package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?.lua'
    package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?/init.lua'

    local test_home = "/tmp/jve_test_home"
    os.execute("mkdir -p " .. test_home .. "/.jve")
    setenv("HOME", test_home)

    local project_name = opts.project_name or "UI Test Project"
    local db_path = opts.db_path
    if not db_path then
        local sanitized = project_name:gsub("[^%w_-]", "_"):lower()
        db_path = string.format("/tmp/jve/test_%s.jvp", sanitized)
    end
    os.execute("mkdir -p /tmp/jve")

    -- Create + open the .jvp via the user-visible primitive. blank_project
    -- wipes the path, calls create_project_from_template, then executes
    -- the OpenProject command — exactly the path a real user takes through
    -- New Project / Open Project, with the full project_changed signal
    -- cascade firing. This is the first OpenProject of the session — its
    -- post_open_init tolerates the missing-UI state because
    -- panel_manager.get_persistable_sizes returns nil when not initialized.
    local blank_project = require("tests.helpers.blank_project")
    local opened = blank_project.open_fresh(db_path, {
        template_name = "Film 24fps",
        project_name  = project_name,
    })
    local template = opened.template
    local project_id = opened.project_id
    local default_seq_id = opened.sequence_id

    local command_manager = require("core.command_manager")
    local database = require("core.database")
    local uuid = require("uuid")

    local sequence_names = opts.sequence_names or {}
    local num_sequences = opts.num_sequences or 1
    local active_idx = opts.active_sequence or 1
    local sequences = { { id = default_seq_id, name = "Sequence 1" } }

    -- Rename the template default if a name was requested.
    local first_name = sequence_names[1]
    if first_name then
        local rr = command_manager.execute("SetSequenceMetadata", {
            project_id  = project_id,
            sequence_id = default_seq_id,
            field       = "name",
            value       = first_name,
        })
        assert(rr and rr.success,
            "ui_test_env: rename default sequence failed: " ..
            tostring(rr and rr.error_message or "(nil)"))
        sequences[1].name = first_name
    end

    -- Additional sequences via CreateSequence.
    for i = 2, num_sequences do
        local name = sequence_names[i] or ("Sequence " .. i)
        local new_id = uuid.generate()
        local rr = command_manager.execute("CreateSequence", {
            project_id        = project_id,
            sequence_id       = new_id,
            name              = name,
            frame_rate        = { fps_numerator = template.fps_num, fps_denominator = template.fps_den },
            audio_sample_rate = template.audio_sample_rate,
            width             = template.width,
            height            = template.height,
        })
        assert(rr and rr.success,
            "ui_test_env: CreateSequence failed for " .. name .. ": " ..
            tostring(rr and rr.error_message or "(nil)"))
        sequences[i] = { id = new_id, name = name }
    end

    -- Persist which sequence should be active on next open. This setting is
    -- the natural "remember session" state every user-driven sequence switch
    -- writes; setting it directly here is fixture session state, not a
    -- model mutation. layout.lua reads it via Sequence.resolve_initial_for
    -- _project when it opens.
    if sequences[active_idx] then
        database.set_project_setting(project_id, "last_open_sequence_id",
            sequences[active_idx].id)
    end

    -- Hand off to layout.lua. It runs its own OpenProject path (close
    -- current → open same file → resolve active sequence → init
    -- command_manager → build UI). Wasteful but harmless — the on-disk
    -- state is what counts, and layout captures app.active_sequence_id
    -- AT this open, so it sees the active sequence we just prepared.
    setenv("JVE_PROJECT_PATH", db_path)
    local app = require("ui.layout")
    assert(type(app) == "table",
        "ui_test_env: layout.lua must return a table (got " .. type(app) .. ")")
    assert(app.main_window,
        "ui_test_env: layout.lua did not return main_window")
    assert(app.top_splitter,
        "ui_test_env: layout.lua did not return top_splitter")
    assert(app.main_splitter,
        "ui_test_env: layout.lua did not return main_splitter")
    M.pump(200)

    return app, {
        db_path   = db_path,
        project   = { id = project_id, name = project_name },
        sequences = sequences,
    }
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
