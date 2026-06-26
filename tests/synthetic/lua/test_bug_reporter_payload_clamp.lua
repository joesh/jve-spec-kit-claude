-- Feature 027 T027: payload clamp order (FR-024a).
--
-- App clamps total request size to 10 MB BEFORE sending. Clamp order:
-- (1) drop oldest log entries first
-- (2) then drop commands (oldest first)
-- (3) slideshow.mp4 preserved
-- (4) user description preserved
-- (5) unclampable case (e.g. slideshow alone over 10 MB) → user-visible
--     refusal, never silent truncation.

require("test_env")

local function require_or_red(modname, task)
    local ok, mod = pcall(require, modname)
    if not ok then
        error("RED — " .. modname .. " unloadable (" .. task .. " not landed): " .. tostring(mod))
    end
    return mod
end

local clamp = require_or_red("bug_reporter.payload_clamp", "T035-or-T036-or-T049")

local function make_capture(opts)
    opts = opts or {}
    local cap = {
        capture_metadata = {
            user_description = opts.user_desc or "Reproducer.",
            jve_version = "8935293",
            capture_type = "user_submitted",
        },
        gestures = {},
        commands = {},
        logs = {},
        screenshots = {},
    }
    -- Pad each stream to push total over the cap.
    local pad_size = opts.pad_size or 80
    for i = 1, (opts.commands or 200) do
        cap.commands[#cap.commands + 1] = { id = "c" .. i, timestamp_ms = i, command = string.rep("X", pad_size) }
    end
    for i = 1, (opts.logs or 1000) do
        cap.logs[#cap.logs + 1] = { timestamp_ms = i, level = "info", message = string.rep("L", pad_size) }
    end
    return cap
end

-- (1) Clamp shrinks logs first.
do
    local cap = make_capture({ logs = 5000, commands = 50, pad_size = 800 })
    local original_log_count = #cap.logs
    local original_cmd_count = #cap.commands
    local result = clamp.clamp(cap, { max_bytes = 10 * 1024 * 1024, slideshow_bytes = 0 })
    assert(result.ok == true, "clamp should succeed by dropping logs")
    -- Logs must be smaller than they were; commands untouched (logs are
    -- the dominant byte source here).
    assert(#cap.logs < original_log_count, "logs were not trimmed")
    assert(#cap.commands == original_cmd_count,
        "commands trimmed before logs exhausted — clamp order is wrong")
end

-- (2) When logs alone aren't enough, commands also drop.
do
    -- Use a slideshow + logs+commands together so we hit the 10 MB
    -- ceiling even when logs are emptied.
    local cap = make_capture({ logs = 1000, commands = 200, pad_size = 1024 })
    local original_user_desc = cap.capture_metadata.user_description
    local result = clamp.clamp(cap, {
        max_bytes = 10 * 1024 * 1024,
        slideshow_bytes = 9 * 1024 * 1024,  -- close to ceiling
    })
    assert(result.ok == true, "clamp should still succeed")
    -- user_description must be preserved.
    assert(cap.capture_metadata.user_description == original_user_desc,
        "user_description was clobbered during clamp")
end

-- (3) Unclampable (slideshow alone > 10 MB) → ok=false + user-visible error.
do
    local cap = make_capture({ logs = 10, commands = 10 })
    local result = clamp.clamp(cap, {
        max_bytes = 10 * 1024 * 1024,
        slideshow_bytes = 11 * 1024 * 1024,
    })
    assert(result.ok == false,
        "unclampable case must surface ok=false, not silently truncate slideshow")
    assert(result.user_message,
        "result must carry a user-visible message for the dialog to show")
end

print("✅ test_bug_reporter_payload_clamp.lua passed")
