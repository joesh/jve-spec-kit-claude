--- ConformSequence command (018 T045 / FR-035 / FR-029 / FR-031 / FR-032).
---
--- Rewrites a single sequence's fps_numerator/fps_denominator plus every
--- dependent row so the resolver produces the same wall-clock content
--- under the new fps. Atomic, undoable, transactional. ONLY legal path
--- to mutate sequences.fps_*; direct UPDATEs blocked by the fps single-writer trigger (FR-035).
---
--- See specs/018-uniform-clip-source/contracts/conform_sequence.md.
---
--- @file conform_sequence.lua

local M = {}

local Sequence = require("models.sequence")
local subframe_math = require("core.subframe_math")
local log = require("core.logger").for_area("commands")

-- Build a per-step rescaler that maps an old-frame integer to the new
-- count under the (new_fps_num, new_fps_den) timebase given the original
-- (old_fps_num, old_fps_den). Uses FR-008 round-half-away-from-zero so
-- this command and the resolver agree on edge cases.
local function make_rescaler(old_num, old_den, new_num, new_den)
    local rhaz = subframe_math.round_half_away_from_zero
    return function(old_frames)
        if old_frames == nil then return nil end
        return rhaz(old_frames * new_num * old_den / (new_den * old_num))
    end
end

function M.execute(args)
    assert(type(args) == "table", "ConformSequence.execute: args required")
    assert(args.project_id and args.project_id ~= "",
        "ConformSequence: project_id required (rule 2.29)")
    assert(args.sequence_id and args.sequence_id ~= "",
        "ConformSequence: sequence_id required (rule 2.29)")
    assert(type(args.fps_numerator) == "number" and args.fps_numerator > 0
        and math.floor(args.fps_numerator) == args.fps_numerator,
        string.format("ConformSequence: fps_numerator must be positive integer; got %s",
            tostring(args.fps_numerator)))
    assert(type(args.fps_denominator) == "number" and args.fps_denominator > 0
        and math.floor(args.fps_denominator) == args.fps_denominator,
        string.format("ConformSequence: fps_denominator must be positive integer; got %s",
            tostring(args.fps_denominator)))

    local kind, old_num, old_den, captured =
        Sequence.collect_conform_captured(args.sequence_id)
    assert(old_num ~= args.fps_numerator or old_den ~= args.fps_denominator,
        string.format(
            "ConformSequence: new fps %d/%d equals current; no-op rejected",
            args.fps_numerator, args.fps_denominator))

    local rescaler = make_rescaler(old_num, old_den,
        args.fps_numerator, args.fps_denominator)
    local post = Sequence.conform_fps(args.sequence_id,
        args.fps_numerator, args.fps_denominator, captured, rescaler)

    log.event("ConformSequence: %s (kind=%s) %d/%d -> %d/%d "
        .. "(mrefs=%d inner_clips=%d outer_clips=%d)",
        args.sequence_id, kind, old_num, old_den,
        args.fps_numerator, args.fps_denominator,
        #captured.mrefs, #captured.inner_clips, #captured.outer_clips)

    return {
        project_id   = args.project_id,
        sequence_id  = args.sequence_id,
        kind         = kind,
        old_num      = old_num,
        old_den      = old_den,
        new_num      = args.fps_numerator,
        new_den      = args.fps_denominator,
        pre_captured = captured,
        post_captured = post,
    }
end

-- Undo replays the captured pre-conform values against the OLD fps. The
-- model helper uses the rescaler to compute the per-row "new" value; for
-- restore, we want literal pre-values, so the rescaler is a pass-through
-- that yields the captured columns straight back.
function M.undo(persisted)
    assert(type(persisted) == "table", "ConformSequence.undo: persisted required")
    assert(persisted.sequence_id and persisted.sequence_id ~= "",
        "ConformSequence.undo: sequence_id missing")
    assert(type(persisted.old_num) == "number" and persisted.old_num > 0,
        "ConformSequence.undo: old_num missing/invalid")
    assert(type(persisted.old_den) == "number" and persisted.old_den > 0,
        "ConformSequence.undo: old_den missing/invalid")
    assert(type(persisted.pre_captured) == "table",
        "ConformSequence.undo: pre_captured missing")

    -- Pass-through rescaler: each rescaler call corresponds to one row in
    -- the captured list, in order. We hand back the pre-value's column.
    -- Because conform_fps invokes the rescaler twice per row (for the two
    -- numeric columns in order: seq_start then dur for mrefs/inner,
    -- src_in then src_out for outer), we replay those two values in turn.
    local cap = persisted.pre_captured
    assert(type(cap.mrefs) == "table" and type(cap.inner_clips) == "table"
        and type(cap.outer_clips) == "table",
        "ConformSequence.undo: pre_captured must carry mrefs/inner_clips/outer_clips tables")
    local replay = {}
    for _, m in ipairs(cap.mrefs)       do replay[#replay+1] = m.seq_start; replay[#replay+1] = m.dur end
    for _, c in ipairs(cap.inner_clips) do replay[#replay+1] = c.seq_start; replay[#replay+1] = c.dur end
    for _, c in ipairs(cap.outer_clips) do replay[#replay+1] = c.src_in;    replay[#replay+1] = c.src_out end
    local idx = 0
    local function restore_rescaler(_old_unused)
        idx = idx + 1
        local v = replay[idx]
        assert(v ~= nil, "ConformSequence.undo: replay queue exhausted mid-iter")
        return v
    end

    Sequence.conform_fps(persisted.sequence_id,
        persisted.old_num, persisted.old_den, cap, restore_rescaler)
end

local SPEC = {
    -- 018: conform is a sequence-METADATA rewrite (fps change cascades to
    -- frame columns), not a per-clip timeline mutation. UI refresh fires
    -- via the standard whole-sequence reload after this command runs, not
    -- per-clip mutation entries. command_manager's mutation-tracking
    -- assertion is therefore not applicable.
    mutates_clips = false,
    args = {
        project_id      = { required = true },
        sequence_id     = { required = true },
        fps_numerator   = { required = true, kind = "number" },
        fps_denominator = { required = true, kind = "number" },
    },
    persisted = {
        kind          = { kind = "string" },
        old_num       = { kind = "number" },
        old_den       = { kind = "number" },
        new_num       = { kind = "number" },
        new_den       = { kind = "number" },
        pre_captured  = { kind = "table" },
        post_captured = { kind = "table" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["ConformSequence"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("ConformSequence: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("kind",          cap.kind)
        command:set_parameter("old_num",       cap.old_num)
        command:set_parameter("old_den",       cap.old_den)
        command:set_parameter("new_num",       cap.new_num)
        command:set_parameter("new_den",       cap.new_den)
        command:set_parameter("pre_captured",  cap.pre_captured)
        command:set_parameter("post_captured", cap.post_captured)
        return true
    end

    command_undoers["ConformSequence"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id  = args.sequence_id,
            old_num      = args.old_num,
            old_den      = args.old_den,
            pre_captured = args.pre_captured,
        })
        return true
    end

    return {
        executor = command_executors["ConformSequence"],
        undoer   = command_undoers["ConformSequence"],
        spec     = SPEC,
    }
end

return M
