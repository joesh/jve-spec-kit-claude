--- LuaJIT sampling profiler for playback diagnostics
--
-- Uses jit.profile (built-in sampling profiler) to capture call stacks
-- at regular intervals. Writes structured reports to /tmp/jve/profile_report.txt.
--
-- Toggle via Shift+F12 keybinding or require("core.lua_profiler").toggle()
--
-- @file lua_profiler.lua
local profile = require("jit.profile")
local logger = require("core.logger")

local M = {}

local REPORT_PATH = "/tmp/jve/profile_report.txt"
local SAMPLE_INTERVAL_MS = 2

local samples = {}
local vmstate_counts = {}
local total_samples = 0
local is_running = false
local start_time = 0

local function on_sample(thread, count, vmstate)
    vmstate_counts[vmstate] = (vmstate_counts[vmstate] or 0) + count
    total_samples = total_samples + count

    -- Full stack: line-level, full paths, 10 frames deep, semicolon-separated
    local stack = profile.dumpstack(thread, "pFl;", 10)
    local key = vmstate .. "|" .. stack
    samples[key] = (samples[key] or 0) + count
end

function M.start()
    assert(not is_running, "lua_profiler.start: profiler already running")
    samples = {}
    vmstate_counts = {}
    total_samples = 0
    start_time = os.clock()
    profile.start("li" .. SAMPLE_INTERVAL_MS, on_sample)
    is_running = true
    logger.info("profiler", string.format("STARTED (%dms sampling interval)", SAMPLE_INTERVAL_MS))
end

function M.stop()
    assert(is_running, "lua_profiler.stop: profiler not running")
    profile.stop()
    local elapsed = os.clock() - start_time
    is_running = false
    logger.info("profiler", string.format(
        "STOPPED after %.1fs (%d samples)", elapsed, total_samples))
    M._write_report(elapsed)
end

function M.toggle()
    if is_running then
        M.stop()
    else
        M.start()
    end
end

function M.is_running()
    return is_running
end

-- ── Report generation ──

local STATE_NAMES = {
    I = "Interpreted Lua",
    N = "JIT-compiled (native)",
    C = "C/FFI code",
    G = "Garbage collector",
    J = "JIT compiler",
}

function M._write_report(elapsed)
    os.execute("mkdir -p /tmp/jve")

    local f = io.open(REPORT_PATH, "w")
    assert(f, "lua_profiler._write_report: could not open " .. REPORT_PATH)

    f:write("=== JVE Profiler Report ===\n")
    f:write(string.format("Duration: %.1fs | Samples: %d | Interval: %dms\n\n",
        elapsed, total_samples, SAMPLE_INTERVAL_MS))

    -- VM state breakdown
    f:write("── VM State Breakdown ──\n")
    for _, st in ipairs({"C", "I", "N", "G", "J"}) do
        local count = vmstate_counts[st] or 0
        if count > 0 then
            local pct = total_samples > 0 and (count / total_samples * 100) or 0
            f:write(string.format("  %s (%s): %d (%.1f%%)\n",
                st, STATE_NAMES[st] or "?", count, pct))
        end
    end
    f:write("\n")

    -- Aggregate leaf frames (the function actually executing when sampled)
    local leaf_counts = {}
    for key, count in pairs(samples) do
        local vmstate, stack = key:match("^(.)|(.*)")
        local leaf = stack:match("^([^;]+)") or stack
        local leaf_key = vmstate .. " " .. leaf
        leaf_counts[leaf_key] = (leaf_counts[leaf_key] or 0) + count
    end

    local leaf_sorted = {}
    for key, count in pairs(leaf_counts) do
        leaf_sorted[#leaf_sorted + 1] = { key = key, count = count }
    end
    table.sort(leaf_sorted, function(a, b) return a.count > b.count end)

    f:write("── Top 50 Hotspots (leaf frame) ──\n")
    for i, entry in ipairs(leaf_sorted) do
        if i > 50 then break end
        local pct = total_samples > 0 and (entry.count / total_samples * 100) or 0
        f:write(string.format("  %5d (%5.1f%%)  %s\n", entry.count, pct, entry.key))
    end
    f:write("\n")

    -- Full stacks sorted by frequency (shows call chains)
    local stack_sorted = {}
    for key, count in pairs(samples) do
        stack_sorted[#stack_sorted + 1] = { key = key, count = count }
    end
    table.sort(stack_sorted, function(a, b) return a.count > b.count end)

    f:write("── Top 30 Full Stacks ──\n")
    for i, entry in ipairs(stack_sorted) do
        if i > 30 then break end
        local pct = total_samples > 0 and (entry.count / total_samples * 100) or 0
        -- Format: indent stack frames for readability
        local vmstate, stack = entry.key:match("^(.)|(.*)")
        f:write(string.format("  [%5d %5.1f%% vm=%s]\n", entry.count, pct, vmstate))
        for frame in stack:gmatch("[^;]+") do
            f:write(string.format("    %s\n", frame))
        end
        f:write("\n")
    end

    f:close()
    logger.info("profiler", "Report → " .. REPORT_PATH)
end

return M
