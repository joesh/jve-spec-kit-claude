--- relink_rules: the matching-criteria rule set for media reconnection.
--
-- Single source of truth for:
--   - the ordered list of rules (key + label + section) that the relink
--     dialog renders as an always-visible checkbox panel, and
--   - the default rule set, and
--   - the "at least one anchor" validity constraint.
--
-- Lives here (not buried in a modal) because the relink dialog now toggles
-- these rules live and re-classifies in place — there is no separate rules
-- dialog. The relinker (core.media_relinker) consumes the resulting flat
-- {match_filename=…, match_timecode=…, …} table.
--
-- @file relink_rules.lua
local M = {}

-- Ordered rule descriptors. `section` groups them in the panel:
--   "match"   — criteria a candidate must satisfy to be considered a match
--   "options" — relaxations that admit more candidates
-- Order here is the render order.
M.RULES = {
    { key = "match_filename",           label = "Filename",                  section = "match" },
    { key = "match_timecode",           label = "Timecode",                  section = "match" },
    { key = "match_resolution",         label = "Resolution",                section = "match" },
    { key = "match_frame_rate",         label = "Frame Rate",                section = "match" },
    { key = "accept_trimmed_media",     label = "Accept Trimmed Media",      section = "options" },
    { key = "accept_filename_suffixes", label = "Accept Filename Suffixes",  section = "options" },
}

-- The two rules that can anchor identity. At least one must be on, else the
-- matcher has nothing to key candidates by.
M.ANCHOR_KEYS = { "match_filename", "match_timecode" }

--- Default matching rules (filename + timecode on, rest off).
-- @return table flat rule set
function M.default_rules()
    return {
        match_filename = true,
        match_timecode = true,
        match_resolution = false,
        match_frame_rate = false,
        accept_trimmed_media = false,
        accept_filename_suffixes = false,
    }
end

--- Validate a rule set: at least one anchor (filename or timecode) must be on.
-- @param rules table flat rule set
-- @return boolean ok, string|nil error_message
function M.validate(rules)
    assert(type(rules) == "table", "relink_rules.validate: rules table required")
    for _, key in ipairs(M.ANCHOR_KEYS) do
        if rules[key] then return true, nil end
    end
    return false, "At least one of Filename or Timecode must be checked"
end

return M
