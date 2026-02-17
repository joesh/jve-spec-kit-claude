--- offline_frame_cache: caches composited "MEDIA OFFLINE" frames per media path.
--
-- Each offline clip gets a single composited frame with text burned into the pixels.
-- Frames are cached by media_path so repeated seeks/ticks return the same handle.
-- The cache is cleared on project_changed (all handles released).
--
-- @file offline_frame_cache.lua

local qt_constants = require("core.qt_constants")
local path_utils = require("core.path_utils")
local logger = require("core.logger")
local Signals = require("core.signals")

local M = {}

-- {[media_path] = frame_handle}
local cache = {}

-- Resolved path to the offline frame PNG (lazy-init)
local png_path = nil

local function ensure_png_path()
    if not png_path then
        png_path = path_utils.resolve_repo_path("resources/offline_frame.png")
        assert(png_path, "offline_frame_cache: could not resolve offline_frame.png path")
    end
    return png_path
end

--- Build the lines table for COMPOSE_OFFLINE_FRAME from offline metadata.
-- @param metadata table with media_path, error_code, error_msg
-- @return table array of {text, size, color, bold}
local function build_lines(metadata)
    local lines = {}

    -- Title
    lines[#lines + 1] = {
        text = "Media Offline",
        height_pct = 12,
        color = "#ffffff",
        bold = true,
        gap_after_pct = 5,
    }

    -- Filename
    local filename = metadata.media_path and metadata.media_path:match("[^/]+$") or "?"
    lines[#lines + 1] = {
        text = filename,
        height_pct = 5,
        color = "#dddddd",
        bold = false,
    }

    -- Full path
    if metadata.media_path then
        lines[#lines + 1] = {
            text = metadata.media_path,
            height_pct = 4.5,
            color = "#bbbbbb",
            bold = false,
        }
    end

    -- Error info — show error_msg, strip redundant path (already on its own line)
    if metadata.error_msg then
        local msg = tostring(metadata.error_msg)
        if metadata.media_path then
            msg = msg:gsub(": ?" .. metadata.media_path:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), "")
        end
        lines[#lines + 1] = {
            text = msg,
            height_pct = 4.5,
            color = "#bbbbbb",
            bold = false,
        }
    end

    return lines
end

--- Get (or compose) an offline frame for the given metadata.
-- @param metadata table with media_path, error_code, error_msg
-- @return frame_handle
function M.get_frame(metadata)
    assert(metadata, "offline_frame_cache.get_frame: metadata is nil")
    assert(metadata.media_path,
        "offline_frame_cache.get_frame: metadata.media_path is nil")

    local key = metadata.media_path
    if cache[key] then
        return cache[key]
    end

    assert(qt_constants.EMP and qt_constants.EMP.COMPOSE_OFFLINE_FRAME,
        "offline_frame_cache.get_frame: EMP.COMPOSE_OFFLINE_FRAME not available")

    local lines = build_lines(metadata)
    local frame = qt_constants.EMP.COMPOSE_OFFLINE_FRAME(ensure_png_path(), lines)
    assert(frame, string.format(
        "offline_frame_cache.get_frame: COMPOSE_OFFLINE_FRAME returned nil for '%s'",
        key))

    cache[key] = frame
    logger.debug("offline_frame_cache", string.format(
        "Composed offline frame for '%s'", key))
    return frame
end

--- Clear all cached frames (releases handles).
function M.clear()
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    cache = {}
    if count > 0 then
        logger.debug("offline_frame_cache", string.format(
            "Cleared %d cached offline frames", count))
    end
end

-- Clear cache on project switch
Signals.connect("project_changed", M.clear, 15)

return M
