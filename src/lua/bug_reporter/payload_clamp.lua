-- Payload size clamp for the bug-reporter pipeline (feature 027 T027/T049).
--
-- FR-024a: app clamps total request size to 10 MB BEFORE sending.
-- Clamp order:
--   (1) oldest log entries dropped first
--   (2) then commands (oldest first)
--   (3) slideshow.mp4 preserved
--   (4) user description preserved
-- Unclampable (slideshow alone > cap) → returns {ok=false,
-- user_message} so the dialog surfaces an actionable refusal — no
-- silent truncation of the slideshow.

local dkjson = require("dkjson")

local M = {}

local function encoded_size(t)
    return #dkjson.encode(t)
end

-- opts: { max_bytes, slideshow_bytes }
function M.clamp(capture, opts)
    assert(type(capture) == "table",   "payload_clamp: capture required")
    assert(type(opts) == "table",      "payload_clamp: opts required")
    local max_bytes = opts.max_bytes
    local slideshow_bytes = opts.slideshow_bytes or 0
    assert(type(max_bytes) == "number" and max_bytes > 0,
        "payload_clamp: opts.max_bytes must be positive number")

    if slideshow_bytes > max_bytes then
        return {
            ok = false,
            user_message = string.format(
                "Bug report is too large to send (%d MB; max %d MB). " ..
                "Try the 'Text only' option to exclude the slideshow.",
                math.floor(slideshow_bytes / (1024 * 1024)),
                math.floor(max_bytes / (1024 * 1024))),
        }
    end

    -- Per-iteration full re-encode is O(N²) for log-heavy captures and
    -- locks up on the realistic 10k+ entry input. Instead measure once,
    -- estimate per-entry bytes, drop bulk slices.
    local function total_bytes()
        return slideshow_bytes + encoded_size(capture)
    end

    -- Step 1: drop oldest logs in bulk to get under the cap.
    if capture.logs and #capture.logs > 0 then
        local current = total_bytes()
        local excess = current - max_bytes
        if excess > 0 then
            local per_entry = math.max(1, math.floor((current - slideshow_bytes - encoded_size({
                gestures = capture.gestures, commands = capture.commands,
                logs = {}, screenshots = capture.screenshots,
                capture_metadata = capture.capture_metadata,
            })) / #capture.logs))
            local drop = math.min(#capture.logs, math.ceil(excess / per_entry) + 16)
            for _ = 1, drop do table.remove(capture.logs, 1) end
        end
    end

    -- Step 2: if still over, drop commands in bulk.
    if total_bytes() > max_bytes and capture.commands and #capture.commands > 0 then
        local current = total_bytes()
        local excess = current - max_bytes
        local per_entry = math.max(1, math.floor(encoded_size({ commands = capture.commands }) / #capture.commands))
        local drop = math.min(#capture.commands, math.ceil(excess / per_entry) + 4)
        for _ = 1, drop do table.remove(capture.commands, 1) end
    end

    if total_bytes() > max_bytes then
        -- Still over — only gestures + screenshots left + slideshow.
        -- The user-description is preserved; slideshow is preserved.
        return {
            ok = false,
            user_message = string.format(
                "Bug report is too large after trimming logs and commands " ..
                "(%d MB; max %d MB). Try the 'Text only' option.",
                math.floor(total_bytes() / (1024 * 1024)),
                math.floor(max_bytes / (1024 * 1024))),
        }
    end

    return { ok = true, total_bytes = total_bytes() }
end

return M
