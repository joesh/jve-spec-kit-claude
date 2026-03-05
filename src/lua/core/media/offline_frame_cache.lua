--- offline_frame_cache: caches composited "MEDIA OFFLINE" frames per media path.
--
-- Each offline clip gets a single composited frame with text burned into the pixels.
-- Frames are cached by media_path so repeated seeks/ticks return the same handle.
-- The cache is cleared on project_changed (all handles released).
--
-- @file offline_frame_cache.lua

local qt_constants = require("core.qt_constants")
local path_utils = require("core.path_utils")
local log = require("core.logger").for_area("video")
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

--- Codec hint from file extension (for "Codec Unavailable" display)
local CODEC_HINTS = {
    braw = "BRAW (Blackmagic RAW)",
    r3d  = "RED R3D",
    ari  = "ARRIRAW",
    arx  = "ARRIRAW",
    nef  = "Nikon RAW",
    cr2  = "Canon RAW",
    cr3  = "Canon RAW",
    dng  = "DNG",
}

--- Derive codec hint from file extension or error message.
-- @param metadata table with media_path, error_msg
-- @return string|nil codec name hint
local function get_codec_hint(metadata)
    if metadata.media_path then
        local ext = metadata.media_path:match("%.([^.]+)$")
        if ext then
            local hint = CODEC_HINTS[ext:lower()]
            if hint then return hint end
        end
    end
    -- Try to extract from error_msg (e.g. "Unsupported codec: xyz")
    if metadata.error_msg then
        local codec = metadata.error_msg:match("[Cc]odec:?%s+(.+)")
        if codec then return codec end
    end
    return nil
end

--- Build the lines table for COMPOSE_OFFLINE_FRAME from offline metadata.
-- @param metadata table with media_path, error_code, error_msg
-- @return table array of {text, size, color, bold}
local function build_lines(metadata)
    local lines = {}

    -- Title: distinguish codec errors from missing files
    local ec = metadata.error_code
    local is_codec_error = (ec == "Unsupported" or ec == "DecodeFailed")
    local title = is_codec_error and "Codec Unavailable" or "Media Offline"

    lines[#lines + 1] = {
        text = title,
        height_pct = 12,
        color = "#ffffff",
        bold = true,
        gap_after_pct = 5,
    }

    -- Codec hint (only for codec errors)
    if is_codec_error then
        local hint = get_codec_hint(metadata)
        if hint then
            lines[#lines + 1] = {
                text = hint,
                height_pct = 6,
                color = "#ffcc44",
                bold = true,
                gap_after_pct = 2,
            }
        end
    end

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

    local key = metadata.media_path .. ":" .. (metadata.error_code or "offline")
    if cache[key] then
        return cache[key]
    end

    assert(qt_constants.EMP and qt_constants.EMP.COMPOSE_OFFLINE_FRAME,
        "offline_frame_cache.get_frame: EMP.COMPOSE_OFFLINE_FRAME not available")

    local lines = build_lines(metadata)
    assert(#lines >= 1, string.format(
        "offline_frame_cache.get_frame: build_lines produced 0 lines for '%s'", key))
    local frame = qt_constants.EMP.COMPOSE_OFFLINE_FRAME(ensure_png_path(), lines)
    assert(frame, string.format(
        "offline_frame_cache.get_frame: COMPOSE_OFFLINE_FRAME returned nil for '%s'",
        key))

    cache[key] = frame
    log.event("Composed offline frame for '%s'", key)
    return frame
end

--- Clear all cached frames (releases handles).
function M.clear()
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    cache = {}
    if count > 0 then
        log.event("Cleared %d cached offline frames", count)
    end
end

-- Clear cache on project switch
Signals.connect("project_changed", M.clear, 15)

return M
