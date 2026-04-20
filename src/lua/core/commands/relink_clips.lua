--- RelinkClips command: clip-level media reconnection with undo
--
-- Responsibilities:
-- - Update clip source_in/source_out and media_id per clip_relink_map
-- - Update media file_path(s) per media_path_changes
-- - Create new media records for segment files
-- - Full undo: restore clip state, media paths, delete new media records
--
-- Non-goals:
-- - Scanning/matching (handled by media_relinker.relink_media_batch)
-- - UI (handled by ShowRelinkDialog)
--
-- Invariants:
-- - Requires clip_relink_map, project_id
-- - Single atomic operation (one undo reverts all)
--
-- @file relink_clips.lua
local M = {}
local log = require("core.logger").for_area("media")

--- Count keys in a map (for tables where #t is meaningless).
local function count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local SPEC = {
    args = {
        clip_relink_map = { required = true, kind = "table" },
        project_id = { required = true },
        -- Optional with a table default: the framework materializes a fresh
        -- empty table per invocation, so executors can iterate unconditionally
        -- without fallback guards.
        media_path_changes = { kind = "table", default = {} },
        new_media_records = { kind = "table", default = {} },
    }
}

function M.register(executors, undoers, db)

    executors["RelinkClips"] = function(command)
        -- SPEC enforces clip_relink_map (required, kind=table) and project_id
        -- (required) via command_schema validation; no manual re-check needed.
        local args = command:get_all_parameters()

        local Clip = require("models.clip")
        local Media = require("models.media")

        local old_clip_state  -- set in Phase 3
        local old_media_paths = {}
        local media_path_changes = args.media_path_changes
        local new_media_records = args.new_media_records
        local media_count = 0

        -- No transaction here — command_manager provides one.
        -- Any assert/error unwinds to command_manager which rolls back.

        -- Wrap the whole executor in a media batch so every mark_dirty()
        -- — from Phase 1 (Media:save on new records), Phase 2
        -- (batch_set_file_paths), and Phase 3 (if any clip-side write
        -- dirties media) — accumulates into a single media_changed
        -- signal at the end. Eliminates the duplicate emit we used to
        -- fire after Phase 3: that handler cascade was responsible for
        -- ~30% of the command's wall time on large batches.
        Media.begin_batch()

        local t_p1 = qt_monotonic_s()

        -- Phase 1: Create new media records (split clones, segment files)
        for _, rec in ipairs(new_media_records) do
            assert(rec.id and rec.path and rec.name,
                "RelinkClips: new_media_record requires id, path, name")
            assert(rec.duration_frames, "RelinkClips: new_media_record requires duration_frames")
            assert(rec.fps_num, "RelinkClips: new_media_record requires fps_num")
            assert(rec.fps_den, "RelinkClips: new_media_record requires fps_den")
            local rec_codec = rec.codec
            local rec_width = rec.width
            local media = Media.create({
                id = rec.id,
                project_id = args.project_id,
                file_path = rec.path,
                name = rec.name,
                duration_frames = rec.duration_frames,
                fps_numerator = rec.fps_num,
                fps_denominator = rec.fps_den,
                audio_sample_rate = rec.audio_sample_rate,
                audio_channels = rec.audio_channels,
                width = rec_width,
                height = rec.height,
                codec = rec_codec,
                is_still = Media.classify_is_still(rec_codec, rec_width, rec.duration_frames),
                metadata = rec.metadata or "{}",
            })
            assert(media:save(), string.format("RelinkClips: failed to save new media %s", rec.id))
            log.event("RelinkClips: created media %s → %s", rec.id, rec.path)
        end

        local t_p1_end = qt_monotonic_s()

        -- Phase 2: Update media paths via batch helper — one SELECT for
        -- old paths (undo state), one prepared UPDATE loop for writes.
        -- mark_dirty accumulates into the outer begin_batch set.
        old_media_paths = Media.batch_set_file_paths(media_path_changes)
        for _ in pairs(media_path_changes) do media_count = media_count + 1 end
        local t_p2_core = qt_monotonic_s()
        local t_p2_end = t_p2_core

        -- Phase 3: Read old clip state, write new state (via model batch methods)
        local t_p3 = qt_monotonic_s()
        old_clip_state = Clip.batch_read_source(args.clip_relink_map)

        local updates = {}
        for clip_id, relink in pairs(args.clip_relink_map) do
            local prev = old_clip_state[clip_id]
            -- new_source_in / new_source_out are nil when the relink is a
            -- pure media_id reassignment (e.g. dedupe salvage path) — the
            -- clip keeps its existing source range in that case.
            updates[clip_id] = {
                media_id = relink.new_media_id or prev.media_id,
                source_in = relink.new_source_in or prev.source_in,
                source_out = relink.new_source_out or prev.source_out,
            }
        end
        Clip.batch_update_source(updates)

        -- Persist undo state
        command:set_parameter("old_clip_state", old_clip_state)
        command:set_parameter("old_media_paths", old_media_paths)

        -- Clip writes don't call mark_dirty on media rows, but any clip
        -- pointed at a different media_id (new split clone, dedupe
        -- salvage sibling) means that media's viewers need to refresh.
        -- Add those ids into the batch accumulator so the single
        -- media_changed emit at end_batch covers them. mid is always
        -- non-nil — batch_read_source asserts media_id is NOT NULL —
        -- so we assert here too rather than silently skipping.
        for clip_id, relink in pairs(args.clip_relink_map) do
            local mid = relink.new_media_id or old_clip_state[clip_id].media_id
            assert(mid, string.format(
                "RelinkClips: clip %s has neither new_media_id nor old media_id",
                tostring(clip_id)))
            Media.mark_dirty(mid)
        end
        local t_p3_end = qt_monotonic_s()

        -- Single media_changed emit — wraps every id touched by Phase 1
        -- (new media creates), Phase 2 (path changes), and Phase 3
        -- (clip-side retargets). Replaces the prior double-emit (once
        -- at Media.end_batch after Phase 2, then again via explicit
        -- Signals.emit after Phase 3), which doubled downstream
        -- listener work.
        Media.end_batch()
        local t_signal_end = qt_monotonic_s()

        log.event("RelinkClips: relinked %d clip(s), %d media path(s)",
            count_keys(args.clip_relink_map), media_count)
        log.detail("RelinkClips timing: p1=%.2fs p2_core=%.2fs p2_end_batch=%.2fs "
            .. "p3=%.2fs signal=%.2fs",
            t_p1_end - t_p1,
            t_p2_core - t_p1_end,
            t_p2_end - t_p2_core,
            t_p3_end - t_p3,
            t_signal_end - t_p3_end)
        return { success = true }
    end

    undoers["RelinkClips"] = function(command)
        local args = command:get_all_parameters()
        assert(args.old_clip_state, "RelinkClips undo: old_clip_state missing")
        assert(type(args.old_media_paths) == "table", "RelinkClips undo: old_media_paths missing")

        local Clip = require("models.clip")
        local Media = require("models.media")

        local old_media_paths = args.old_media_paths

        -- No transaction here — command_manager provides one.
        -- Any assert/error unwinds to command_manager which rolls back.

        -- Same single-signal pattern as the executor: wrap the whole
        -- undo body, let mark_dirty accumulate, emit once at the end.
        Media.begin_batch()

        -- Phase 1: Restore clips via model batch method
        Clip.batch_update_source(args.old_clip_state)

        -- Phase 2: Restore media paths via the same batch helper used
        -- by the executor. Discards the return value (we're restoring,
        -- not capturing forward-undo state).
        Media.batch_set_file_paths(old_media_paths)

        -- Phase 3: Delete new media records (and their clips)
        -- SPEC guarantees args.new_media_records is a table (default = {}).
        for _, rec in ipairs(args.new_media_records) do
            local media = Media.load(rec.id)
            assert(media, string.format("RelinkClips undo: new media %s not found for deletion", rec.id))
            media:delete()
        end

        -- Clip-side retargets don't mark media dirty via SQL alone;
        -- explicitly dirty every restored media_id so its viewers pick
        -- up the change in the single media_changed emit below.
        -- old_state.media_id is always non-nil (batch_read_source
        -- asserts media_id is NOT NULL at capture time), so assert
        -- rather than silently skipping.
        for clip_id, old_state in pairs(args.old_clip_state) do
            assert(old_state.media_id, string.format(
                "RelinkClips undo: clip %s has no media_id in undo state",
                tostring(clip_id)))
            Media.mark_dirty(old_state.media_id)
        end

        Media.end_batch()

        log.event("RelinkClips undo: restored %d clip(s)", count_keys(args.old_clip_state))
        return true
    end

    return {
        ["RelinkClips"] = {
            executor = executors["RelinkClips"],
            undoer = undoers["RelinkClips"],
            spec = SPEC,
        },
    }
end

return M
