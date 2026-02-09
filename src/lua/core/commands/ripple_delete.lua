--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~221 LOC
-- Volatility: unknown
--
-- @file ripple_delete.lua
local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")


local SPEC = {
    args = {
        dry_run = { kind = "boolean" },
        fps_denominator = { kind = "number" },  -- Optional: used for Rational hydration
        fps_numerator = { kind = "number" },  -- Optional: used for Rational hydration
        gap_duration = { required = true },
        gap_start = { required = true },
        project_id = { required = true },
        ripple_gap_duration = {},  -- Set by executor for undo
        ripple_gap_start = {},  -- Set by executor for undo
        ripple_moved_clips = {},  -- Set by executor
        ripple_sequence_id = {},
        ripple_track_id = {},  -- Set by executor for undo
        sequence_id = { required = true },
        track_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["RippleDelete"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing RippleDelete command")
        end

        local track_id = args.track_id
        local gap_start = args.gap_start
        local gap_duration = args.gap_duration
        local sequence_id = args.sequence_id

        -- Validate integer inputs
        assert(type(gap_start) == "number", "RippleDelete: gap_start must be integer")
        assert(type(gap_duration) == "number" and gap_duration > 0, "RippleDelete: gap_duration must be positive integer")

        local gap_end = gap_start + gap_duration

        -- Ensure global gap is clear (using integer frames)
        local function ensure_global_gap_is_clear()
            -- We need to check if any clip overlaps the gap interval.
            -- Use track -> sequence join to avoid relying on owner_sequence_id being populated.
            local gap_query = db:prepare([[
                SELECT c.id, c.track_id, c.timeline_start_frame, c.duration_frames
                FROM clips c
                JOIN tracks t ON c.track_id = t.id
                WHERE t.sequence_id = ?
            ]])

            if not gap_query then
                set_last_error("RippleDelete: Failed to prepare gap validation query")
                return false
            end
            gap_query:bind_value(1, sequence_id)

            local blocking_clips = {}
            if gap_query:exec() then
                while gap_query:next() do
                    local c_start = gap_query:value(2)
                    local c_dur = gap_query:value(3)
                    local c_end = c_start + c_dur

                    -- Check overlap: NOT (end <= gap_start OR start >= gap_end)
                    -- Equivalent to: end > gap_start AND start < gap_end
                    if c_end > gap_start and c_start < gap_end then
                        table.insert(blocking_clips, {
                            clip_id = gap_query:value(0),
                            track_id = gap_query:value(1),
                            start = c_start,
                            end_time = c_end
                        })
                    end
                end
            end
            gap_query:finalize()

            if #blocking_clips > 0 then
                local messages = {}
                for index, info in ipairs(blocking_clips) do
                    messages[index] = string.format(
                        "clip %s on track %s (%d–%d)",
                        tostring(info.clip_id),
                        tostring(info.track_id),
                        info.start,
                        info.end_time
                    )
                end
                print("WARNING: RippleDelete blocked because the gap is not clear across all tracks: " .. table.concat(messages, "; "))
                return false
            end

            return true
        end

        if not ensure_global_gap_is_clear() then
            return false
        end

        -- Identify clips to move (start >= gap_end)
        local moved_clips = {}
        local query = db:prepare([[
            SELECT c.id, c.timeline_start_frame, c.track_id
            FROM clips c
            JOIN tracks t ON c.track_id = t.id
            WHERE t.sequence_id = ?
        ]])

        if not query then
            set_last_error("RippleDelete: Failed to prepare clip query")
            return false
        end
        query:bind_value(1, sequence_id)

        local clip_ids = {}
        if query:exec() then
            while query:next() do
                local c_start = query:value(1)

                if c_start >= gap_end then
                    table.insert(clip_ids, {
                        id = query:value(0),
                        start = c_start,
                        track_id = query:value(2)
                    })
                end
            end
        end
        query:finalize()

        if args.dry_run then
            return true, {
                track_id = track_id,
                gap_start = gap_start,
                gap_duration = gap_duration,
                clip_count = #clip_ids
            }
        end

        for _, info in ipairs(clip_ids) do
            local clip = Clip.load(info.id)
            if not clip then
                print(string.format("WARNING: RippleDelete: Clip %s not found", tostring(info.id)))
                return false
            end

            local original_start = clip.timeline_start

            -- Move clip: new_start = current_start - gap_duration
            local new_start = clip.timeline_start - gap_duration

            -- Clamp to 0 if something went wrong, though validation above should prevent this
            if new_start < 0 then
                new_start = 0
            end

            clip.timeline_start = new_start

            local saved = clip:save({skip_occlusion = true})
            if not saved then
                print(string.format("ERROR: RippleDelete: Failed to save clip %s", tostring(info.id)))
                return false
            end

            local update_payload = command_helper.clip_update_payload(clip, sequence_id)
            if update_payload then
                command_helper.add_update_mutation(command, update_payload.track_sequence_id, update_payload)
            end

            table.insert(moved_clips, {
                clip_id = info.id,
                original_start = original_start,  -- integer
                track_id = info.track_id,
            })
        end

        command:set_parameters({
            ["ripple_track_id"] = track_id,
            ["ripple_gap_start"] = gap_start,
            ["ripple_sequence_id"] = sequence_id,
            ["ripple_gap_duration"] = gap_duration,
            ["ripple_moved_clips"] = moved_clips,
        })
        -- Clear post-selection so redo doesn't leave stray clip selection (we removed the gap).
        command.selected_clip_ids = "[]"
        command.selected_edge_infos = "[]"
        command.selected_gap_infos = "[]"

        print(string.format("✅ Ripple deleted gap on track %s (moved %d clip(s) across sequence %s)", tostring(track_id), #moved_clips, tostring(sequence_id)))
        return true
    end

    command_undoers["RippleDelete"] = function(command)
        local args = command:get_all_parameters()


        
        if not args.ripple_moved_clips or #args.ripple_moved_clips == 0 then
            return true
        end

        -- Restore from rightmost to leftmost to avoid transient overlaps while moving clips back.
        table.sort(args.ripple_moved_clips, function(a, b)
            return (a.original_start or 0) > (b.original_start or 0)
        end)

        for _, info in ipairs(args.ripple_moved_clips) do
            local clip = Clip.load(info.clip_id)
            if clip then
                clip.timeline_start = info.original_start

                local saved = clip:save({skip_occlusion = true})
                if not saved then
                    print(string.format("WARNING: RippleDelete undo: Failed to restore clip %s", tostring(info.clip_id)))
                else
                    local update_payload = command_helper.clip_update_payload(clip, args.ripple_sequence_id)
                    if update_payload then
                        command_helper.add_update_mutation(command, update_payload.track_sequence_id, update_payload)
                    end
                end
            end
        end

        print("✅ Undo RippleDelete: Restored clip positions")
        return true
    end
    
    command_executors["UndoRippleDelete"] = command_undoers["RippleDelete"]

    return {
        executor = command_executors["RippleDelete"],
        undoer = command_undoers["RippleDelete"],
        spec = SPEC,
    }
end

return M