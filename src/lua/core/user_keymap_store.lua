--- User keymap preset persistence (TOML files under ~/.jve/keymaps/)
--
-- Responsibilities:
-- - Read/write/list/delete TOML preset files in ~/.jve/keymaps/<name>.jvekeys
-- - Track active-preset pointer at ~/.jve/keymap_active (one-line file: name, or absent)
-- - Validate preset names (no path traversal, no NUL, non-empty)
--
-- Non-goals:
-- - Serializing the registry to TOML (caller's job — store deals in strings)
-- - Knowing which preset is "default" — that's the registry's concern
--
-- Invariants:
-- - Filenames on disk are exactly "<name>.jvekeys"; the name is the preset identity
-- - Base dir is created lazily on first write
--
-- @file user_keymap_store.lua
local M = {}

-- Configurable base dir (overridable for tests); defaults to $HOME/.jve
local function default_base()
    local home = os.getenv("HOME")
    assert(home and home ~= "", "user_keymap_store: HOME env var not set")
    return home .. "/.jve"
end

M._base_dir = default_base()

local KEYMAP_SUBDIR = "keymaps"
local PRESET_EXT = ".jvekeys"
local ACTIVE_FILE = "keymap_active"

function M.set_base_dir(path)
    assert(type(path) == "string" and path ~= "",
        "set_base_dir: path must be non-empty string")
    M._base_dir = path
end

local function keymaps_dir()
    return M._base_dir .. "/" .. KEYMAP_SUBDIR
end

local function active_file_path()
    return M._base_dir .. "/" .. ACTIVE_FILE
end

local function preset_path(name)
    return keymaps_dir() .. "/" .. name .. PRESET_EXT
end

-- Validate a preset name. Reject path-traversal and filesystem-hostile chars.
-- Spaces, apostrophes, hyphens are allowed (matches Premiere preset naming).
local function validate_name(name)
    assert(type(name) == "string", "preset name must be a string")
    assert(name ~= "", "preset name must be non-empty")
    assert(not name:find("/", 1, true), "preset name must not contain '/'")
    assert(not name:find("\\", 1, true), "preset name must not contain '\\'")
    assert(not name:find("\0", 1, true), "preset name must not contain NUL")
    assert(name ~= "." and name ~= "..", "preset name must not be '.' or '..'")
end

local function ensure_dir(path)
    local ok, err = qt_fs_mkdir_p(path)
    assert(ok, "user_keymap_store: mkdir " .. path .. " failed: " .. tostring(err))
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

-- ----- Public API ---------------------------------------------------------

function M.exists(name)
    validate_name(name)
    return file_exists(preset_path(name))
end

function M.read(name)
    validate_name(name)
    local f = io.open(preset_path(name), "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write(name, content)
    validate_name(name)
    assert(type(content) == "string", "content must be a string")
    ensure_dir(keymaps_dir())
    local path = preset_path(name)
    local f, err = io.open(path, "w")
    assert(f, string.format("user_keymap_store.write: cannot open %s: %s",
        path, tostring(err)))
    f:write(content)
    f:close()
end

function M.delete(name)
    validate_name(name)
    os.remove(preset_path(name))
end

-- Rename a preset file in-place to "<name>.jvekeys.broken" so the user
-- can recover/diff it. The .broken suffix is NOT picked up by list()
-- (it filters on .jvekeys$), so a quarantined file is invisible to the
-- preset UI but stays in the keymaps/ dir for forensic access.
-- Returns the destination path on success, or nil if the source didn't exist.
function M.quarantine_to_broken(name)
    validate_name(name)
    local src = preset_path(name)
    if not file_exists(src) then return nil end
    local dst = src .. ".broken"
    -- If a prior quarantine left a .broken file, overwrite it: keeping
    -- stacked .broken.broken.broken serves nobody.
    os.remove(dst)
    local ok, err = os.rename(src, dst)
    assert(ok, string.format("user_keymap_store.quarantine_to_broken: "
        .. "rename %s -> %s failed: %s", src, dst, tostring(err)))
    return dst
end

function M.list()
    local dir = keymaps_dir()
    local names = {}
    -- ls can fail if dir doesn't exist; treat as empty
    local handle = io.popen(string.format("ls -1 %q 2>/dev/null", dir))
    if not handle then return names end
    for filename in handle:lines() do
        local name = filename:match("^(.+)%" .. PRESET_EXT .. "$")
        if name then names[#names + 1] = name end
    end
    handle:close()
    table.sort(names)
    return names
end

function M.get_active()
    local f = io.open(active_file_path(), "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line or line == "" then return nil end
    return line
end

-- Pass nil to clear the active pointer.
function M.set_active(name)
    if name == nil then
        os.remove(active_file_path())
        return
    end
    validate_name(name)
    ensure_dir(M._base_dir)
    local f, err = io.open(active_file_path(), "w")
    assert(f, string.format("user_keymap_store.set_active: cannot open %s: %s",
        active_file_path(), tostring(err)))
    f:write(name)
    f:close()
end

return M
