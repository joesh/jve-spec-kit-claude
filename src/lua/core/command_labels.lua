--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~32 LOC
-- Volatility: unknown
--
-- @file command_labels.lua
local M = {}

local function split_camel_case(text)
    if type(text) ~= "string" or text == "" then
        return ""
    end

    local spaced = text
    spaced = spaced:gsub("(%l)(%u)", "%1 %2")        -- "fooBar" -> "foo Bar"
    spaced = spaced:gsub("(%u)(%u%l)", "%1 %2")      -- "FCP7XML" -> "FCP7 XML"
    spaced = spaced:gsub("(%d)(%a)", "%1 %2")        -- "7XML" -> "7 XML"
    spaced = spaced:gsub("(%a)(%d)", "%1 %2")        -- "XML7" -> "XML 7"
    spaced = spaced:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return spaced
end

local overrides = {
    BatchRippleEdit = "Ripple Edit",
    RippleDeleteSelection = "Ripple Delete",
    ImportFCP7XML = "Import FCP7 XML",
}

function M.label_for_type(command_type)
    local label = overrides[command_type]
    if label then
        return label
    end
    return split_camel_case(command_type)
end

function M.label_for_command(command)
    if not command or not command.type then
        return ""
    end
    return M.label_for_type(command.type)
end

return M
