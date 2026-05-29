--- LinkSelectedClips — keyboard/menu adapter for the pure-model LinkClips.
--
-- LinkClips (core.commands.link_clips) is pure-model: callers must
-- supply `clips` as a list of `{clip_id, role, time_offset}`. The
-- Cmd+L keymap binding has no gesture to carry that list, so this
-- adapter builds it from the current timeline selection.
--
-- Resolution policy:
--   - Read the current clip selection via timeline_state.get_selected_clips().
--   - Filter to non-gap clips on tracks whose track_type is "VIDEO" or
--     "AUDIO" (the only roles clip_link.add_to_group accepts;
--     see models/clip_link.lua:135).
--   - Build the clips list: `role = "video"|"audio"` (lowercase per
--     clip_link.add_to_group's assertion), `time_offset = 0` (the
--     default for synced linking — clips with non-zero time offsets
--     are an advanced case the keyboard binding doesn't model).
--   - Refuse with a user-facing log.event when fewer than 2 valid
--     clips are present (the LinkClips contract requires ≥2).
--
-- This adapter is undoable=false: the nested LinkClips call owns the
-- single user-visible undo entry, so Cmd+Z reverts the link cleanly.
--
-- Parallels BladeAtPlayhead (see specs/013-timeline-placements-as/
-- contracts/commands.md "Cmd+B keyboard adapter") — same pattern of
-- thin keyboard adapter around a pure-model command.

local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
    },
}

local TRACK_TYPE_TO_ROLE = { VIDEO = "video", AUDIO = "audio" }

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["LinkSelectedClips"] = function(command)
        local args = command:get_all_parameters()
        local project_id = args.project_id
        assert(project_id and project_id ~= "",
            "LinkSelectedClips: project_id required (auto-inject failed)")

        local timeline_state = require("ui.timeline.timeline_state")
        local selected = timeline_state.get_selected_clips()

        local clips_to_link = {}
        for _, sc in ipairs(selected) do
            if not sc.is_gap then
                local track = timeline_state.get_track_by_id(sc.track_id)
                assert(track, string.format(
                    "LinkSelectedClips: selected clip %s references "
                    .. "unknown track %s",
                    tostring(sc.id), tostring(sc.track_id)))
                local role = TRACK_TYPE_TO_ROLE[track.track_type]
                if role then
                    clips_to_link[#clips_to_link + 1] = {
                        clip_id     = sc.id,
                        role        = role,
                        time_offset = 0,
                    }
                end
            end
        end

        if #clips_to_link < 2 then
            log.event("LinkSelectedClips: need ≥2 selected video/audio "
                .. "clips, got %d — no-op", #clips_to_link)
            return true
        end

        -- command_manager.execute drops the executor's secondary return on
        -- success; surface success/failure only (matches BladeAtPlayhead).
        local command_manager = require("core.command_manager")
        -- No link_group_id: LinkClips mints the group id itself (same as the
        -- "Link Clips" menu path). Passing one here was a dummy to satisfy a
        -- since-removed required-arg in LINK_SPEC.
        local result = command_manager.execute("LinkClips", {
            project_id = project_id,
            clips      = clips_to_link,
        })
        assert(type(result) == "table" and type(result.success) == "boolean",
            string.format("LinkSelectedClips: command_manager.execute(\"LinkClips\") "
                .. "returned malformed result (got %s) — contract violation",
                type(result)))
        if not result.success then
            local msg = result.error_message
            assert(type(msg) == "string" and msg ~= "",
                "LinkSelectedClips: nested LinkClips reported success=false "
                .. "but error_message missing — LinkClips contract violation")
            return false, msg
        end
        return true
    end

    return {
        executor = command_executors["LinkSelectedClips"],
        undoer   = nil,
        spec     = SPEC,
    }
end

return M
