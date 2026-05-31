local M = {}

-- Ensure repo lua modules are on the path (core, dkjson, etc.)
local repo_root
do
    local here = debug.getinfo(1, "S").source:sub(2)
    local prefix = here:match("^(.*)/tests/test_env.lua$")
    if (not prefix or prefix == "") then
        local search_path = package.searchpath("test_env", package.path)
        if search_path then
            prefix = search_path:match("^(.*)/tests/test_env.lua$")
        end
    end
    if not prefix or prefix == "" then
        prefix = "."
    end
    repo_root = prefix
    local function ensure_absolute(path)
        if path:sub(1, 1) == "/" then
            return path
        end
        local handle = assert(io.popen("pwd", "r"))
        local cwd = handle:read("*l")
        handle:close()
        return cwd .. "/" .. path
    end
    repo_root = ensure_absolute(repo_root)
    local function normalize(path)
        local parts = {}
        for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
        local absolute = path:sub(1, 1) == "/"
        local out = {}
        for _, part in ipairs(parts) do
            if part == ".." then
                if #out > 0 then out[#out] = nil end
            elseif part ~= "." and part ~= "" then
                out[#out + 1] = part
            end
        end
        if absolute then
            return "/" .. table.concat(out, "/")
        else
            return table.concat(out, "/")
        end
    end
    repo_root = normalize(repo_root)
    repo_root = repo_root:gsub("/tests$", "")
    local paths = {
        repo_root .. "/?.lua",
        repo_root .. "/?/init.lua",
        repo_root .. "/src/lua/?.lua",
        repo_root .. "/src/lua/?/init.lua",
        repo_root .. "/tests/?.lua",
        repo_root .. "/tests/?/init.lua",
        repo_root .. "/../src/lua/?.lua",
        repo_root .. "/../src/lua/?/init.lua",
    }
    package.path = table.concat(paths, ";") .. ";" .. package.path
end
M.repo_root = repo_root

function M.resolve_repo_path(relative)
    if not relative or relative == "" then return repo_root end
    if relative:sub(1, 1) == "/" then return relative end
    return repo_root .. "/" .. relative
end

--- Touch every path in the current DB's `media` table so that reachability
--- checks (io.open, etc.) see the fixtures as online. Used by tests that
--- exercise the resolver or renderer with synthetic media rows.
--- Creates parent directories as needed. Safe to call more than once.
function M.touch_media_fixtures()
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "touch_media_fixtures: no database connection")
    local stmt = db:prepare("SELECT file_path FROM media")
    assert(stmt and stmt:exec(), "touch_media_fixtures: query failed")
    while stmt:next() do
        local path = stmt:value(0)
        if path and path ~= "" then
            local dir = path:match("(.*)/")
            if dir and dir ~= "" then os.execute("mkdir -p " .. dir) end
            local fh = io.open(path, "a")
            if fh then fh:close() end
        end
    end
    stmt:finalize()
end

--- Resolve a fixture path and ASSERT it exists. Tests must not silently pass
--- when their fixture files are missing.
function M.require_fixture(relative)
    local path = M.resolve_repo_path(relative)
    local f = io.open(path, "r")
    assert(f, string.format("FIXTURE MISSING: %s\n  Tests must not silently pass with missing fixtures.", path))
    f:close()
    return path
end

-- Provide deterministic JSON helpers via bundled dkjson
local function ensure_json_helpers()
    if _G.qt_json_encode and _G.qt_json_decode then
        return
    end

    local ok, dkjson = pcall(require, "dkjson")
    if not ok then
        error("dkjson module is required for Lua regression tests: " .. tostring(dkjson))
    end

    if not _G.qt_json_encode then
        _G.qt_json_encode = function(value)
            local encoded, err = dkjson.encode(value)
            if not encoded then
                error(err or "qt_json_encode failed")
            end
            return encoded
        end
    end

    if not _G.qt_json_decode then
        _G.qt_json_decode = function(str)
            local decoded, _, err = dkjson.decode(str)
            if err then
                error(err)
            end
            return decoded
        end
    end
end

-- Provide a stub for the Qt single-shot timer used for UI listener debouncing
local function ensure_timer_stub()
    if _G.qt_create_single_shot_timer then
        return
    end

    function _G.qt_create_single_shot_timer(_, callback)
        if callback then
            callback()
        end
        return {}
    end
end

ensure_json_helpers()
ensure_timer_stub()

-- Ensure temp workspace exists for all tests
do
    local tmp_root = "/tmp/jve"
    local ok, err = pcall(function() return os.execute(string.format("mkdir -p %q", tmp_root)) end)
    if not ok then
        -- Best-effort; tests that need it will fail loudly otherwise
        io.stderr:write("WARNING: failed to create ", tmp_root, ": ", tostring(err), "\n")
    end
end

-- Force nil calls to raise useful errors (parity with layout.lua)
local function enforce_nil_call_protection()
    if not debug or not debug.setmetatable then
        return
    end

    local current = getmetatable(nil) or {}
    if current.__call == nil then
        current.__call = function()
            error("attempt to call nil value", 2)
        end
        debug.setmetatable(nil, current)
    end
end

enforce_nil_call_protection()

-- Provide qt_monotonic_s for plain-luajit test runs. The native binding
-- (misc_bindings.cpp) uses std::chrono::steady_clock; under the editor
-- it's registered globally at startup. Tests under luajit don't load
-- the C++ bindings, so we substitute a wall-clock source via FFI to
-- POSIX clock_gettime(CLOCK_MONOTONIC). MUST be wall time — earlier
-- versions used os.clock() (process CPU time), which silently misled
-- any test that measured gesture-gap or idle-period behavior because
-- CPU time barely advances when the app is idle.
if not _G.qt_monotonic_s then
    local ffi = require("ffi")
    pcall(ffi.cdef, [[
        typedef long time_t;
        struct timespec { time_t tv_sec; long tv_nsec; };
        int clock_gettime(int clk_id, struct timespec *tp);
    ]])
    -- macOS: CLOCK_MONOTONIC=6; Linux: CLOCK_MONOTONIC=1.
    local clk_id = (jit.os == "OSX") and 6 or 1
    local ts = ffi.new("struct timespec[1]")
    _G.qt_monotonic_s = function()
        ffi.C.clock_gettime(clk_id, ts)
        return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) * 1e-9
    end
end

-- Provide qt_file_mtime for plain-luajit test runs. Production registers
-- the C++ binding (misc_bindings.cpp::lua_qt_file_mtime), which calls
-- POSIX stat(2) directly for nanosecond precision. The headless harness
-- can't link Qt, so we shell out to `stat` here. fs_utils.file_mtime
-- now assumes the binding exists — the stub keeps the same global
-- contract so tests don't need to know which environment they run in.
-- stat's format flag is platform-split (same OS branch as the monotonic
-- clock above): macOS/BSD use `-f %Fm`, GNU/Linux use `-c %.Y`. Both
-- emit a fractional epoch, matching the binding's sub-second resolution.
-- Without this branch the macOS form silently returns nil on Linux,
-- which also blinds media_status's in-place-rewrite mtime comparison.
if not _G.qt_file_mtime then
    local stat_fmt = (jit.os == "OSX" or jit.os == "BSD")
        and "stat -f %%Fm %q 2>/dev/null"
        or  "stat -c %%.Y %q 2>/dev/null"
    _G.qt_file_mtime = function(path)
        if type(path) ~= "string" or path == "" then return nil end
        local handle = io.popen(string.format(stat_fmt, path))
        if not handle then return nil end
        local data = handle:read("*a") or ""
        local close_ok = handle:close()
        if not close_ok then return nil end
        local mtime = tonumber((data:gsub("%s+$", "")))
        return mtime
    end
end

-- Lightweight dependency guards for tests
local function enforce(expected, fn)
    if type(fn) ~= "function" then
        error(string.format("Missing required dependency '%s'", tostring(expected)), 3)
    end
    return fn
end

local function enforce_table(tbl, specs)
    if type(tbl) ~= "table" or type(specs) ~= "table" then
        return
    end
    for key, descriptor in pairs(specs) do
        local expected = descriptor or key
        local candidate = tbl[key]
        tbl[key] = enforce(expected, candidate)
    end
end

M.enforce = enforce
M.enforce_table = enforce_table

--------------------------------------------------------------------------------
-- Error Path Testing Helpers (NSF compliance)
--------------------------------------------------------------------------------

--- Test that a function raises an error.
-- @param fn Function to call (should error)
-- @param pattern Optional pattern the error message must match
-- @return The error message (for further inspection if needed)
-- @usage expect_error(function() module.func(nil) end, "missing required")
function M.expect_error(fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        error("expect_error: function did not raise an error", 2)
    end
    if pattern then
        local err_str = tostring(err)
        if not err_str:match(pattern) then
            error(string.format(
                "expect_error: error message did not match pattern\n  pattern: %s\n  got: %s",
                pattern, err_str), 2)
        end
    end
    return err
end

--- Assert a value is of expected type with context.
-- @param val Value to check
-- @param expected_type Expected type string ("number", "string", "table", etc.)
-- @param context Description for error message
-- @usage assert_type(clip.sequence_start, "number", "clip.sequence_start")
function M.assert_type(val, expected_type, context)
    local actual = type(val)
    if actual ~= expected_type then
        error(string.format(
            "assert_type: %s expected %s, got %s (%s)",
            context or "value", expected_type, actual, tostring(val)), 2)
    end
    return val
end

--- Execute raw SQL for test setup (bypasses normal validation).
-- Use this to inject corrupt data for testing error paths.
-- For INSERT/UPDATE, use db:exec() with string interpolation.
-- @param db Database connection
-- @param sql SQL to execute (use %q for string values that need quoting)
-- @param ... Values to substitute via string.format
-- @return true on success, raises on error
-- @usage raw_sql(db, "INSERT INTO t VALUES (%q, %d)", "text", 123)
function M.raw_sql(db, sql, ...)
    local formatted = string.format(sql, ...)
    local result = db:exec(formatted)
    if not result then
        error("raw_sql: exec failed: " .. formatted, 2)
    end
    return true
end

--------------------------------------------------------------------------------
-- Test Media Helper
--------------------------------------------------------------------------------

--- Create a Media record with proper TC metadata for testing.
-- Tests have no real files, so TC must be explicitly provided.
-- Defaults to TC=0 (00:00:00:00) — the correct value for files without a TC tag.
-- @param params table: Media.create params (id, project_id, name, file_path, etc.)
-- @return Media: saved media record
function M.create_test_media(params)
    local Media = require("models.media")
    local json = require("dkjson")
    -- Ensure TC metadata is present (no real file to extract from in tests)
    if not params.metadata then
        local fps_num = params.fps_numerator
            or (type(params.frame_rate) == "table" and params.frame_rate.fps_numerator)
            or 24
        local sr = tonumber(params.audio_sample_rate) or 0
        params.metadata = json.encode({
            start_tc_value = params.start_tc or 0,
            start_tc_rate = fps_num,
            start_tc_audio_samples = params.start_tc_audio or 0,
            start_tc_audio_rate = sr > 0 and sr or nil,
        })
    end
    local media = Media.create(params)
    assert(media, "create_test_media: Media.create returned nil")
    assert(media:save(), "create_test_media: save failed for " .. tostring(params.id))
    return media
end

--------------------------------------------------------------------------------
-- Test Masterclip Sequence Helper
--------------------------------------------------------------------------------

--- Create a masterclip sequence for testing Insert/Overwrite commands.
-- Creates the sequence, video track, and video stream clip.
-- @param project_id string: Project ID
-- @param name string: Name for sequence/clip
-- @param fps_num number: FPS numerator (e.g., 24)
-- @param fps_den number: FPS denominator (e.g., 1)
-- @param duration_frames number: Duration in frames
-- @param media_id string|nil: Optional media_id for clip
-- @return string: masterclip sequence ID
function M.create_test_masterclip_sequence(project_id, name, fps_num, fps_den, duration_frames, media_id)
    -- V13: a "masterclip" is a kind='master' sequence containing one or more
    -- media_refs. Sequence.ensure_master does the right thing — assert TC
    -- metadata is present on the Media row first (callers usually create the
    -- Media themselves; we synthesize TC=0 if absent so legacy tests keep
    -- working).
    assert(media_id and media_id ~= "",
        "create_test_masterclip_sequence: media_id is required (V13 requires a media to anchor the master)")
    local Sequence = require("models.sequence")
    local Media = require("models.media")
    local json = require("dkjson")

    local media = Media.load(media_id)
    assert(media, string.format(
        "create_test_masterclip_sequence: media_id=%s not found", tostring(media_id)))
    -- Ensure TC origin is set (V13 ensure_master asserts on it). Synthesize a
    -- TC=0 metadata blob whenever start_tc_value is absent — file-based
    -- extraction won't work with the synthetic /tmp paths used in tests.
    local existing_meta = media.metadata
    local parsed = nil
    if existing_meta and existing_meta ~= "" then
        parsed = json.decode(existing_meta)
    end
    if not parsed or parsed.start_tc_value == nil then
        local merged = parsed or {}
        merged.start_tc_value = 0
        merged.start_tc_rate = fps_num
        merged.start_tc_audio_samples = 0
        merged.start_tc_audio_rate = (media.audio_channels and media.audio_channels > 0)
            and (media.audio_sample_rate or 48000) or nil
        media.metadata = json.encode(merged)
        assert(media:save(), "create_test_masterclip_sequence: failed to update media metadata")
    end

    -- ensure_master derives duration / rate / name from the media row, so
    -- duration_frames / fps_num / fps_den / name args are unused here. Kept
    -- in the signature for back-compat with existing callers.
    return Sequence.ensure_master(media_id, project_id)
end

-- Isolate the user keymap store from the developer's real ~/.jve dir.
-- Without this, tests that load_active_or_default would pick up the
-- developer's autosave files and overlay them on the bundled Default,
-- silently breaking tests that depend on a clean keymap state.
do
    local store = require("core.user_keymap_store")
    -- Per-process unique sandbox. Previously used os.time() + math.random(),
    -- but luaJIT defaults math.random's seed to 1 per process — so under
    -- parallel test runs (make -j4) multiple processes started in the same
    -- second pick the same sandbox path and `rm -rf` each other's state.
    -- Address of a fresh table gives a process-unique value; pairing with
    -- os.time() keeps the path human-recognizable.
    local proc_tag = assert(tostring({}):match("0x(%x+)"),
        "test_env: failed to derive process-unique tag from table address — "
        .. "luaJIT runtime no longer renders 0x<hex> in tostring(table)?")
    local sandbox = string.format("/tmp/jve_test_keymap_%d_%s",
        os.time(), proc_tag)
    os.execute(string.format("rm -rf %q && mkdir -p %q", sandbox, sandbox))
    store.set_base_dir(sandbox)
end

return M
