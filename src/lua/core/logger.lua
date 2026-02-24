--- Unified logging for JVE Editor
--
-- Intent-based levels: DETAIL < EVENT < WARN < ERROR < NONE
-- Functional areas: ticks, audio, video, timeline, commands, database, ui, media
--
-- Usage:
--   local log = require("core.logger").for_area("ticks")
--   log.event("Play dir=%d speed=%.1f", dir, speed)
--   log.detail("frame %d delivered", frame)
--
-- In-process (JVEEditor): calls C++ jve_log via FFI (single parser, single output).
-- Tests (luajit): pure-Lua fallback writing to stderr with same format.
--
-- @file logger.lua

local logger = {}

-- ---- Area/Level constants (must match jve_log.h) ----
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

-- ---- Backend: FFI (in-process) or pure-Lua (tests) ----
local log_enabled  -- function(area_num, level_num) -> bool
local log_output   -- function(area_num, level_num, msg)

local function init_backend()
    -- Try FFI first (available when running inside JVEEditor)
    local ffi_ok, ffi = pcall(require, "ffi")
    if ffi_ok then
        local ok = pcall(function()
            ffi.cdef[[
                void jve_log_init_ffi(void);
                bool jve_log_enabled_ffi(int area, int level);
                void jve_log_ffi(int area, int level, const char* msg);
            ]]
        end)
        if ok then
            -- Test if the symbol is actually linked (fails in plain luajit)
            local sym_ok = pcall(function() return ffi.C.jve_log_enabled_ffi(0, 2) end)
            if sym_ok then
                log_enabled = function(a, l) return ffi.C.jve_log_enabled_ffi(a, l) end
                log_output  = function(a, l, msg) ffi.C.jve_log_ffi(a, l, msg) end
                return
            end
        end
    end

    -- Pure-Lua fallback (test environment)
    -- Parse JVE_LOG env var ourselves; write to stderr
    local area_levels = {}
    for i = 0, AREA_COUNT - 1 do
        area_levels[i] = LEVELS.warn  -- default: WARN
    end

    local env = os.getenv("JVE_LOG")
    if env and env ~= "" then
        for entry in env:gmatch("[^,]+") do
            local area_str, level_str = entry:match("^%s*([^:]+):([^:]+)%s*$")
            if area_str and level_str then
                area_str = area_str:lower()
                level_str = level_str:lower()
                local lvl = LEVELS[level_str]
                if lvl then
                    if area_str == "all" then
                        for i = 0, AREA_COUNT - 1 do area_levels[i] = lvl end
                    elseif area_str == "play" then
                        area_levels[AREAS.ticks] = lvl
                        area_levels[AREAS.audio] = lvl
                        area_levels[AREAS.video] = lvl
                    elseif AREAS[area_str] then
                        area_levels[AREAS[area_str]] = lvl
                    end
                end
            end
        end
    end

    log_enabled = function(a, l) return l >= area_levels[a] end
    log_output = function(a, l, msg)
        local ts = os.date("%H:%M:%S")
        io.stderr:write(string.format("[%s] [%s] %s: %s\n",
            ts, AREA_NAMES[a] or "???", LEVEL_NAMES[l] or "???", msg))
        io.stderr:flush()
    end
end

init_backend()

-- ---- Core: for_area(name) -> {event, detail, warn, error} ----

function logger.for_area(area_name)
    local area_num = AREAS[area_name]
    assert(area_num, "logger.for_area: unknown area '" .. tostring(area_name) .. "'")

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

return logger
