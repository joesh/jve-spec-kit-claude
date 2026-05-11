--- Auto-patch defaults (Feature 015, FR-029).
---
--- When a source clip is first loaded into the source viewer and the record
--- sequence has no patches yet, create identity patches (source V1→rec V1,
--- A1→A1, etc.) so the patch buttons appear immediately without manual wiring.
---
--- Only fires when the record sequence has ZERO patches.  Once the user has
--- any patches (including ones they have customised), this is a no-op.
---
--- @file auto_patch_defaults.lua

local M = {}

local Patch       = require("models.patch")
local Track       = require("models.track")
local command_mgr = require("core.command_manager")

--- Create identity patches for each source track if the record seq has none.
-- @param record_seq_id string  The active record sequence.
-- @param source_seq_id string  The master sequence loaded in the source monitor.
-- @param project_id    string  Required by SetPatch.
function M.apply_if_empty(record_seq_id, source_seq_id, project_id)
    assert(type(record_seq_id) == "string" and record_seq_id ~= "",
        "auto_patch_defaults: record_seq_id required")
    assert(type(source_seq_id) == "string" and source_seq_id ~= "",
        "auto_patch_defaults: source_seq_id required")
    assert(type(project_id) == "string" and project_id ~= "",
        "auto_patch_defaults: project_id required")

    local existing = Patch.find_by_sequence(record_seq_id)
    if #existing > 0 then return end  -- user already has patches; never override

    local function patch_tracks(track_type)
        local tracks = Track.find_by_sequence(source_seq_id, track_type)
        for _, t in ipairs(tracks) do
            command_mgr.execute("SetPatch", {
                sequence_id        = record_seq_id,
                source_track_index = t.track_index,
                record_track_index = t.track_index,
                track_type         = track_type,
                project_id         = project_id,
                enabled            = true,
            })
        end
    end

    patch_tracks("VIDEO")
    patch_tracks("AUDIO")
end

return M
