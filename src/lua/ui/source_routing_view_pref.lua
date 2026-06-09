--- source_routing_view_pref — per-user preference for source-routing display mode.
---
--- Values: 'per_channel' (default) | 'per_clip'
--- Stored as JSON at a path passed to init() (production: ~/.jve/source_routing_view.json).
---
--- @file source_routing_view_pref.lua

local json = require("dkjson")
local log  = require("core.logger").for_area("ui")

local M = {}

local VALID = { per_channel = true, per_clip = true }
local DEFAULT = "per_channel"

local _path  = nil
local _value = DEFAULT

local function load_from_disk()
    assert(_path and _path ~= "", "source_routing_view_pref: not initialized")
    -- First launch (file absent) is the legitimate quiet-default path.
    -- A present-but-corrupt JSON is a real problem and gets a warning so
    -- the silent fallback doesn't mask a serializer regression.
    local f = io.open(_path, "r")
    if not f then return DEFAULT end
    local raw = f:read("*a")
    f:close()
    local t = json.decode(raw)
    if type(t) == "table" and VALID[t.value] then
        return t.value
    end
    log.warn("source_routing_view_pref: corrupt or invalid pref at %s — falling back to default %q",
        _path, DEFAULT)
    return DEFAULT
end

local function save_to_disk(value)
    assert(_path and _path ~= "", "source_routing_view_pref: not initialized")
    local dir = _path:match("^(.+)/[^/]+$")
    if dir then
        local ok, err = qt_fs_mkdir_p(dir)
        assert(ok, "source_routing_view_pref: mkdir " .. dir .. " failed: " .. tostring(err))
    end
    local f = io.open(_path, "w")
    assert(f, string.format("source_routing_view_pref: cannot write to '%s'", _path))
    f:write(json.encode({ value = value }))
    f:close()
end

--- Initialize (or re-initialize) the pref from disk. Call once at startup and
--- again to simulate an app restart in tests.
function M.init(path)
    assert(type(path) == "string" and path ~= "",
        "source_routing_view_pref.init: path required")
    _path  = path
    _value = load_from_disk()
end

--- Return the current preference value.
function M.get()
    assert(_path, "source_routing_view_pref: call init() first")
    return _value
end

--- Set and persist the preference. Errors on invalid values.
function M.set(value)
    assert(_path, "source_routing_view_pref: call init() first")
    assert(VALID[value], string.format(
        "source_routing_view_pref.set: invalid value '%s'; must be per_channel or per_clip",
        tostring(value)))
    _value = value
    save_to_disk(value)
end

--- Return the storage path passed to init().
function M.storage_path()
    return _path
end

return M
