--- SetClipLayer command (Feature 013, T053).
---
--- Sets a per-clip video-layer override. The override picks one of the
--- referenced sequence's V tracks; NULL means "track the referenced
--- sequence's default_video_layer_track_id" (which INV-8 keeps valid).
---
--- Per FR-013 and contracts/commands.md §SetClipLayer:
---   Args: { sequence_id, clip_id, track_id_or_null }
---   sequence_id is the clip's owner_sequence_id (rule 2.29).
---   track_id (if non-NULL) MUST belong to clip.nested_sequence_id.
---     A track_id that resolves to a different sequence is a corrupt
---     command — refuse loudly (rule 1.14 / rule 2.13: no fallback).
---   Mutation: UPDATE clips SET master_layer_track_id = ? WHERE id = ?.
---   Undo capture: previous master_layer_track_id (or NULL).
---
--- Signals: sequence_content_changed(sequence_id) — affects the renderer
--- pull path for clips of this clip's edit timeline.
---
--- @file set_clip_layer.lua

local M = {}

local Clip  = require("models.clip")
local Track = require("models.track")
local log   = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "SetClipLayer: '%s' is required (rule 2.29)", name))
    return v
end

--- Pure-logic entry point. Returns an undo-capture table that can be
--- passed to M.undo to reverse the mutation. Does NOT touch
--- command_manager — wiring is in M.register.
---
--- @param args table { sequence_id, clip_id, track_id (string|nil) }
--- @return table { sequence_id, clip_id, prior_track_id }
function M.execute(args)
    assert(type(args) == "table", "SetClipLayer.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")
    local track_id    = args.track_id  -- nullable: NULL means "inherit default"

    local clip = Clip.load_v13_row(clip_id)
    assert(clip, string.format(
        "SetClipLayer: clip %s not found", tostring(clip_id)))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "SetClipLayer: sequence_id mismatch — clip %s owner=%s, args=%s "
        .. "(rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))

    if track_id ~= nil then
        assert(type(track_id) == "string" and track_id ~= "",
            "SetClipLayer: track_id must be non-empty string or nil")
        local owner = Track.get_sequence_id(track_id)
        assert(owner, string.format(
            "SetClipLayer: track %s does not exist", track_id))
        assert(owner == clip.nested_sequence_id, string.format(
            "SetClipLayer: track %s belongs to sequence %s, not the clip's "
            .. "nested_sequence_id %s. The per-clip layer override must "
            .. "name a track of the directly-referenced sequence (FR-013).",
            track_id, owner, clip.nested_sequence_id))
    end

    local prior_track_id = clip.master_layer_track_id

    Clip.set_master_layer_track_id(clip_id, track_id)

    log.event("SetClipLayer: clip=%s %s -> %s",
        clip_id, tostring(prior_track_id), tostring(track_id))

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)

    return {
        sequence_id     = sequence_id,
        clip_id         = clip_id,
        prior_track_id  = prior_track_id,
    }
end

--- Reverse a previous M.execute. Restores the prior layer override,
--- whatever it was (string or NULL).
---
--- @param capture table  the value returned by M.execute
function M.undo(capture)
    assert(type(capture) == "table",
        "SetClipLayer.undo: capture table required")
    local clip_id        = capture.clip_id
    local prior_track_id = capture.prior_track_id   -- may be nil

    Clip.set_master_layer_track_id(clip_id, prior_track_id)

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", capture.sequence_id)
end

-- ---------------------------------------------------------------------------
-- M.register — command_manager wiring. Mirrors the Phase 3.4 pattern.
-- ---------------------------------------------------------------------------

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },
        track_id    = {},   -- nullable: NULL clears the override
    },
    persisted = {
        prior_track_id = { kind = "string" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetClipLayer"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetClipLayer: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local capture = capture_or_err
        -- prior_track_id is nullable (NULL = inherit nested sequence's
        -- default). Persist nil-vs-set distinctly — no '' sentinel.
        if capture.prior_track_id ~= nil then
            command:set_parameter("prior_track_id", capture.prior_track_id)
        end
        return true
    end

    command_undoers["SetClipLayer"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id     = args.sequence_id,
            clip_id         = args.clip_id,
            prior_track_id  = args.prior_track_id,  -- nullable
        })
        return true
    end

    return {
        executor = command_executors["SetClipLayer"],
        undoer   = command_undoers["SetClipLayer"],
        spec     = SPEC,
    }
end

return M
