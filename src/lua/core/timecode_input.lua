-- Flexible timecode input parsing for NLE-style "go to" fields.
--
-- Supports:
--   - Absolute:  "01:02:03:04", "1:23" (right-aligned), "1234" (right-aligned digits)
--   - Relative:  "+10" / "-10" (frames), "+1:00" (timecode right-aligned), "+2s", "-3m"
--
-- Design goals:
--   - Never crash on user input; return (nil, err) for invalid strings.
--   - No hidden default frame rates; frame_rate must be provided by caller.
--   - "Right-aligned" interpretation for segmented inputs with <4 fields.

local Rational = require("core.rational")

local M = {}

local function trim(s)
    return (s and s:match("^%s*(.-)%s*$")) or ""
end

local function require_frame_rate(frame_rate)
    if type(frame_rate) ~= "table" then
        return nil, "frame_rate must be a table"
    end
    if type(frame_rate.fps_numerator) ~= "number" or type(frame_rate.fps_denominator) ~= "number" then
        return nil, "frame_rate must include fps_numerator/fps_denominator"
    end
    if frame_rate.fps_denominator == 0 then
        return nil, "frame_rate fps_denominator must be non-zero"
    end
    return frame_rate, nil
end

local function fps_integer(frame_rate)
    local fps = math.floor((frame_rate.fps_numerator / frame_rate.fps_denominator) + 0.5)
    if fps <= 0 then
        return nil, "invalid fps"
    end
    return fps, nil
end

local function parse_duration_suffix(number_text, suffix, frame_rate)
    local fps, fps_err = fps_integer(frame_rate)
    if not fps then
        return nil, fps_err
    end
    local number_value = tonumber(number_text)
    if not number_value then
        return nil, "invalid number"
    end

    local scale = suffix:lower()
    if scale == "f" then
        return math.floor(number_value + 0.0), nil
    elseif scale == "s" then
        return math.floor((number_value * fps) + 0.5), nil
    elseif scale == "m" then
        return math.floor((number_value * 60 * fps) + 0.5), nil
    elseif scale == "h" then
        return math.floor((number_value * 3600 * fps) + 0.5), nil
    end
    return nil, "unsupported suffix"
end

local function right_align_fields(fields)
    local padded = {0, 0, 0, 0}
    local start = 4 - #fields + 1
    for i = 1, #fields do
        padded[start + i - 1] = fields[i]
    end
    return padded[1], padded[2], padded[3], padded[4]
end

local function parse_segmented_timecode(text, frame_rate)
    local cleaned = trim(text)
    if cleaned == "" then
        return nil, "empty"
    end

    local fields = {}
    local current = ""
    local saw_digit = false
    for i = 1, #cleaned do
        local ch = cleaned:sub(i, i)
        if ch:match("%d") then
            current = current .. ch
            saw_digit = true
        elseif ch == ":" or ch == ";" or ch == "." then
            if current == "" then
                table.insert(fields, 0)
            else
                table.insert(fields, tonumber(current))
            end
            current = ""
        else
            return nil, "invalid character"
        end
    end
    if current == "" then
        table.insert(fields, 0)
    else
        table.insert(fields, tonumber(current))
    end

    if not saw_digit then
        return nil, "no digits"
    end
    if #fields > 4 then
        return nil, "too many fields"
    end

    local fps, fps_err = fps_integer(frame_rate)
    if not fps then
        return nil, fps_err
    end

    local hh, mm, ss, ff = right_align_fields(fields)
    local total_frames = (((hh * 60) + mm) * 60 + ss) * fps + ff
    return total_frames, nil
end

local function parse_right_aligned_digits(text, frame_rate)
    if not text:match("^%d+$") then
        return nil, "not digits"
    end
    local digits = text
    if #digits > 8 then
        return nil, "too many digits"
    end
    digits = string.rep("0", 8 - #digits) .. digits

    local hh = tonumber(digits:sub(1, 2))
    local mm = tonumber(digits:sub(3, 4))
    local ss = tonumber(digits:sub(5, 6))
    local ff = tonumber(digits:sub(7, 8))
    local fps, fps_err = fps_integer(frame_rate)
    if not fps then
        return nil, fps_err
    end
    local total_frames = (((hh * 60) + mm) * 60 + ss) * fps + ff
    return total_frames, nil
end

local function parse_absolute_frames(text, frame_rate)
    local number_text, suffix = text:match("^(%d+)%s*([fFsSmMhH])$")
    if number_text and suffix then
        return parse_duration_suffix(number_text, suffix, frame_rate)
    end
    return nil, "not a suffixed duration"
end

local function parse_timecode_or_digits(text, frame_rate)
    if text:find("[:;%.]") then
        return parse_segmented_timecode(text, frame_rate)
    end
    local frames, err = parse_absolute_frames(text, frame_rate)
    if frames ~= nil then
        return frames, nil
    end
    return parse_right_aligned_digits(text, frame_rate)
end

--- Parse timecode input string into a Rational time.
-- @param text string: user input
-- @param frame_rate table: sequence frame rate (required)
-- @param opts table|nil: { base_time = Rational } enables relative +/-
-- @return Rational|nil, string|nil
function M.parse(text, frame_rate, opts)
    local rate, rate_err = require_frame_rate(frame_rate)
    if not rate then
        return nil, rate_err
    end

    local cleaned = trim(text)
    if cleaned == "" then
        return nil, "empty"
    end

    local sign = 1
    local first = cleaned:sub(1, 1)
    if first == "+" or first == "-" then
        sign = (first == "-") and -1 or 1
        cleaned = trim(cleaned:sub(2))
    end

    if cleaned == "" then
        return nil, "empty"
    end

    local base_time = (opts and opts.base_time) or nil
    local is_relative = (first == "+" or first == "-") and base_time ~= nil

    local frames
    local err
    if is_relative and cleaned:match("^%d+$") then
        frames = tonumber(cleaned)
        err = frames and nil or "invalid number"
    else
        frames, err = parse_timecode_or_digits(cleaned, rate)
    end

    if frames == nil then
        return nil, err or "invalid"
    end

    frames = frames * sign
    local time_obj = Rational.new(frames, rate.fps_numerator, rate.fps_denominator)
    if is_relative then
        local base = Rational.hydrate(base_time, rate.fps_numerator, rate.fps_denominator)
        if not base then
            return nil, "base_time invalid"
        end
        return base + time_obj, nil
    end
    return time_obj, nil
end

return M
