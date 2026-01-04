-- Golden Test 4: False Positive Guard (No Leverage When None Exists)
-- This cluster should be ACCEPTED with NO leverage point identified
-- Reason: Coherent data construction, no responsibility tension, trivial context differences

local M = {}
local display_cache = {}

-- Domain: Media display name construction
-- Responsibility: Build display strings from media metadata
-- All functions have similar context breadth (within ±1)

-- Public API: Build display name for media item (nucleus candidate)
function M.build_display_name(media)
    local parts = {}
    parts[#parts + 1] = add_name_part(media)
    parts[#parts + 1] = add_duration_part(media)
    parts[#parts + 1] = add_type_part(media)

    local display_name = table.concat(parts, " - ")
    display_cache[media.id] = display_name

    return display_name
end

-- Internal: Add name part to display string
local function add_name_part(media)
    return media.name
end

-- Internal: Add duration part to display string
local function add_duration_part(media)
    local minutes = math.floor(media.duration_ms / 60000)
    return minutes .. "m"
end

-- Internal: Add type part to display string
local function add_type_part(media)
    return "[" .. media.type .. "]"
end

return M
