--- Renders user-facing popups for source-resolution problems detected
--- by `core.effective_source.resolve_for_edit`. Lives in `ui/` because
--- the copy is a UI concern; `effective_source` only returns structured
--- problem tables.
---
--- @file ui/edit_source_popup.lua

local qt_constants = require("core.qt_constants")

local M = {}

local function require_str(problem, field)
    local v = problem[field]
    assert(type(v) == "string" and v ~= "", string.format(
        "edit_source_popup: problem.kind=%q requires string field %q (got %s)",
        problem.kind, field, type(v)))
    return v
end

local function quote(s) return string.format('"%s"', s) end

local function show_error(title, message)
    qt_constants.DIALOG.SHOW_CONFIRM({
        title        = title,
        message      = message,
        icon         = "error",
        confirm_text = "OK",
    })
end

local function show_not_insertable(problem)
    show_error(
        "Not an insertable type",
        string.format(
            "%s is not an insertable type. Please load a clip or sequence "
            .. "into the source viewer, or select one in the project browser.",
            quote(require_str(problem, "label"))))
end

local function show_missing_item(problem)
    show_error(
        "Missing item",
        string.format(
            "%s requires an item to insert. Please load a clip or sequence "
            .. "into the source viewer, or select one in the project browser.",
            require_str(problem, "cmd")))
end

local function show_cycle_self(problem)
    show_error(
        "Would create a cycle",
        string.format(
            "Can't add %s to itself as that would create a cycle.",
            quote(require_str(problem, "seq_name"))))
end

local function show_cycle_transitive(problem)
    local dest = quote(require_str(problem, "dest_name"))
    local src  = quote(require_str(problem, "src_name"))
    show_error(
        "Would create a cycle",
        string.format(
            "%s is already inside %s. Adding %s would create a cycle.",
            dest, src, src))
end

local DISPATCH = {
    not_insertable   = show_not_insertable,
    missing_item     = show_missing_item,
    cycle_self       = show_cycle_self,
    cycle_transitive = show_cycle_transitive,
}

--- Show the popup matching `problem.kind`. Asserts on unknown kinds —
--- silent fallback would hide a contract breach between the resolver
--- and the popup layer.
function M.show(problem)
    assert(type(problem) == "table" and type(problem.kind) == "string",
        "edit_source_popup.show: problem table with string .kind required")
    local handler = DISPATCH[problem.kind]
    assert(handler, string.format(
        "edit_source_popup.show: unknown problem.kind %q", problem.kind))
    handler(problem)
end

return M
