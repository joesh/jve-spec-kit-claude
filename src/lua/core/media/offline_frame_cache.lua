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
local offline_note_mod = require("core.media.offline_note")

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

-- Format helper lives in core.media.offline_note for reuse.
local format_frame_delta = offline_note_mod.format_frame_delta

-- "candidate_path" basename. candidate_path is a documented invariant
-- of a partial_coverage note (see schema.sql), so absence is a writer bug.
local function candidate_basename(note)
    assert(type(note.candidate_path) == "string" and note.candidate_path ~= "",
        "offline_frame_cache: partial_coverage note missing candidate_path")
    local base = note.candidate_path:match("[^/]+$")
    assert(base, "offline_frame_cache: candidate_path yielded no basename")
    return base
end

local function line_header(text)
    return { text = text, height_pct = 5, color = "#ffaa55", bold = true }
end

local function line_body(text)
    return { text = text, height_pct = 4.5, color = "#dddddd", bold = false }
end

--- Compose "partial coverage" lines from a parsed offline_note and the
-- clip's own source range. Result describes what the relinker found
-- and precisely what's missing for THIS clip. Returns nil when the
-- note isn't a partial_coverage shape. When the per-clip range is
-- missing, returns a single-line "coverage doesn't match this clip"
-- message — the renderer can enter this path with no source range if
-- the clip isn't in the active PlaybackEngine's window (source-viewer
-- vs timeline crossover). Per-field shape is a writer invariant and
-- validated by offline_note.shortfall.
local function build_partial_coverage_lines(note, clip)
    if type(note) ~= "table" or note.kind ~= "partial_coverage" then
        return nil
    end
    if not clip or not clip.source_in or not clip.source_out then
        return {line_header(string.format(
            "Found %s — but coverage doesn't match this clip",
            candidate_basename(note)))}
    end

    local cand_name = candidate_basename(note)
    local out = {line_header("Found " .. cand_name .. " in search tree")}

    local sf = offline_note_mod.shortfall(note, clip.source_in, clip.source_out)
    if not sf then
        -- Candidate extent fully covers the clip — relinker rejected it
        -- for a non-coverage reason (e.g. TC mismatch classified partial).
        out[#out + 1] = line_body("File exists but wasn't accepted as a match")
    elseif sf.head_missing > 0 and sf.tail_missing > 0 then
        out[#out + 1] = line_body(string.format(
            "Not enough media for clip — short %s at head, %s at tail",
            format_frame_delta(sf.head_missing, sf.rate),
            format_frame_delta(sf.tail_missing, sf.rate)))
    elseif sf.head_missing > 0 then
        out[#out + 1] = line_body(string.format(
            "Not enough media for clip — short %s at head",
            format_frame_delta(sf.head_missing, sf.rate)))
    else
        out[#out + 1] = line_body(string.format(
            "Not enough media for clip — short %s at tail",
            format_frame_delta(sf.tail_missing, sf.rate)))
    end
    return out
end

-- Exported as underscored helpers so targeted tests can exercise the
-- pure formatting logic without touching Qt or EMP.
M._format_frame_delta = format_frame_delta
M._build_partial_coverage_lines = build_partial_coverage_lines

--- Build the lines table for COMPOSE_OFFLINE_FRAME from offline metadata.
-- Caller (get_frame) has asserted metadata.media_path is a non-empty string.
-- @param metadata table with media_path, error_code, error_msg, offline_note, clip
-- @return table array of {text, size, color, bold}
local function build_lines(metadata)
    local filename = metadata.media_path:match("[^/]+$")
    assert(filename, "offline_frame_cache.build_lines: media_path has no basename")
    local lines = {}

    -- Partial-coverage branch — supersedes "File not found" when the
    -- relinker found a same-basename candidate and left us a note.
    -- Skip the generic error title/msg lines in this case — we have
    -- more actionable content to show.
    local note = metadata.offline_note
    if type(note) == "string" then note = offline_note_mod.parse(note) end
    local partial_lines = build_partial_coverage_lines(note, metadata.clip)
    if partial_lines then
        lines[#lines + 1] = {
            text = "Media Offline",
            height_pct = 12, color = "#ffffff", bold = true, gap_after_pct = 3,
        }
        lines[#lines + 1] = {
            text = filename, height_pct = 5, color = "#dddddd", bold = false,
        }
        for _, ln in ipairs(partial_lines) do lines[#lines + 1] = ln end
        return lines
    end

    -- Title: distinguish codec errors from missing files
    local ec = metadata.error_code
    local is_codec_error = (ec == "Unsupported" or ec == "DecodeFailed")
    local title = is_codec_error and "Codec Unavailable" or "Media Offline"

    lines[#lines + 1] = {
        text = title,
        height_pct = 12, color = "#ffffff", bold = true, gap_after_pct = 5,
    }

    -- Codec hint (only for codec errors)
    if is_codec_error then
        local hint = get_codec_hint(metadata)
        if hint then
            lines[#lines + 1] = {
                text = hint,
                height_pct = 6, color = "#ffcc44", bold = true, gap_after_pct = 2,
            }
        end
    end

    lines[#lines + 1] = {
        text = filename, height_pct = 5, color = "#dddddd", bold = false,
    }
    lines[#lines + 1] = {
        text = metadata.media_path, height_pct = 4.5, color = "#bbbbbb", bold = false,
    }

    -- Error info — strip redundant path from error_msg (already its own line).
    if metadata.error_msg then
        local escaped = metadata.media_path:gsub(
            "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        local msg = tostring(metadata.error_msg):gsub(": ?" .. escaped, "")
        lines[#lines + 1] = {
            text = msg, height_pct = 4.5, color = "#bbbbbb", bold = false,
        }
    end

    return lines
end

-- Exported so tests can assert the lines structure without invoking Qt.
M._build_lines = build_lines

--- Get (or compose) an offline frame for the given metadata.
-- @param metadata table with media_path, error_code, error_msg
-- @return frame_handle
function M.get_frame(metadata)
    assert(metadata, "offline_frame_cache.get_frame: metadata is nil")
    assert(metadata.media_path,
        "offline_frame_cache.get_frame: metadata.media_path is nil")

    -- Partial-coverage frames are per-clip (the "short by N frames"
    -- number depends on the clip's source range). Fold the clip's
    -- source_in/out into the key when an offline_note + clip pair is
    -- supplied so different clips using the same media don't collide.
    local key = metadata.media_path .. ":" .. (metadata.error_code or "offline")
    if metadata.offline_note and metadata.clip then
        key = key .. ":" .. tostring(metadata.clip.source_in)
            .. ":" .. tostring(metadata.clip.source_out)
    end
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
