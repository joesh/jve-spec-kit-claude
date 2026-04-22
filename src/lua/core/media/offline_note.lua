--- offline_note: pure helpers for decoding the JSON diagnostic the
--- relinker writes into media.offline_note and deriving per-clip
--- shortfall information.
---
--- Shape of the stored note (see schema.sql comment on media):
---   { kind = "partial_coverage",
---     candidate_path = "/fixture/.../X.mov",
---     covered_start_tc = <int>,  -- in stored_rate frames/samples
---     covered_end_tc   = <int>,
---     rate = <int> }
---
--- All functions are pure — no IO, no Qt. Offline_frame_cache uses
--- these to compose the monitor's offline frame; timeline_view_renderer
--- uses them to append a short "(short Nf)" suffix to clip labels so
--- the user can see at a glance which clips have partial coverage.
---
--- @file offline_note.lua

local json = require("dkjson")

local M = {}

--- Decode a JSON offline_note string. Returns nil for nil/empty/invalid
--- input — callers should treat the absence of a note as "no diagnostic."
--- @param raw string|nil
--- @return table|nil parsed note
function M.parse(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    local parsed, _, err = json.decode(raw)
    if err or type(parsed) ~= "table" then return nil end
    return parsed
end

--- Compute the per-clip shortfall implied by a partial_coverage note.
--- Returns {head, tail, rate} in stored_rate frames (or samples, for
--- audio). Missing-frame deltas are non-negative. Returns nil when the
--- note isn't a partial_coverage shape, clip range is missing, or the
--- candidate actually covers the clip (no shortfall to report).
---
--- @param note table       parsed offline_note
--- @param source_in number clip source_in in stored_rate units
--- @param source_out number clip source_out in stored_rate units
--- @return table|nil {head_missing, tail_missing, rate}
function M.shortfall(note, source_in, source_out)
    if type(note) ~= "table" or note.kind ~= "partial_coverage" then
        return nil
    end
    if type(source_in) ~= "number" or type(source_out) ~= "number" then
        return nil
    end
    -- covered_*_tc + rate are documented invariants of a partial_coverage
    -- note (see media.offline_note comment in schema.sql) — missing fields
    -- are a writer bug, not a runtime state to degrade from.
    assert(type(note.covered_start_tc) == "number",
        "offline_note.shortfall: partial_coverage note missing covered_start_tc")
    assert(type(note.covered_end_tc) == "number",
        "offline_note.shortfall: partial_coverage note missing covered_end_tc")
    assert(type(note.rate) == "number" and note.rate > 0,
        "offline_note.shortfall: partial_coverage note missing/invalid rate")
    local head = math.max(0, note.covered_start_tc - source_in)
    local tail = math.max(0, source_out - note.covered_end_tc)
    if head == 0 and tail == 0 then return nil end
    return {
        head_missing = head,
        tail_missing = tail,
        rate = note.rate,
    }
end

--- Format a frame delta for compact inline display. "3f", "120f (~5s)".
--- Called after `shortfall` has produced positive numeric head/tail with a
--- valid rate — inputs are compose-time invariants.
--- @param frames number  must be > 0
--- @param rate number    must be > 0
--- @return string
function M.format_frame_delta(frames, rate)
    assert(type(frames) == "number" and frames > 0,
        "offline_note.format_frame_delta: frames must be a positive number")
    assert(type(rate) == "number" and rate > 0,
        "offline_note.format_frame_delta: rate must be a positive number")
    if frames < rate then
        return string.format("%df", frames)
    end
    local secs = frames / rate
    if secs < 60 then
        return string.format("%df (~%.1fs)", frames, secs)
    end
    return string.format("%df (~%ds)", frames, math.floor(secs + 0.5))
end

--- Compact frames-only delta. Skips the "(~Ns)" hint because inline
--- label space is precious. Use format_frame_delta for prose contexts
--- (offline frame composer) where seconds clarify long deltas.
local function short_delta(frames)
    return string.format("%df", frames)
end

--- Rescale a delta from the note's stored rate to a display rate.
--- For audio clips the note carries samples (rate = 48000 etc.); when
--- the label is rendered inline on a timeline whose fps is ~25, the
--- user wants frames, not samples. Video clips with matching rates
--- pass through unchanged. Pass display_rate=nil to skip conversion.
local function rescale(frames, from_rate, to_rate)
    if not to_rate or not from_rate or from_rate <= 0 then return frames end
    if math.abs(from_rate - to_rate) < 0.01 then return frames end
    return math.floor(frames * to_rate / from_rate + 0.5)
end

--- Format a compact inline suffix for a clip label, e.g.
---   " (short 3f)"        tail-only shortfall
---   " (short head:45f)"  head-only
---   " (short 45f+3f)"    both ends
--- Returns empty string when the note is missing, isn't partial_coverage,
--- or the clip is fully covered. Frames-only — no seconds hint, because
--- this goes on the clip label where every character competes with the
--- media name for visible space.
---
--- display_rate optional: target rate for the delta. Use the timeline
--- sequence's fps so audio shortfalls (stored in samples at 48000 Hz)
--- render as video frames instead of the raw 1524-sample number that
--- looks like video frames but isn't.
---
--- @param note table|string|nil raw JSON string OR already-parsed table
--- @param source_in number
--- @param source_out number
--- @param display_rate number|nil target rate for the formatted delta
--- @return string
function M.short_suffix(note, source_in, source_out, display_rate)
    if type(note) == "string" then note = M.parse(note) end
    local sf = M.shortfall(note, source_in, source_out)
    if not sf then return "" end
    local head = rescale(sf.head_missing, sf.rate, display_rate)
    local tail = rescale(sf.tail_missing, sf.rate, display_rate)
    -- After rescaling a small sample count to a slow frame rate, a
    -- real shortfall can round to zero (e.g., 50 samples @48k → 0f
    -- @25fps). Suppress the suffix for sub-frame deltas — the clip
    -- will still appear offline; there's just nothing interesting
    -- to say at label granularity.
    if head == 0 and tail == 0 then return "" end
    if head > 0 and tail > 0 then
        return string.format(" (short %s+%s)",
            short_delta(head), short_delta(tail))
    elseif head > 0 then
        return string.format(" (short head:%s)", short_delta(head))
    else
        return string.format(" (short %s)", short_delta(tail))
    end
end

return M
