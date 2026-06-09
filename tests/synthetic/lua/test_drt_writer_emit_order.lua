-- Lock the contract that drt_writer owns the emit-order map.
-- SendToResolve sends `clip_positions = authored.emit_order` to the
-- helper; the helper matches imported timeline items by
-- (track_type, track_index, record_start). If the writer's track
-- partition (VideoTrackVec then AudioTrackVec, 1-based per-type
-- index, JVE order preserved within a type) ever drifts, the
-- helper's position-match silently fails — every clip becomes
-- "unkeyed" and the mapping is empty.
--
-- Behavior verified WITHOUT looking at compute_emit_order's source:
-- given a payload whose tracks are interleaved V/A/V/A with multiple
-- clips per track, what must the helper see? See helper-protocol.md
-- §import_timeline + drt_writer's VideoTrackVec/AudioTrackVec layout.

require("test_env")
local drt_writer = require("exporters.drt_writer")

local seq = {
    name = "S",
    fps = 24,
    tracks = {
        { type = "video", clips = {
            { id = "vA1", sequence_start = 100 },
            { id = "vA2", sequence_start = 250 },
        }},
        { type = "audio", clips = {
            { id = "aA1", sequence_start = 100 },
        }},
        { type = "video", clips = {
            { id = "vB1", sequence_start = 175 },
        }},
        { type = "audio", clips = {
            { id = "aB1", sequence_start = 50 },
            { id = "aB2", sequence_start = 400 },
        }},
    },
}

local order = drt_writer.compute_emit_order(seq)

-- 5 video-track entries (2+1) come before 3 audio-track entries (1+2)?
-- Helper-protocol partition is VideoTrackVec then AudioTrackVec.
local function find(clip_id)
    for i, e in ipairs(order) do
        if e.clip_id == clip_id then return i, e end
    end
    error("clip not found in emit_order: " .. clip_id)
end

local _, e_vA1 = find("vA1")
local _, e_vA2 = find("vA2")
local _, e_vB1 = find("vB1")
local _, e_aA1 = find("aA1")
local _, e_aB1 = find("aB1")
local _, e_aB2 = find("aB2")

assert(e_vA1.track_type == "video" and e_vA1.track_index == 1,
    "vA1 must be video track 1")
assert(e_vA2.track_type == "video" and e_vA2.track_index == 1,
    "vA2 must be video track 1 (same track)")
assert(e_vB1.track_type == "video" and e_vB1.track_index == 2,
    "vB1 must be video track 2 (second video track in JVE order)")
assert(e_aA1.track_type == "audio" and e_aA1.track_index == 1,
    "aA1 must be audio track 1")
assert(e_aB1.track_type == "audio" and e_aB1.track_index == 2
    and e_aB2.track_index == 2,
    "aB1/aB2 must be audio track 2 (second audio track in JVE order)")

assert(e_vA1.record_start == 100, "record_start preserved (vA1)")
assert(e_vB1.record_start == 175, "record_start preserved (vB1)")
assert(e_aB2.record_start == 400, "record_start preserved (aB2)")

-- Unknown track type must crash (rule 1.14, no silent emit-order corruption).
local ok = pcall(function()
    drt_writer.compute_emit_order({
        tracks = { { type = "subtitle", clips = {} } },
    })
end)
assert(not ok, "compute_emit_order must reject unknown track.type")

print("✅ test_drt_writer_emit_order.lua passed")
