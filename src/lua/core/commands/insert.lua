--- Insert command (Feature 013, rewrite per T040).
--
-- Places a master (or nested) sequence as a clip reference onto a non-master
-- edit sequence's track. Writes 1 or 2 V9 clips rows (V and/or A — not
-- per-channel; channel overrides live in media_refs_channel_state and
-- clip_channel_override, resolved at playback). If 2 rows land, they share
-- a clip_links.link_group_id. fps_mismatch_policy is frozen on each row at
-- Insert time from the explicit arg / owner sequence override / project
-- default chain (data-model.md §Decisions — structural at Insert).
--
-- Collision strategy: ripple. Target tracks' clips at or past the insertion
-- frame shift forward by the new clip's owner-timebase duration. Other
-- tracks are untouched (differs from Overwrite which occludes).
--
-- Shared scaffolding lives in _place_shared.lua. This module owns only the
-- ripple-vs-occlude decision and its undo capture.
--
-- SQL isolation: all DB access goes through models.
--
-- @file insert.lua

local M = {}

local Clip          = require("models.clip")
local Sequence      = require("models.sequence")
local Track         = require("models.track")
local place_shared  = require("core.commands._place_shared")
local log           = require("core.logger").for_area("commands")

-- M.execute — pure-logic entry point. Args and return shape documented below.
function M.execute(args)
    -- sequence_start_frame is optional at the SPEC layer because the
    -- editor's user-mode Insert is "insert at playhead." When omitted,
    -- consume the framework-injected playhead. (command_manager.inject_context
    -- auto-injects `playhead` for any command that declares the arg.)
    if args.sequence_start_frame == nil then
        assert(type(args.playhead) == "number", string.format(
            "Insert: sequence_start_frame omitted and no playhead "
            .. "available for sequence %s", tostring(args.sequence_id)))
        args.sequence_start_frame = args.playhead
    end

    -- 015 F2: ensure identity patches exist for every source track in the
    -- nested sequence. Patches are the sole routing mechanism; this is
    -- the API-layer guarantee that pre-patch source→record identity
    -- behavior still works without explicit user setup.
    require("models.patch").ensure_identity_for_source(
        args.sequence_id, args.source_sequence_id)

    local plan = place_shared.plan_placement(args)
    -- Carry preset_ids through redo so created_clip_ids stays stable.
    plan.preset_ids = args.created_clip_ids

    -- A clip strictly straddling the insertion frame is split into a left
    -- half ending at start_frame and a right half starting at start_frame
    -- BEFORE the ripple step. This matches V8 / Resolve / Premiere / FCP
    -- UX: an Insert at mid-clip cuts that clip and shoves the right half
    -- (along with everything downstream) forward by the inserted duration.
    -- Without this step, ripple_track_forward (which only moves clips
    -- whose start >= insertion frame) would leave the straddler untouched
    -- and the new clip's INSERT would collide with it on the
    -- video-overlap trigger.
    -- Every target track (VIDEO + each audio destination) must split + ripple
    -- before the new clip rows land. Walker is in place_shared so Overwrite
    -- shares it.
    local target_track_ids = place_shared.iter_target_track_ids(plan)

    local split_captures = {}
    for _, track_id in ipairs(target_track_ids) do
        local cap = place_shared.split_track_at_insertion(
            track_id, plan.owner, plan.start_frame)
        if cap and (#cap.trimmed > 0 or #cap.split_new_ids > 0) then
            split_captures[track_id] = cap
        end
    end

    -- Ripple target tracks BEFORE inserting so the new clip doesn't collide.
    -- The right halves created by split_track_at_insertion (sequence_start
    -- == plan.start_frame) get picked up here and shifted along with all
    -- downstream clips.
    local rippled = {}
    for _, track_id in ipairs(target_track_ids) do
        local ids = Clip.ripple_track_forward(
            track_id, plan.start_frame, plan.owner_duration)
        if #ids > 0 then
            rippled[track_id] = {
                shift = plan.owner_duration,
                from_frame = plan.start_frame,
                clip_ids = ids,
            }
        end
    end

    local written = place_shared.write_clips(plan)

    log.event("Insert: owner=%s nested=%s policy=%s duration=%d clips=%d",
        plan.owner.id, plan.nested.id, plan.policy,
        plan.owner_duration, #written.created_clip_ids)

    return {
        created_clip_ids    = written.created_clip_ids,
        video_clip_id       = written.video_clip_id,
        audio_clip_id       = written.audio_clip_id,
        link_group_id       = written.link_group_id,
        duration_frames     = plan.owner_duration,
        fps_mismatch_policy = plan.policy,
        rippled             = rippled,
        split_captures      = split_captures,
        start_frame         = plan.start_frame,
    }
end

-- ---------------------------------------------------------------------------
-- M.register — command_manager wiring.
-- ---------------------------------------------------------------------------

local SPEC = {
    args = {
        sequence_id           = { required = true,  kind = "string" },
        source_sequence_id    = { required = true,  kind = "string" },
        -- playhead is framework-injected (command_manager.inject_context).
        -- Insert only needs it as the default for sequence_start_frame;
        -- it's non-required so script callers building synthetic Insert
        -- calls can pin sequence_start_frame explicitly and skip playhead.
        playhead              = { kind = "number" },
        -- sequence_start_frame omitted ⇒ defaults to args.playhead.
        -- No silent default-to-0 (rule 2.13).
        sequence_start_frame  = { kind = "number" },
        target_video_track_id = { kind = "string" },
        target_audio_track_id = { kind = "string" },
        fps_mismatch_policy   = { kind = "string" },
        clip_name             = { kind = "string" },
        audio_drop_mode       = { kind = "string", one_of = { "composite", "expanded" } },
        advance_playhead      = { kind = "boolean" },
    },
    persisted = {
        created_clip_ids       = { kind = "table" },
        created_link_group_id  = { kind = "string" },
        rippled_capture        = { kind = "table" },
        split_capture          = { kind = "table" },
        duration_frames        = { kind = "number" },
        fps_mismatch_policy    = { kind = "string" },
        prior_playhead         = { kind = "number" },
        executed_mutations     = { kind = "table" },
        auto_track_ids         = { kind = "table" },
    },
}

-- Spec F2: ensure the record sequence has audio tracks 1..N where N is
-- the highest record_track_index referenced by an ENABLED patch row.
-- Patches are the sole routing mechanism: source channels with no patch
-- row contribute nothing (they don't participate in the edit). Disabled
-- patches likewise contribute nothing.
local function auto_create_record_audio_tracks(args)
    assert(args.source_sequence_id and args.source_sequence_id ~= "",
        "Insert.auto_create_record_audio_tracks: source_sequence_id required "
        .. "(SPEC declares it required=true; reaching this helper without it "
        .. "is a programming error in the executor wiring)")

    local Patch = require("models.patch")
    local rec_audio = Track.find_by_sequence(args.sequence_id, "AUDIO")

    local max_rec_idx = 0
    for _, p in ipairs(Patch.find_by_sequence(args.sequence_id)) do
        if p.track_type == "AUDIO"
           and p.enabled == 1  -- normalized to INTEGER by Patch.save
           and p.record_track_index > max_rec_idx then
            max_rec_idx = p.record_track_index
        end
    end

    -- Walk only the indices that don't already have a track. Using
    -- rec_count+1..max_rec_idx silently misroutes whenever existing
    -- record tracks are non-contiguous (e.g. user deleted A2 leaving
    -- A1+A3): Track.determine_next_index would assign MAX+1 ignoring
    -- the patch's record_track_index. Pin track_index explicitly.
    local existing_by_idx = {}
    for _, t in ipairs(rec_audio) do existing_by_idx[t.track_index] = true end
    local created_ids = {}
    for i = 1, max_rec_idx do
        if not existing_by_idx[i] then
            local t = Track.create_audio(
                string.format("A%d", i), args.sequence_id,
                { sync_mode = "ripple", index = i })
            assert(t:save(), string.format(
                "Insert: failed to save auto-created audio track A%d "
                .. "for sequence %s", i, tostring(args.sequence_id)))
            created_ids[#created_ids + 1] = t.id
            log.event("Insert: auto-created audio track A%d id=%s "
                .. "(max enabled patch rec_idx=%d)", i, t.id, max_rec_idx)
        end
    end
    return created_ids
end

-- Flat executed_mutations list: one entry per row touched. Stable contract
-- consumed by tests/test_insert_split_behavior, batch-ripple undo, and
-- move-clip-to-track replay paths. Entries:
--   {type="insert", clip_id=...}  — new clip (created or split right-half)
--   {type="update", clip_id=...}  — bounds changed (split left-half, ripple)
local function build_executed_mutations(result)
    local muts = {}
    for _, cap in pairs(result.split_captures) do
        for _, right_id in ipairs(cap.split_new_ids) do
            muts[#muts + 1] = { type = "insert", clip_id = right_id }
        end
        for _, tr in ipairs(cap.trimmed) do
            muts[#muts + 1] = { type = "update", clip_id = tr.id }
        end
    end
    for _, cid in ipairs(result.created_clip_ids) do
        muts[#muts + 1] = { type = "insert", clip_id = cid }
    end
    for _, rip in pairs(result.rippled) do
        for _, cid in ipairs(rip.clip_ids) do
            muts[#muts + 1] = { type = "update", clip_id = cid }
        end
    end
    return muts
end

local function build_insert_mutation_entry(clip_id)
    -- Clip.load (not load_v13_row) so the in-memory mutation carries the
    -- joined frame_rate from the nested sequence row. Consumers that
    -- read clip.frame_rate (batch_ripple_edit's fetch_base_clip etc.)
    -- require it.
    local clip = Clip.load(clip_id)
    assert(clip, "Insert: could not re-read inserted clip " .. tostring(clip_id))
    return {
        id                    = clip.id,
        owner_sequence_id     = clip.owner_sequence_id,
        track_sequence_id     = clip.owner_sequence_id,
        track_id              = clip.track_id,
        sequence_id    = clip.sequence_id,
        start_value           = clip.sequence_start,
        sequence_start        = clip.sequence_start,
        duration_value        = clip.duration,
        duration              = clip.duration,
        source_in             = clip.source_in,
        source_out            = clip.source_out,
        master_layer_track_id = clip.master_layer_track_id,
        fps_mismatch_policy   = clip.fps_mismatch_policy,
        frame_rate            = clip.frame_rate,
        name                  = clip.name,
        enabled               = clip.enabled,
        volume                = clip.volume,
        playhead_frame        = clip.playhead_frame,
    }
end

-- Build the post-execute __timeline_mutations bucket. Mirrors the natural
-- three-phase domain flow: split → bulk_shift → place into cleared space.
--   updates    — split's left-half trim
--   inserts    — split's right-half at PRE-shift position (so bulk_shift
--                catches it the same way it catches pre-existing
--                downstream clips)
--   bulk_shifts — ripple by inserted duration, predicate from cut frame
--   placements — the new clips at their final post-shift position
-- See clip_state.apply_mutations for the consumer side.
local function build_executor_mutation_bucket(args, result)
    local bucket = {
        sequence_id = args.sequence_id,
        inserts = {}, updates = {}, deletes = {},
        bulk_shifts = {}, placements = {},
    }
    for track_id, cap in pairs(result.split_captures) do
        local track_shift = result.rippled[track_id]
            and result.rippled[track_id].shift or 0
        for _, right_id in ipairs(cap.split_new_ids) do
            local entry = build_insert_mutation_entry(right_id)
            -- DB row is at POST-shift position (ripple ran after split).
            -- Emit at PRE-shift so the bucket's bulk_shift moves it to the
            -- final position in-memory, mirroring the DB sequence.
            entry.start_value    = entry.start_value    - track_shift
            entry.sequence_start = entry.sequence_start - track_shift
            bucket.inserts[#bucket.inserts + 1] = entry
        end
        for _, tr in ipairs(cap.trimmed) do
            local row = Clip.load_v13_row(tr.id)
            assert(row, "Insert: could not re-read trimmed left-half "
                .. tostring(tr.id))
            bucket.updates[#bucket.updates + 1] = {
                clip_id          = row.id,
                id               = row.id,
                track_id         = row.track_id,
                start_value      = row.sequence_start_frame,
                duration_value   = row.duration_frames,
                source_in_value  = row.source_in_frame,
                source_out_value = row.source_out_frame,
            }
        end
    end
    for track_id, rip in pairs(result.rippled) do
        bucket.bulk_shifts[#bucket.bulk_shifts + 1] = {
            track_id     = track_id,
            shift_frames = rip.shift,
            start_frame  = rip.from_frame,
        }
    end
    -- New clips go into placements — applied AFTER bulk_shift, so they
    -- land at the final post-ripple position without being double-shifted.
    for _, cid in ipairs(result.created_clip_ids) do
        bucket.placements[#bucket.placements + 1] = build_insert_mutation_entry(cid)
    end
    return bucket
end

-- Build the inverse __timeline_mutations bucket for Insert's undoer:
-- created clips become deletes, ripple shifts become inverse bulk_shifts,
-- split right-halves become deletes, split left-halves' restored bounds
-- become updates. Mirror order in the consumer (updates → inserts →
-- bulk_shifts → deletes per clip_state.apply_mutations).
local function build_undo_mutation_bucket(args, created_ids, rippled, splits)
    local bucket = {
        sequence_id = args.sequence_id,
        inserts = {}, updates = {}, deletes = {}, bulk_shifts = {},
    }
    for _, cid in ipairs(created_ids) do
        bucket.deletes[#bucket.deletes + 1] = { clip_id = cid }
    end
    for track_id, rip in pairs(rippled) do
        if rip.shift and rip.shift ~= 0 then
            bucket.bulk_shifts[#bucket.bulk_shifts + 1] = {
                track_id     = track_id,
                shift_frames = -rip.shift,
                start_frame  = (rip.from_frame or 0) + rip.shift,
            }
        end
    end
    for _, cap in pairs(splits) do
        for _, right_id in ipairs(cap.split_new_ids) do
            bucket.deletes[#bucket.deletes + 1] = { clip_id = right_id }
        end
        for _, tr in ipairs(cap.trimmed) do
            bucket.updates[#bucket.updates + 1] = {
                clip_id          = tr.id,
                id               = tr.id,
                start_value      = tr.prior.sequence_start_frame,
                duration_value   = tr.prior.duration_frames,
                source_in_value  = tr.prior.source_in_frame,
                source_out_value = tr.prior.source_out_frame,
            }
        end
    end
    return bucket
end

-- Reverse the mid-clip-Insert splits: drop right-halves first (frees the
-- track range), then restore each left-half's pre-split bounds. Order
-- matches split_clip.lua's undoer so the video-overlap trigger doesn't
-- fire on the intermediate state.
local function reverse_split_captures(splits)
    for _, cap in pairs(splits) do
        if cap.split_new_ids and #cap.split_new_ids > 0 then
            Clip.delete_by_ids(cap.split_new_ids)
        end
    end
    for _, cap in pairs(splits) do
        for _, tr in ipairs(cap.trimmed) do
            Clip.update_bounds(tr.id,
                tr.prior.sequence_start_frame, tr.prior.duration_frames,
                tr.prior.source_in_frame,      tr.prior.source_out_frame)
        end
    end
end

-- advance_playhead side effect: after a successful placement, advance
-- the sequence's playhead by the inserted duration and persist. Captures
-- the prior playhead onto the command for undo. No-op when advance is off.
local function advance_owner_playhead(args, command, result, signals)
    if not args.advance_playhead then return end
    local owner = assert(Sequence.load(args.sequence_id),
        "Insert: sequence " .. tostring(args.sequence_id) .. " not found post-execute")
    command:set_parameter("prior_playhead", owner.playhead_position)
    local new_playhead = result.start_frame + result.duration_frames
    owner:set_playhead(new_playhead)
    assert(owner:save(), "Insert: sequence save failed after advance_playhead")
    signals.emit("playhead_changed", args.sequence_id, new_playhead)
end

local function restore_owner_playhead(args, signals)
    if not (args.advance_playhead and type(args.prior_playhead) == "number") then
        return
    end
    local owner = assert(Sequence.load(args.sequence_id),
        "Insert.undo: sequence " .. tostring(args.sequence_id) .. " not found")
    owner:set_playhead(args.prior_playhead)
    assert(owner:save(), "Insert.undo: sequence save failed")
    signals.emit("playhead_changed", args.sequence_id, args.prior_playhead)
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Insert"] = function(command)
        local args = command:get_all_parameters()

        -- Validate the source sequence exists before any content checks.
        if not Sequence.find(args.source_sequence_id) then
            set_last_error(string.format(
                "Insert: source_sequence_id '%s' not found",
                tostring(args.source_sequence_id)))
            return false
        end

        -- T042: auto-create any missing record audio tracks (within this undo
        -- entry so Cmd-Z removes them together with the inserted clip).
        local auto_ids = auto_create_record_audio_tracks(args)
        command:set_parameter("auto_track_ids", auto_ids)

        -- If the source sequence has no clips, track creation was the only
        -- goal (T042 path). Persist empty clip-insertion state and return.
        local src_mediums = Sequence.contained_mediums(args.source_sequence_id)
        if not next(src_mediums) then
            command:set_parameter("created_clip_ids",      {})
            command:set_parameter("created_link_group_id", "")
            command:set_parameter("rippled_capture",       {})
            command:set_parameter("split_capture",         {})
            command:set_parameter("duration_frames",       0)
            command:set_parameter("fps_mismatch_policy",   "")
            command:set_parameter("executed_mutations",    {})
            command:set_parameter("__timeline_mutations",  {
                sequence_id = args.sequence_id,
                inserts = {}, updates = {}, deletes = {},
                bulk_shifts = {}, placements = {},
            })
            return true
        end

        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Insert: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        local result = result_or_err

        command:set_parameter("created_clip_ids",      result.created_clip_ids)
        command:set_parameter("created_link_group_id", result.link_group_id or "")
        command:set_parameter("rippled_capture",       result.rippled)
        command:set_parameter("split_capture",         result.split_captures)
        command:set_parameter("duration_frames",       result.duration_frames)
        command:set_parameter("fps_mismatch_policy",   result.fps_mismatch_policy)
        command:set_parameter("executed_mutations",    build_executed_mutations(result))
        command:set_parameter("__timeline_mutations",
            build_executor_mutation_bucket(args, result))

        local Signals = require("core.signals")
        advance_owner_playhead(args, command, result, Signals)
        return true
    end

    command_undoers["Insert"] = function(command)
        local args = command:get_all_parameters()
        -- Executor sets all three unconditionally (execute always returns
        -- non-nil arrays/maps for these). No fallbacks.
        local created_ids = args.created_clip_ids
        local rippled     = args.rippled_capture
        local splits      = args.split_capture
        -- clip_links cascade on clip delete; link_group_id is preserved on
        -- the command for redo reinstatement.

        Clip.delete_by_ids(created_ids)
        for _, rip in pairs(rippled) do
            if rip.clip_ids and #rip.clip_ids > 0 then
                Clip.shift_many_by(rip.clip_ids, -rip.shift)
            end
        end
        reverse_split_captures(splits)

        -- T042: remove auto-created record tracks (reverse order of creation).
        local auto_ids = args.auto_track_ids
        assert(type(auto_ids) == "table",
            "Insert.undo: auto_track_ids not persisted on command")
        for i = #auto_ids, 1, -1 do
            Track.delete(auto_ids[i])
        end

        local undo_bucket = build_undo_mutation_bucket(args, created_ids, rippled, splits)
        command:set_parameter("__timeline_mutations", undo_bucket)
        -- When the original Insert had no clips (T042 track-only path), the undo
        -- bucket is empty — no clip deletions or shifts.  Suppress the run_undoer
        -- "no __timeline_mutations" error; the undo DID do real work (Track.delete).
        if #created_ids == 0 then
            command:set_parameter("__no_timeline_mutations_expected", true)
        end

        local Signals = require("core.signals")
        restore_owner_playhead(args, Signals)
        return true
    end

    return {
        executor = command_executors["Insert"],
        undoer   = command_undoers["Insert"],
        spec     = SPEC,
    }
end

return M
