--- Shared query engine for Find, Sift, Smart Bins, and Timeline Index.
--
-- Pure-function module with zero dependencies beyond Lua stdlib.
-- All matching is case-insensitive for text operators.
--
-- @file query_engine.lua

local M = {}

-- ============================================================================
-- Searchable fields registry
-- ============================================================================

local SEARCHABLE_FIELDS = {
    -- Clip table fields
    { name = "name",              type = "text",    editable = true,  source = "clip" },
    { name = "enabled",           type = "boolean", editable = true,  source = "clip" },
    { name = "offline",           type = "boolean", editable = false, source = "clip" },
    { name = "volume",            type = "numeric", editable = true,  source = "clip" },
    { name = "duration",          type = "numeric", editable = false, source = "clip" },
    -- Media table fields
    { name = "codec",             type = "text",    editable = false, source = "media" },
    { name = "fps",               type = "numeric", editable = false, source = "media" },
    { name = "width",             type = "numeric", editable = false, source = "media" },
    { name = "height",            type = "numeric", editable = false, source = "media" },
    { name = "audio_channels",    type = "numeric", editable = false, source = "media" },
    { name = "audio_sample_rate", type = "numeric", editable = false, source = "media" },
    { name = "date_modified",     type = "numeric", editable = false, source = "clip" },
    -- Grade reproduction (spec 023 FR-015): 'full'|'approximate'|'not_shown'.
    -- Find clips whose Resolve grade JVE can't fully show (e.g. the spatial
    -- 'not_shown' shots). Absent on ungraded clips → never matches a value.
    { name = "reproduction",      type = "text",    editable = false, source = "clip_grade" },
}

local FIELD_LOOKUP = {}
for _, f in ipairs(SEARCHABLE_FIELDS) do
    FIELD_LOOKUP[f.name] = f
end

-- ============================================================================
-- Value resolution: extract a field's value from clip_data
-- ============================================================================

local function resolve_value(clip_data, column)
    -- Direct clip/media fields
    if clip_data[column] ~= nil then
        return clip_data[column]
    end
    -- Custom properties (Scene, Take, Shot, Comments, etc.)
    if clip_data.properties and clip_data.properties[column] ~= nil then
        return clip_data.properties[column]
    end
    return nil
end

-- ============================================================================
-- Text matching operators (all case-insensitive)
-- ============================================================================

local function text_contains(haystack, needle)
    return string.find(string.lower(tostring(haystack)), string.lower(needle), 1, true) ~= nil
end

local function text_begins_with(haystack, prefix)
    local h = string.lower(tostring(haystack))
    local p = string.lower(prefix)
    return h:sub(1, #p) == p
end

local function text_ends_with(haystack, suffix)
    local h = string.lower(tostring(haystack))
    local s = string.lower(suffix)
    if #s > #h then return false end
    return h:sub(-#s) == s
end

local function text_matches_exactly(haystack, target)
    return string.lower(tostring(haystack)) == string.lower(target)
end

-- ============================================================================
-- Numeric matching operators
-- ============================================================================

local function to_number_strict(val)
    if type(val) == "number" then return val end
    if type(val) == "boolean" then return val and 1 or 0 end
    return tonumber(tostring(val))
end

local function numeric_equals(actual, expected)
    local a = to_number_strict(actual)
    local e = to_number_strict(expected)
    if a == nil or e == nil then return false end
    return a == e
end

local function numeric_greater_than(actual, threshold)
    local a = to_number_strict(actual)
    local t = to_number_strict(threshold)
    if a == nil or t == nil then return false end
    return a > t
end

local function numeric_less_than(actual, threshold)
    local a = to_number_strict(actual)
    local t = to_number_strict(threshold)
    if a == nil or t == nil then return false end
    return a < t
end

-- ============================================================================
-- Boolean matching
-- ============================================================================

local function boolean_equals(actual, expected_str)
    local expected = (string.lower(expected_str) == "true")
    if type(actual) == "boolean" then
        return actual == expected
    end
    -- numeric: 0/1
    if type(actual) == "number" then
        return (actual ~= 0) == expected
    end
    return false
end

-- ============================================================================
-- Operator dispatch
-- ============================================================================

local TEXT_OPERATORS = {
    contains = text_contains,
    begins_with = text_begins_with,
    ends_with = text_ends_with,
    matches_exactly = text_matches_exactly,
}

local NUMERIC_OPERATORS = {
    equals = numeric_equals,
    greater_than = numeric_greater_than,
    less_than = numeric_less_than,
}

-- ============================================================================
-- Public API
-- ============================================================================

--- Test whether a clip matches a single query criterion.
-- @param clip_data table with clip fields + properties subtable
-- @param query table with column, operator, value
-- @return boolean
function M.match(clip_data, query)
    assert(query.column, "query_engine.match: column is required")
    assert(query.operator, "query_engine.match: operator is required")
    assert(query.value and query.value ~= "", "query_engine.match: value is required and must not be empty")

    -- "Any" column: match if ANY text field matches
    if query.column == "Any" then
        -- Try all direct text fields
        for _, field_name in ipairs({"name", "codec"}) do
            local val = resolve_value(clip_data, field_name)
            if val and M.match(clip_data, {column = field_name, operator = query.operator, value = query.value}) then
                return true
            end
        end
        -- Try all custom properties
        if clip_data.properties then
            for prop_name, prop_val in pairs(clip_data.properties) do
                if type(prop_val) == "string" and prop_val ~= "" then
                    if M.match(clip_data, {column = prop_name, operator = query.operator, value = query.value}) then
                        return true
                    end
                end
            end
        end
        return false
    end

    local raw = resolve_value(clip_data, query.column)
    if raw == nil then
        return false
    end

    -- Determine field type from registry, or infer from value
    local field_info = FIELD_LOOKUP[query.column]
    local field_type = field_info and field_info.type or "text"

    -- Boolean fields use boolean matching
    if field_type == "boolean" then
        if query.operator == "equals" then
            return boolean_equals(raw, query.value)
        end
        return false
    end

    -- Try text operators first
    local text_fn = TEXT_OPERATORS[query.operator]
    if text_fn then
        return text_fn(raw, query.value)
    end

    -- Try numeric operators
    local num_fn = NUMERIC_OPERATORS[query.operator]
    if num_fn then
        return num_fn(raw, query.value)
    end

    assert(false, string.format("query_engine.match: unknown operator '%s'", query.operator))
end

--- Test whether a clip matches ALL queries (AND logic).
-- @param clip_data table
-- @param queries array of query tables
-- @return boolean
function M.match_all(clip_data, queries)
    for _, q in ipairs(queries) do
        if not M.match(clip_data, q) then
            return false
        end
    end
    return true
end

--- Filter a list of clips into matching and non-matching arrays.
-- @param clips array of clip_data tables
-- @param queries array of query tables (AND logic)
-- @return matching array, non_matching array
function M.filter(clips, queries)
    local matching = {}
    local non_matching = {}
    for _, clip in ipairs(clips) do
        if M.match_all(clip, queries) then
            matching[#matching + 1] = clip
        else
            non_matching[#non_matching + 1] = clip
        end
    end
    return matching, non_matching
end

--- Return the registry of all searchable fields.
-- @return array of {name, type, editable, source}
function M.get_searchable_fields()
    -- Return a copy so callers can't corrupt the registry
    local result = {}
    for _, f in ipairs(SEARCHABLE_FIELDS) do
        result[#result + 1] = {
            name = f.name,
            type = f.type,
            editable = f.editable,
            source = f.source,
        }
    end
    return result
end

return M
