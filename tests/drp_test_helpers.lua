-- Shared XML-element builders for DRP importer tests.
--
-- The DRP test corpus builds in-memory XML trees in the shape produced by
-- qt_xml_parse (tag, attrs, children, text). Before this helper existed,
-- nine test files inlined identical copies of elem()/wrap_clips() and a
-- 2026-06-07 signature widening had to touch all nine in lockstep.

local M = {}

-- elem(tag, text)              — text-only element
-- elem(tag, "", children)      — children-only (no text, no attrs)
-- elem(tag, attrs_table)       — attrs-only (no children, no text)
-- elem(tag, attrs_table, children) — attrs + children
function M.elem(tag, text_or_attrs, children)
    local text  = type(text_or_attrs) == "string" and text_or_attrs or ""
    local attrs = type(text_or_attrs) == "table"  and text_or_attrs or {}
    return {
        tag      = tag,
        attrs    = attrs,
        children = children or {},
        text     = text,
    }
end

-- Wrap clip elements in the <Items>/<Element> shell qt_xml_parse produces.
function M.wrap_clips(...)
    local elements = {}
    for _, clip in ipairs({...}) do
        table.insert(elements, M.elem("Element", "", {clip}))
    end
    return M.elem("Items", "", elements)
end

return M
