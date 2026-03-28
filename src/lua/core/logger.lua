--- Unified logging for JVE Editor
--
-- Intent-based levels: DETAIL < EVENT < WARN < ERROR < NONE
-- Hierarchical areas: "ui" enables "ui" and "ui.*" (e.g. "ui.find")
--
-- Usage:
--   local log = require("core.logger").for_area("ticks")
--   log.event("Play dir=%d speed=%.1f", dir, speed)
--   local log2 = require("core.logger").for_area("ui.find")
--   log2.event("found %d matches", count)
--
-- In-process (JVEEditor): calls C++ jve_log via FFI (single parser, single output).
-- Tests (luajit): pure-Lua fallback writing to stderr with same format.
--
-- @file logger.lua

local logger = {}

-- ---- Area/Level constants ----
-- Core areas have integer IDs for FFI compatibility.
-- Hierarchical areas (e.g. "ui.find") are Lua-only extensions.
local AREAS = {
    ticks    = 0,
    audio    = 1,
    video    = 2,
    timeline = 3,
    commands = 4,
    database = 5,
    ui       = 6,
    media    = 7,
}

local LEVELS = {
    detail = 0,
    event  = 1,
    warn   = 2,
    error  = 3,
    none   = 4,
}

local LEVEL_NAMES = { [0] = "DETAIL", [1] = "EVENT", [2] = "WARN", [3] = "ERROR" }
local AREA_NAMES  = { [0] = "ticks", [1] = "audio", [2] = "video", [3] = "timeline",
                       [4] = "commands", [5] = "database", [6] = "ui", [7] = "media" }
local AREA_COUNT = 8

-- Extended area levels for hierarchical names (Lua-only, string-keyed)
local extended_area_levels = {}

-- ---- Backend: FFI (in-process) or pure-Lua (tests) ----
local log_enabled  -- function(area_num, level_num) -> bool
local log_output   -- function(area_num, level_num, msg)
local area_levels  -- integer-keyed table for core areas

-- Parse JVE_LOG env var for hierarchical area levels.
-- Called by both FFI and pure-Lua backends.
local function parse_env_levels()
    area_levels = {}
    for i = 0, AREA_COUNT - 1 do
        area_levels[i] = LEVELS.warn  -- default: WARN
    end

    local env = os.getenv("JVE_LOG")
    if not env or env == "" then return end

    for entry in env:gmatch("[^,]+") do
        local area_str, level_str = entry:match("^%s*([^:]+):([^:]+)%s*$")
        if area_str and level_str then
            area_str = area_str:lower()
            level_str = level_str:lower()
            local lvl = LEVELS[level_str]
            if lvl then
                if area_str == "all" then
                    for i = 0, AREA_COUNT - 1 do area_levels[i] = lvl end
                    for k in pairs(extended_area_levels) do
                        extended_area_levels[k] = lvl
                    end
                elseif area_str == "play" then
                    area_levels[AREAS.ticks] = lvl
                    area_levels[AREAS.audio] = lvl
                    area_levels[AREAS.video] = lvl
                elseif AREAS[area_str] ~= nil then
                    area_levels[AREAS[area_str]] = lvl
                end
                -- Store for hierarchical matching
                extended_area_levels[area_str] = lvl
            end
        end
    end
end

local function init_backend()
    -- Always parse env for hierarchical area support
    parse_env_levels()

    -- Try FFI first (available when running inside JVEEditor)
    local ffi_ok, ffi = pcall(require, "ffi")
    if ffi_ok then
        local ok = pcall(function()
            ffi.cdef[[
                void jve_log_init_ffi(void);
                bool jve_log_enabled_ffi(int area, int level);
                void jve_log_ffi(int area, int level, const char* msg);
                bool jve_log_enabled_str_ffi(const char* area_name, int level);
                void jve_log_str_ffi(const char* area_name, int level, const char* msg);
            ]]
        end)
        if ok then
            local sym_ok = pcall(function() return ffi.C.jve_log_enabled_ffi(0, 2) end)
            if sym_ok then
                log_enabled = function(a, l) return ffi.C.jve_log_enabled_ffi(a, l) end
                log_output  = function(a, l, msg) ffi.C.jve_log_ffi(a, l, msg) end
                return
            end
        end
    end

    -- Pure-Lua fallback (test environment)
    log_enabled = function(a, l) return l >= area_levels[a] end
    log_output = function(a, l, msg)
        local ts = os.date("%H:%M:%S")
        io.stderr:write(string.format("[%s] [%s] %s: %s\n",
            ts, AREA_NAMES[a] or "???", LEVEL_NAMES[l] or "???", msg))
        io.stderr:flush()
    end
end

init_backend()

-- ---- Hierarchical area resolution ----
-- "ui.find" resolves to: check extended_area_levels["ui.find"] first,
-- then fall back to parent "ui" (core area 6).

local function resolve_area(area_name)
    -- Direct core area?
    if AREAS[area_name] ~= nil then
        return AREAS[area_name], area_name
    end
    -- Hierarchical: find parent core area (e.g. "ui.find" -> parent "ui")
    local parent = area_name:match("^([^.]+)")
    if parent and AREAS[parent] ~= nil then
        return AREAS[parent], area_name
    end
    return nil, area_name
end

local function is_enabled_hierarchical(area_name, parent_area_num, level_num)
    -- Check explicit level for this exact area name
    local explicit = extended_area_levels[area_name]
    if explicit then
        return level_num >= explicit
    end
    -- Fall back to parent core area
    if parent_area_num then
        return log_enabled(parent_area_num, level_num)
    end
    -- Default: WARN and above
    return level_num >= LEVELS.warn
end

-- ---- Core: for_area(name) -> {event, detail, warn, error} ----

function logger.for_area(area_name)
    assert(area_name and area_name ~= "", "logger.for_area: area_name required")

    local parent_area_num, full_name = resolve_area(area_name)

    -- For core areas (no dot), use the fast FFI path
    if parent_area_num and full_name == area_name and AREAS[area_name] ~= nil then
        local area_num = parent_area_num
        local function make_fn(level_num)
            return function(fmt, ...)
                if not log_enabled(area_num, level_num) then return end
                local msg
                if select("#", ...) > 0 then
                    msg = string.format(fmt, ...)
                else
                    msg = fmt
                end
                log_output(area_num, level_num, msg)
            end
        end
        return {
            detail = make_fn(LEVELS.detail),
            event  = make_fn(LEVELS.event),
            warn   = make_fn(LEVELS.warn),
            error  = make_fn(LEVELS.error),
        }
    end

    -- Hierarchical area (e.g. "ui.find")
    -- Use string-based FFI if available, otherwise Lua fallback
    local ffi_ok, ffi = pcall(require, "ffi")
    local has_str_ffi = ffi_ok and pcall(function() return ffi.C.jve_log_enabled_str_ffi("test", 2) end)

    local function make_fn_ext(level_num)
        return function(fmt, ...)
            if has_str_ffi then
                -- C++ handles hierarchical check + output with correct area name
                if not ffi.C.jve_log_enabled_str_ffi(full_name, level_num) then return end
                local msg
                if select("#", ...) > 0 then
                    msg = string.format(fmt, ...)
                else
                    msg = fmt
                end
                ffi.C.jve_log_str_ffi(full_name, level_num, msg)
            else
                -- Lua fallback
                if not is_enabled_hierarchical(full_name, parent_area_num, level_num) then return end
                local msg
                if select("#", ...) > 0 then
                    msg = string.format(fmt, ...)
                else
                    msg = fmt
                end
                local display_num = parent_area_num or 6
                local saved = AREA_NAMES[display_num]
                AREA_NAMES[display_num] = full_name
                log_output(display_num, level_num, msg)
                AREA_NAMES[display_num] = saved
            end
        end
    end
    return {
        detail = make_fn_ext(LEVELS.detail),
        event  = make_fn_ext(LEVELS.event),
        warn   = make_fn_ext(LEVELS.warn),
        error  = make_fn_ext(LEVELS.error),
    }
end

return logger
