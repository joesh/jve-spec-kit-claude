--- Regression: project_browser must stamp clip.offline from media_status cache
-- at render time. After undo/redo, populate_tree reloads master_clips from DB
-- which defaults offline=false; media_status_changed only fires on cache
-- changes, so without an explicit stamp the browser displays stale online
-- state for media that is actually offline.
require('test_env')

local media_status = require("core.media.media_status")

-- Contract: ensure_clip_status stamps clip.offline from cache for the
-- clip's media_path. This is the primitive the project_browser fix relies on.
do
    local path = "/tmp/jve/does_not_exist_offline_stamp.mov"
    media_status._set_cache(path, { offline = true, error_code = "FileNotFound" })

    -- Simulate clip as returned by database.load_master_clips (offline=false default)
    local clip = { media_path = path, offline = false }
    media_status.ensure_clip_status(clip)

    assert(clip.offline == true,
        "ensure_clip_status must stamp offline=true when cache says offline")
    assert(clip.error_code == "FileNotFound",
        "ensure_clip_status must stamp error_code from cache")
end

-- Source-level guard: project_browser's add_master_clip_item must call
-- ensure_clip_status so the reactive-only path doesn't leave clip.offline
-- stale after refresh/undo/redo.
do
    local path_utils = require("core.path_utils")
    local src_path = path_utils.resolve_repo_root() .. "/src/lua/ui/project_browser.lua"
    local f = assert(io.open(src_path, "r"))
    local src = f:read("*a")
    f:close()

    local fn_start = src:find("local function add_master_clip_item", 1, true)
    assert(fn_start, "could not locate add_master_clip_item in project_browser.lua")
    local offline_read = src:find("offline = clip.offline", fn_start, true)
    assert(offline_read, "could not locate clip.offline read in add_master_clip_item")
    local stamp = src:find("ensure_clip_status", fn_start, true)
    assert(stamp and stamp < offline_read,
        "add_master_clip_item must call media_status.ensure_clip_status " ..
        "before reading clip.offline (regression: undo/redo online/offline desync)")
end

print("✅ test_project_browser_offline_stamp.lua passed")
