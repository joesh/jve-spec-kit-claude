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

--- Create a command_manager mock that captures executed commands.
-- Handles both old API (execute(cmd)) and new API (execute(type, params)).
-- Returns: mock table, executed commands array
function M.mock_command_manager()
    local executed = {}
    local mock = {
        execute = function(cmd_or_type, params)
            local captured
            if type(cmd_or_type) == "string" then
                captured = {
                    type = cmd_or_type,
                    params = params or {},
                    get_parameter = function(self, k) return self.params[k] end,
                }
            else
                captured = cmd_or_type
            end
            table.insert(executed, captured)
            return { success = true }
        end,
        begin_command_event = function() end,
        end_command_event = function() end,
        peek_command_event_origin = function() return nil end,
    }
    package.loaded["core.command_manager"] = mock
    return mock, executed
end

return M
