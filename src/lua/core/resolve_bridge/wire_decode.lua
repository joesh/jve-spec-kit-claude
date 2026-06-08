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

return M
