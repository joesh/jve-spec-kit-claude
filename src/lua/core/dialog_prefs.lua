--- Per-dialog JSON preferences in ~/.jve/.
--
-- Replaces the load_settings/save_settings copy-paste that lived in
-- find_dialog, find_replace_dialog, and sift_dialog. Fail-fast on
-- corruption (no `json.decode(raw) or {}` silent reset), fail-fast
-- on HOME missing, fail-fast on write failure. Missing file is the
-- only legitimate empty case (first-run).
--
-- @file core/dialog_prefs.lua

local json = require("dkjson")

local M = {}

local function jve_dir()
    local home = os.getenv("HOME")
    assert(home and home ~= "",
        "dialog_prefs: HOME is unset; cannot locate ~/.jve")
    return home .. "/.jve"
end

--- Resolve a settings filename to its absolute path under ~/.jve/.
function M.path_for(filename)
    assert(type(filename) == "string" and filename ~= "",
        "dialog_prefs.path_for: filename required")
    return jve_dir() .. "/" .. filename
end

--- Load JSON settings from `path`. Missing file → empty table.
--- Corrupt JSON → assert (no silent state loss).
function M.load(path)
    assert(type(path) == "string" and path ~= "",
        "dialog_prefs.load: path required")
    local f = io.open(path, "r")
    if not f then return {} end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return {} end
    local decoded, _, err = json.decode(raw)
    assert(decoded and type(decoded) == "table", string.format(
        "dialog_prefs.load: failed to parse %s: %s",
        path, tostring(err)))
    return decoded
end

--- Save JSON settings to `path`. mkdir ~/.jve if needed.
--- Open/write failures assert (no silent persistence loss).
function M.save(path, settings)
    assert(type(path) == "string" and path ~= "",
        "dialog_prefs.save: path required")
    assert(type(settings) == "table",
        "dialog_prefs.save: settings must be a table")
    local dir = jve_dir()
    local ok, err = qt_fs_mkdir_p(dir)
    assert(ok, "dialog_prefs.save: mkdir " .. dir .. " failed: " .. tostring(err))
    local f, open_err = io.open(path, "w")
    assert(f, string.format(
        "dialog_prefs.save: cannot open %s for writing: %s",
        path, tostring(open_err)))
    f:write(json.encode(settings))
    f:close()
end

return M
