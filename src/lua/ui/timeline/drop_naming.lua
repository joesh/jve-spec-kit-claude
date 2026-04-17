--- Naming helpers for sequences auto-created by dropping media onto an
--- otherwise empty timeline (feature 010, FR-011).
---
--- Pure Lua: no Qt, no DB. Testable without --test mode. Lives in its own
--- module so timeline_panel (which touches qt_constants at load time) is
--- not on the test require chain.
---
--- @file drop_naming.lua

local M = {}

--- Build the name of a sequence auto-created from a drop of one or more
--- clips. The name is the first clip's name verbatim when it stands alone,
--- or "<first-clip-name> (+N more)" when other clips were added alongside.
--- The " more" suffix is plural-agnostic to avoid an off-by-one surprise
--- at N=1.
---
--- @param first_name string: the first clip placed into the new sequence
--- @param additional number: count of additional clips (must be >= 0)
--- @return string
function M.build_drop_sequence_name(first_name, additional)
    assert(type(first_name) == "string" and first_name ~= "",
        "build_drop_sequence_name: first_name must be a non-empty string")
    assert(type(additional) == "number" and additional >= 0
        and additional == math.floor(additional),
        "build_drop_sequence_name: additional must be a non-negative integer")

    if additional == 0 then
        return first_name
    end
    return string.format("%s (+%d more)", first_name, additional)
end

return M
