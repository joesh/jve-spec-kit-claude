-- Persistent widget state primitive (rule 1.6).
--
-- JSON key-value store backed by ~/.jve/widget_state.json.
-- Intended for UI widget state that must survive app restart:
--   - Inspector section collapse/expand state
--   - (future) panel sizes, focus-retention hints, etc.
--
-- Only JSON-scalar values (boolean, number, string) are persisted. Nested
-- tables are rejected at set() time — this primitive does not serialize
-- complex state. Callers with complex state compose scalar keys.
--
-- Contract: specs/012-rewrite-the-inspector/contracts/inspector-api.md §7
-- (indirectly, via FR-021a).

local log = require("core.logger").for_area("ui")
local json = require("dkjson")

local M = {}

local STATE_DIR  = os.getenv("HOME") .. "/.jve"
local STATE_PATH = STATE_DIR .. "/widget_state.json"

local state = nil    -- lazy-loaded table
local loaded = false

local function read_file(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local contents = fh:read("*a")
    fh:close()
    return contents
end

local function write_file(path, contents)
    local ok_mkdir, mkdir_err = qt_fs_mkdir_p(STATE_DIR)
    assert(ok_mkdir, string.format(
        "persistent_widget.write_file: mkdir %s failed: %s",
        STATE_DIR, tostring(mkdir_err)))
    local fh, err = io.open(path, "w")
    assert(fh, string.format(
        "persistent_widget.write_file: cannot open %s for write: %s", path, tostring(err)))
    fh:write(contents)
    fh:close()
end

local function ensure_loaded()
    if loaded then return end
    local contents = read_file(STATE_PATH)
    if contents and contents ~= "" then
        local decoded, _, err = json.decode(contents)
        if decoded == nil then
            -- Treat unparseable file as corrupt and fail loudly. Do NOT fall
            -- back to empty state silently — that would destroy the user's
            -- accumulated preferences on any transient read glitch.
            assert(false, string.format(
                "persistent_widget: %s is not valid JSON: %s", STATE_PATH, tostring(err)))
        end
        assert(type(decoded) == "table",
            string.format("persistent_widget: %s root must be object, got %s",
                STATE_PATH, type(decoded)))
        state = decoded
    else
        -- Missing or empty file is a legitimate first-run condition. Empty
        -- table is the correct initial state, not a fallback on required data.
        state = {}
    end
    loaded = true
end

local function assert_scalar(key, value)
    local t = type(value)
    assert(t == "boolean" or t == "number" or t == "string",
        string.format("persistent_widget.set(%q): value must be boolean/number/string, got %s",
            tostring(key), t))
end

function M.get(key, fallback)
    assert(type(key) == "string" and key ~= "",
        "persistent_widget.get: key must be non-empty string")
    ensure_loaded()
    local v = state[key]
    if v == nil then return fallback end
    return v
end

function M.set(key, value)
    assert(type(key) == "string" and key ~= "",
        "persistent_widget.set: key must be non-empty string")
    assert_scalar(key, value)
    ensure_loaded()
    -- No-op if the value hasn't changed — avoids a disk write per inspector
    -- section on initial load where schema.lua calls set() to re-persist the
    -- value it just read.
    if state[key] == value then return end
    state[key] = value
    M.save()
end

function M.save()
    ensure_loaded()
    local encoded = json.encode(state, { indent = true })
    assert(encoded and encoded ~= "",
        "persistent_widget.save: json.encode returned empty")
    write_file(STATE_PATH, encoded)
    log.event("persistent_widget: saved %d keys to %s",
        M.count_keys(), STATE_PATH)
end

function M.count_keys()
    ensure_loaded()
    local n = 0
    for _ in pairs(state) do n = n + 1 end
    return n
end

-- Test-only: reset in-memory state. Does NOT touch disk.
function M._reset_for_test()
    state = nil
    loaded = false
end

-- Test-only: override the on-disk path.
function M._set_path_for_test(path)
    STATE_PATH = path
end

return M
