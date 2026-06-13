--- Resolve bridge wire-decoding helpers (spec 023).
--- Maps between Resolve's lowercase wire conventions and JVE's uppercase
--- model constants.
---
--- @module core.resolve_bridge.wire_decode

local M = {}

--- Map: Resolve wire track_type -> JVE model track_type.
--- (helper-protocol.md §read_timeline)
M.WIRE_TO_JVE_TRACK_TYPE = {
    video = "VIDEO",
    audio = "AUDIO",
}

--- Map: JVE model track_type -> Resolve wire track_type.
M.JVE_TO_WIRE_TRACK_TYPE = {
    VIDEO = "video",
    AUDIO = "audio",
}

--- Validate that a wire item's `kind` is in the closed set
--- {"media", "non_media"} per helper-protocol.md §read_timeline.
--- Returns (true) on valid, (false, errmsg) on unknown kind.
--- Single source of truth for the kind boundary — adding a new kind
--- tomorrow requires changing this set + every caller that assumed the
--- two-element discriminator. Without this lift, the check was repeated
--- verbatim in discovery.index_items_by_position and
--- sync_edits_from_resolve.translate_wire_response, so a closed-set
--- widening could land in one and not the other.
---
--- Callers MUST NOT assert on the returned error — route it to ambiguous
--- or a structured notify instead (external Resolve wire data; rule 1.14).
---
--- @param kind   string the wire `kind` value
--- @param ctx    string caller label for error messages
--- @return       true | false, errmsg
function M.validate_item_kind(kind, ctx)
    if kind == "media" or kind == "non_media" then return true end
    return false, string.format(
        "%s: kind must be 'media' or 'non_media' (got %q) — "
        .. "helper-protocol §read_timeline closed set",
        ctx, tostring(kind))
end

return M
