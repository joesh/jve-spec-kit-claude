local ClipMutator = {}
local uuid = require("uuid")
local log = require("core.logger").for_area("commands")
local frame_utils = require("core.frame_utils")
local krono_ok, krono = pcall(require, "core.krono")

--- Look up sequence fps from a track_id via DB join.
-- Returns fps_numerator, fps_denominator or nil, nil.
local function lookup_seq_fps_for_track(db, track_id)
    local stmt = db:prepare(
        "SELECT s.fps_numerator, s.fps_denominator FROM tracks t JOIN sequences s ON t.sequence_id = s.id WHERE t.id = ?")
    if not stmt then return nil, nil end
    stmt:bind_value(1, track_id)
    local num, den
    if stmt:exec() and stmt:next() then
        num = stmt:value(0)
        den = stmt:value(1)
    end
    stmt:finalize()
    return num, den
end

--- Extract seq fps from a clip row, using the DB-queried rate when
--- the row doesn't carry it (e.g., clips from pending caches).
-- Asserts if neither source has valid fps.
local function resolve_seq_fps(row, db_seq_fps_num, db_seq_fps_den)
    local sn = row.seq_fps_numerator or db_seq_fps_num
    local sd = row.seq_fps_denominator or db_seq_fps_den
    assert(sn and sn > 0, string.format(
        "clip_mutator: missing seq_fps for clip %s", tostring(row.id)))
    return sn, sd
end

    local function clone_state(row)
        return {
            id = row.id,
            project_id = row.project_id,
            track_type = row.track_type,
            name = row.name,
            track_id = row.track_id,
            sequence_id = row.sequence_id,
            master_layer_track_id = row.master_layer_track_id,
            master_audio_track_id = row.master_audio_track_id,
            fps_mismatch_policy = assert(row.fps_mismatch_policy,
                "clip_mutator: clip row missing fps_mismatch_policy "
                .. "(NOT NULL in schema; rule 2.13 — no silent fallback)"),
            owner_sequence_id = row.owner_sequence_id,
            created_at = row.created_at,
            modified_at = row.modified_at,
            timeline_start = row.timeline_start,
            duration = row.duration,
            source_in = row.source_in,
            source_out = row.source_out,
            frame_rate = row.frame_rate,
            enabled = row.enabled,
            volume = row.volume,
        }
    end

-- Extract frames from value (all coords are now integers; this validates and returns)
local function get_frames(val)
    if val == nil then return nil end
    assert(type(val) == "number", "clip_mutator.get_frames: expected integer, got " .. type(val))
    return val
end

-- Assert fps metadata exists (for validation only)
local function assert_fps(num, den, label)
    assert(num and num > 0, "clip_mutator: missing " .. (label or "fps") .. " numerator")
    assert(den and den > 0, "clip_mutator: missing " .. (label or "fps") .. " denominator")
end

-- Helper to get fps metadata from row. Single-shape: row.frame_rate is mandatory.
local function get_row_fps(row)
    assert(row and row.frame_rate,
        string.format("clip_mutator.get_row_fps: clip %s missing frame_rate table",
            tostring(row and row.id)))
    local num = row.frame_rate.fps_numerator
    local den = row.frame_rate.fps_denominator
    assert(type(num) == "number" and num > 0,
        string.format("clip_mutator.get_row_fps: clip %s fps_numerator must be positive, got %s",
            tostring(row.id), tostring(num)))
    assert(type(den) == "number" and den > 0,
        string.format("clip_mutator.get_row_fps: clip %s fps_denominator must be positive, got %s",
            tostring(row.id), tostring(den)))
    return num, den
end

-- Assert value is integer frames (fail-fast, no backward compat)
local function ensure_integer(value, label)
    if type(value) ~= "number" then
        error("clip_mutator: " .. tostring(label or "value") .. " must be integer (got " .. type(value) .. ")", 3)
    end
    return value
end

local function require_source_out(row, context)
    assert(row, "clip_mutator: missing row (" .. tostring(context or "unknown") .. ")")
    local source_out = row.source_out
    assert(type(source_out) == "number", "clip_mutator: source_out must be integer (" .. tostring(context or "unknown") .. ")")
    return source_out
end

local function get_source_in(row)
    local source_in = row.source_in
    assert(type(source_in) == "number", "clip_mutator: source_in must be integer")
    return source_in
end

local function plan_update(row, original)
    return {
        type = "update",
        clip_id = row.id,
        track_id = row.track_id,
        timeline_start_frame = get_frames(row.timeline_start),
        duration_frames = get_frames(row.duration),
        source_in_frame = get_frames(row.source_in),
        source_out_frame = get_frames(row.source_out),
        enabled = row.enabled and 1 or 0,
        previous = original
    }
end

local function plan_delete(row)
    return {
        type = "delete",
        clip_id = row.id,
        previous = row
    }
end

local function plan_insert(row)
    -- Validate frame_rate present even though plan_insert doesn't itself
    -- need fps for the SQL (no fps columns on the clips table) — keeps the
    -- single-shape contract enforced at every entry point.
    get_row_fps(row)
    assert(row.timeline_start, "clip_mutator: insert mutation missing timeline_start")
    assert(row.duration, "clip_mutator: insert mutation missing duration")
    assert(row.source_in, "clip_mutator: insert mutation missing source_in")
    assert(row.source_out, "clip_mutator: insert mutation missing source_out")
    -- V13: sequence_id replaces master_clip_id; clip_kind/media_id/
    -- offline are gone from clips.
    local nested_id = row.sequence_id
    assert(nested_id and nested_id ~= "",
        "clip_mutator.plan_insert: missing sequence_id for clip " .. tostring(row.id))
    return {
        type = "insert",
        clip_id = row.id,
        project_id = row.project_id,
        name = row.name or "",
        track_id = row.track_id,
        sequence_id = nested_id,
        master_layer_track_id = row.master_layer_track_id,
        master_audio_track_id = row.master_audio_track_id,
        fps_mismatch_policy = assert(row.fps_mismatch_policy,
            "clip_mutator: insert mutation missing fps_mismatch_policy "
            .. "for clip " .. tostring(row.id)),
        owner_sequence_id = row.owner_sequence_id,
        timeline_start_frame = get_frames(row.timeline_start),
        duration_frames = get_frames(row.duration),
        source_in_frame = get_frames(row.source_in),
        source_out_frame = get_frames(row.source_out),
        enabled = row.enabled and 1 or 0,
        created_at = assert(row.created_at, "clip_mutator: insert mutation missing created_at for clip " .. tostring(row.id)),
        modified_at = assert(row.modified_at, "clip_mutator: insert mutation missing modified_at for clip " .. tostring(row.id)),
        -- Per-clip metadata. volume and playhead_frame are NOT NULL in the
        -- schema; for a brand-new clip with no prior state, the semantic
        -- neutrals (full volume, head-of-clip playhead) ARE the values, not
        -- a fallback. mark_in/out are nullable (no marks set yet).
        volume = row.volume or 1.0,
        mark_in_frame = row.mark_in,
        mark_out_frame = row.mark_out,
        playhead_frame = row.playhead_frame or 0,
    }
end

-- Resolve occlusions for a clip about to occupy [timeline_start, end_time).
-- Params:
--   track_id, timeline_start, duration
--   exclude_clip_id: clip id to ignore while checking overlaps (e.g., the clip being updated)
local function load_track_clips(db, track_id)
    -- V13 SELECT: same column set produced by database.load_clips, plus
    -- fields legacy callers in clip_mutator expect. The media_refs JOIN is
    -- constrained to media_refs whose own track_type matches the clip's
    -- owner-track type — without this, A/V masters multiply each clip by
    -- the number of media_refs (V + A) and downstream consumers see
    -- duplicates. GROUP BY collapses to one row per clip.
    local stmt = db:prepare([[
        SELECT c.id, c.project_id, c.name, c.track_id,
               c.owner_sequence_id, c.sequence_id,
               c.timeline_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.volume, c.created_at, c.modified_at,
               t.track_type,
               owner_seq.fps_numerator, owner_seq.fps_denominator,
               nested_seq.kind, nested_seq.fps_numerator, nested_seq.fps_denominator,
               mr.media_id
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences owner_seq ON c.owner_sequence_id = owner_seq.id
        JOIN sequences nested_seq ON c.sequence_id = nested_seq.id
        LEFT JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
                                AND nested_seq.kind = 'master'
                                AND EXISTS (
                                    SELECT 1 FROM tracks mt
                                    WHERE mt.id = mr.track_id
                                      AND mt.track_type = t.track_type
                                )
        WHERE c.track_id = ?
        GROUP BY c.id
        ORDER BY c.timeline_start_frame
    ]])
    if not stmt then
        return nil, "Failed to prepare track clip query"
    end
    stmt:bind_value(1, track_id)

    local results = {}
    if not stmt:exec() then
        local err = stmt:last_error()
        stmt:finalize()
        return nil, err
    end

    while stmt:next() do
        local nested_num = stmt:value(21)
        local nested_den = stmt:value(22)
        local owner_num = stmt:value(18)
        local owner_den = stmt:value(19)
        assert_fps(nested_num, nested_den, "clip (nested-seq) fps")
        assert_fps(owner_num, owner_den, "owner sequence fps")
        local track_type = stmt:value(17)
        local nested_id = stmt:value(5)
        table.insert(results, {
            id = stmt:value(0),
            project_id = stmt:value(1),
            name = stmt:value(2),
            track_id = stmt:value(3),
            owner_sequence_id = stmt:value(4),
            sequence_id = nested_id,
            source_sequence_kind = stmt:value(20),
            master_layer_track_id = stmt:value(10),
            master_audio_track_id = stmt:value(11),
            fps_mismatch_policy = stmt:value(12),
            created_at = stmt:value(15),
            modified_at = stmt:value(16),
            -- Integer frame coordinates
            timeline_start = stmt:value(6),
            duration = stmt:value(7),
            source_in = stmt:value(8),
            source_out = stmt:value(9),
            -- Source-side timebase (nested sequence rate).
            frame_rate = { fps_numerator = nested_num, fps_denominator = nested_den },
            -- Owner-sequence rate (used by occlusion / re-bind paths).
            seq_fps_numerator = owner_num,
            seq_fps_denominator = owner_den,
            enabled = stmt:value(13) == 1 or stmt:value(13) == true,
            volume = stmt:value(14),
            track_type = track_type,
            -- V13-resolved chain leaf (joined media_id; nil when nested is itself nested).
            media_id = stmt:value(23),
        })
    end
    stmt:finalize()
    return results
end

local function normalize_pending_lookup(pending_clips, exclude_id)
    local lookup = {}
    if type(pending_clips) ~= "table" then
        return lookup
    end

    local function ingest(clip_id, pending)
        if not clip_id or clip_id == exclude_id then
            return
        end
        if pending == false or pending.deleted then
            return
        end
        lookup[clip_id] = {
            timeline_start = pending.timeline_start,
            duration = pending.duration,
            tolerance = pending.tolerance,
            _seen = false,
            _virtual = false
        }
    end

    for key, value in pairs(pending_clips) do
        if type(key) == "string" and type(value) == "table" then
            ingest(key, value)
        elseif type(value) == "table" and type(value.id) == "string" then
            ingest(value.id, value)
            if lookup[value.id] then
                lookup[value.id]._virtual = value.virtual == true
            end
        end
    end

    return lookup
end

local function iter_overlaps(clip_list, start_value, end_time)
    local index = 1
    local count = #clip_list

    return function()
        while index <= count do
            local item = clip_list[index]
            index = index + 1
            local clip_start = item.timeline_start
            assert(type(clip_start) == "number", "clip_mutator: overlap check missing clip_start")
            local clip_end = clip_start + (item.duration or 0)

            -- Integer comparison
            if clip_end > start_value and clip_start < end_time then
                return item
            end
            if clip_start >= end_time then
                break
            end
        end
        return nil
    end
end

-- ============================================================================
-- resolve_occlusions: per-clip overlap-case planners
-- ============================================================================
--
-- An existing clip C overlaps a "forbidden span" [start_value, end_time):
--
--    full_cover     — the span swallows C entirely → delete C
--    trim_tail      — span clips C's tail → shrink C's duration
--    trim_head      — span clips C's head → shift start, shorten duration
--    straddle_split — span sits inside C → trim C to the left half +
--                     INSERT a new clip for the right half
--
-- Each helper returns an `action` (or nil if the resulting clip would
-- be sub-frame). Helpers mutate `row` in place where appropriate so the
-- caller's plan_update sees the new state. Source-coord conversion uses
-- `get_seq_fps(row)` to honor the row's nested sequence's timebase.

-- Span fully covers the clip → DELETE.
local function plan_full_cover_action(original)
    return plan_delete(original)
end

-- Span clips the tail. Keep timeline_start, shorten duration to end at
-- start_value. source_in stays; source_out moves (right edge trim).
local function plan_trim_tail_action(row, original, start_value, get_seq_fps)
    local clip_start = row.timeline_start
    local new_duration = start_value - clip_start
    if new_duration < 1 then
        return plan_delete(original)
    end
    local trim_delta = new_duration - row.duration  -- negative (shrinking)
    row.duration = new_duration
    row.source_out = row.source_out + frame_utils.timeline_to_source(
        trim_delta, row.frame_rate.fps_numerator, row.frame_rate.fps_denominator,
        get_seq_fps(row))
    return plan_update(row, original)
end

-- Span clips the head. Shift timeline_start to end_time, shorten duration
-- from the front. source_in moves by trim_amount (in source units);
-- source_out stays.
local function plan_trim_head_action(row, original, end_time, get_seq_fps)
    local clip_start = row.timeline_start
    local clip_end = clip_start + row.duration
    local trim_amount = end_time - clip_start
    local new_duration = clip_end - end_time
    if new_duration < 1 then
        return plan_delete(original)
    end
    row.timeline_start = end_time
    row.duration = new_duration
    row.source_in = get_source_in(row) + frame_utils.timeline_to_source(
        trim_amount, row.frame_rate.fps_numerator, row.frame_rate.fps_denominator,
        get_seq_fps(row))
    row.source_out = require_source_out(original, "resolve_occlusions/head_trim")
    return plan_update(row, original)
end

-- Span sits inside the clip. Trim C to the left half (UPDATE) and INSERT
-- a new clip for the right half. Returns (update_action, insert_action)
-- — caller appends both. Returns just (delete_action) when the left half
-- would be sub-frame.
local function plan_straddle_split_actions(row, original, start_value, end_time, get_seq_fps)
    local clip_start = row.timeline_start
    local clip_end = clip_start + row.duration
    local row_fps_num, row_fps_den = get_row_fps(row)
    local left_duration = start_value - clip_start
    local right_duration = clip_end - end_time
    if left_duration < 1 then
        return plan_delete(original), nil
    end

    local left_trim_delta = left_duration - row.duration  -- negative
    row.duration = left_duration
    row.source_out = row.source_out + frame_utils.timeline_to_source(
        left_trim_delta, row.frame_rate.fps_numerator, row.frame_rate.fps_denominator,
        get_seq_fps(row))
    local update_action = plan_update(row, original)

    if right_duration <= 0 then
        return update_action, nil
    end

    local right_shift = end_time - clip_start
    local right_clip = {
        id                    = uuid.generate(),
        project_id            = original.project_id,
        track_type            = original.track_type,
        name                  = original.name,
        track_id              = original.track_id,
        timeline_start        = end_time,
        duration              = right_duration,
        source_in             = get_source_in(original) + frame_utils.timeline_to_source(
            right_shift, row_fps_num, row_fps_den, get_seq_fps(original)),
        source_out            = require_source_out(original, "resolve_occlusions/straddle_split"),
        frame_rate            = { fps_numerator = row_fps_num, fps_denominator = row_fps_den },
        enabled               = original.enabled,
        volume                = original.volume,
        sequence_id    = original.sequence_id,
        master_layer_track_id = original.master_layer_track_id,
        master_audio_track_id = original.master_audio_track_id,
        fps_mismatch_policy   = original.fps_mismatch_policy,
        owner_sequence_id     = original.owner_sequence_id,
        created_at            = os.time(),
        modified_at           = os.time(),
    }
    return update_action, plan_insert(right_clip)
end

-- Classify the overlap of one existing clip vs. the forbidden span and
-- emit the corresponding actions onto `actions`. No-op when the span
-- doesn't actually intersect (caller already filtered).
local function plan_overlap_actions(row, start_value, end_time, get_seq_fps, actions)
    local clip_start = row.timeline_start
    assert(type(clip_start) == "number", "clip_mutator.resolve_occlusions: missing clip_start")
    local clip_duration = row.duration
    assert(type(clip_duration) == "number", "clip_mutator.resolve_occlusions: missing clip duration")
    local clip_end = clip_start + clip_duration

    local overlap_start = math.max(clip_start, start_value)
    local overlap_end   = math.min(clip_end, end_time)
    if overlap_end <= overlap_start then
        return  -- no actual overlap
    end

    local original = clone_state(row)

    if overlap_start <= clip_start and overlap_end >= clip_end then
        table.insert(actions, plan_full_cover_action(original))
    elseif clip_start < start_value and clip_end <= end_time then
        table.insert(actions, plan_trim_tail_action(row, original, start_value, get_seq_fps))
    elseif clip_start >= start_value and clip_end > end_time then
        table.insert(actions, plan_trim_head_action(row, original, end_time, get_seq_fps))
    elseif clip_start < start_value and clip_end > end_time then
        local update_action, insert_action =
            plan_straddle_split_actions(row, original, start_value, end_time, get_seq_fps)
        table.insert(actions, update_action)
        if insert_action then table.insert(actions, insert_action) end
    end
end

function ClipMutator.resolve_occlusions(db, params)
    assert(type(params) == "table",
        "clip_mutator.resolve_occlusions: params table required")
    local track_id = params.track_id
    assert(type(track_id) == "string" and track_id ~= "",
        "clip_mutator.resolve_occlusions: params.track_id required")
    local start_value = assert(params.timeline_start,
        "clip_mutator.resolve_occlusions: timeline_start is required")
    local duration = assert(params.duration, "clip_mutator.resolve_occlusions: duration is required")

    -- Ensure integer frame coordinates
    start_value = ensure_integer(start_value, "start_value")
    duration = ensure_integer(duration, "duration")

    local end_time = start_value + duration
    local exclude_id = params.exclude_clip_id

    -- Sequence rate for source coordinate conversion (from DB via track→sequence JOIN).
    -- Clips from load_track_clips carry seq_fps fields; clips from pending caches may not.
    local track_seq_fps_num, track_seq_fps_den = lookup_seq_fps_for_track(db, track_id)

    local function get_seq_fps(row_or_original)
        return resolve_seq_fps(row_or_original, track_seq_fps_num, track_seq_fps_den)
    end

    local krono_enabled = krono_ok and krono and krono.is_enabled and krono.is_enabled()
    local krono_start = krono_enabled and krono.now and krono.now() or nil
    local track_clips
    local window_cache = params.pending_clips and params.pending_clips.__window_cache
    if window_cache and window_cache[track_id] then
        track_clips = window_cache[track_id]
    end
    if not track_clips then
        local load_err
        track_clips, load_err = load_track_clips(db, track_id)
        if not track_clips then
            return false, load_err
        end
    end

    local pending_lookup = normalize_pending_lookup(params.pending_clips, exclude_id)
    local overlaps = iter_overlaps(track_clips, start_value, end_time)

    local actions = {}

    local krono_prepare_done = krono_enabled and krono.now and krono.now() or nil
    for row in overlaps do
        if row.id ~= exclude_id then
            local pending_state = pending_lookup[row.id]
            if pending_state then
                pending_state._seen = true
            else
                plan_overlap_actions(row, start_value, end_time, get_seq_fps, actions)
            end
        end
    end

    for clip_id, pending_state in pairs(pending_lookup) do
        if not pending_state._seen and not pending_state._virtual then
            log.warn("resolve_occlusions: pending clip %s was not found on track %s",
                tostring(clip_id), tostring(track_id))
        end
    end

    local krono_end = krono_enabled and krono.now and krono.now() or nil
    if krono_enabled and krono_start and krono_prepare_done and krono_end then
        local total = krono_end - krono_start
        log.event("resolve[%s]: %.2fms (load=%.2fms body=%.2fms)",
            tostring(track_id or "unknown"), total,
            krono_prepare_done - krono_start, krono_end - krono_prepare_done)
    end

    return true, nil, actions
end

--- Resolve occlusions against multiple forbidden spans on one track.
-- Each existing clip is processed against ALL spans in a single pass,
-- producing at most one set of mutations per clip. Avoids the stale-state
-- bug where sequential single-span calls read the same DB snapshot.
-- @param db database handle
-- @param track_id string
-- @param spans {{start=int, ["end"]=int}, ...} sorted, non-overlapping
-- @return ok, err, actions
function ClipMutator.resolve_occlusions_multi(db, track_id, spans)
    assert(track_id, "resolve_occlusions_multi: track_id required")
    if not spans or #spans == 0 then return true, nil, {} end

    local track_clips, load_err = load_track_clips(db, track_id)
    if not track_clips then return false, load_err end

    -- Sequence rate from track→sequence JOIN (authoritative source).
    local db_seq_num, db_seq_den = lookup_seq_fps_for_track(db, track_id)
    local function get_seq_fps(row)
        return resolve_seq_fps(row, db_seq_num, db_seq_den)
    end

    local actions = {}

    for _, row in ipairs(track_clips) do
        local clip_start = row.timeline_start
        assert(type(clip_start) == "number",
            string.format("resolve_occlusions_multi: clip %s missing timeline_start",
                tostring(row.id)))
        local clip_dur = row.duration
        assert(type(clip_dur) == "number" and clip_dur > 0,
            string.format("resolve_occlusions_multi: clip %s invalid duration: %s",
                tostring(row.id), tostring(clip_dur)))
        local clip_end = clip_start + clip_dur

        -- Subtract all spans from [clip_start, clip_end) → surviving fragments
        local fragments = {{s = clip_start, e = clip_end}}
        for _, span in ipairs(spans) do
            local new_frags = {}
            for _, f in ipairs(fragments) do
                if span["end"] <= f.s or span.start >= f.e then
                    -- No overlap
                    table.insert(new_frags, f)
                else
                    -- Left fragment
                    if f.s < span.start then
                        table.insert(new_frags, {s = f.s, e = span.start})
                    end
                    -- Right fragment
                    if f.e > span["end"] then
                        table.insert(new_frags, {s = span["end"], e = f.e})
                    end
                    -- Middle is eaten by span
                end
            end
            fragments = new_frags
        end

        -- Filter out zero-length fragments
        local valid = {}
        for _, f in ipairs(fragments) do
            if f.e - f.s >= 1 then
                table.insert(valid, f)
            end
        end

        local original = clone_state(row)

        local unchanged = (#valid == 1 and valid[1].s == clip_start and valid[1].e == clip_end)
        if #valid == 0 then
            -- Fully occluded
            table.insert(actions, plan_delete(original))
        elseif not unchanged then
            -- First fragment updates the original clip.
            -- Each edge moves independently (preserves speed ratio).
            local first = valid[1]
            local trim_left = first.s - clip_start  -- timeline frames removed from left
            local trim_right = clip_end - first.e   -- timeline frames removed from right
            row.timeline_start = first.s
            row.duration = first.e - first.s
            row.source_in = get_source_in(original) + frame_utils.timeline_to_source(
                trim_left, row.frame_rate.fps_numerator, row.frame_rate.fps_denominator,
                get_seq_fps(row))
            row.source_out = require_source_out(original, "resolve_occlusions_multi/first")
                - frame_utils.timeline_to_source(
                    trim_right, row.frame_rate.fps_numerator, row.frame_rate.fps_denominator,
                    get_seq_fps(row))
            table.insert(actions, plan_update(row, original))

            -- Remaining fragments become new clips (splits)
            for i = 2, #valid do
                local f = valid[i]
                local shift = f.s - clip_start  -- left edge offset in timeline frames
                local trim_right_frag = clip_end - f.e  -- right edge offset in timeline frames
                local row_fps_num, row_fps_den = get_row_fps(original)
                local split_clip = {
                    id = uuid.generate(),
                    project_id = original.project_id,
                    track_type = original.track_type,
                    name = original.name,
                    track_id = original.track_id,
                    sequence_id = original.sequence_id,
                    master_layer_track_id = original.master_layer_track_id,
                    master_audio_track_id = original.master_audio_track_id,
                    fps_mismatch_policy = original.fps_mismatch_policy,
                    owner_sequence_id = original.owner_sequence_id,
                    timeline_start = f.s,
                    duration = f.e - f.s,
                    source_in = get_source_in(original) + frame_utils.timeline_to_source(
                        shift, row_fps_num, row_fps_den,
                        get_seq_fps(original)),
                    source_out = require_source_out(original, "resolve_occlusions_multi/split")
                        - frame_utils.timeline_to_source(
                            trim_right_frag, row_fps_num, row_fps_den,
                            get_seq_fps(original)),
                    frame_rate = { fps_numerator = row_fps_num, fps_denominator = row_fps_den },
                    enabled = original.enabled,
                    volume = original.volume,
                    created_at = os.time(),
                    modified_at = os.time(),
                }
                table.insert(actions, plan_insert(split_clip))
            end
        end
    end

    return true, nil, actions
end

ClipMutator.plan_update = plan_update
ClipMutator.plan_delete = plan_delete
ClipMutator.plan_insert = plan_insert

function ClipMutator.resolve_ripple(db, params)
    assert(type(params) == "table", "clip_mutator.resolve_ripple: params table required")
    local track_id = params.track_id
    local insert_time = params.insert_time or params.timeline_start or params.timeline_start_frame
    local shift_amount = params.shift_amount or params.duration or params.duration_frames
    assert(type(track_id) == "string" and track_id ~= "",
        "clip_mutator.resolve_ripple: params.track_id required")
    assert(type(insert_time) == "number",
        "clip_mutator.resolve_ripple: params.insert_time/timeline_start required")
    assert(shift_amount, "clip_mutator.resolve_ripple: shift_amount/duration is required")

    -- Ensure integer frame coordinates
    insert_time = ensure_integer(insert_time, "insert_time")
    shift_amount = ensure_integer(shift_amount, "shift_amount")

    local track_clips, err = load_track_clips(db, track_id)
    if not track_clips then return false, err end

    local db_seq_num, db_seq_den = lookup_seq_fps_for_track(db, track_id)
    local function get_seq_fps(row)
        return resolve_seq_fps(row, db_seq_num, db_seq_den)
    end

    local actions = {}
    
    -- Iterate and shift/split
    -- Note: clips are ordered by start time
    for _, row in ipairs(track_clips) do
        local original = clone_state(row)
        local clip_start = row.timeline_start
        assert(type(clip_start) == "number", "clip_mutator.resolve_ripple: missing clip_start")
        local clip_end = clip_start + row.duration

        if clip_start >= insert_time then
            -- Fully after: Shift
            row.timeline_start = clip_start + shift_amount
            table.insert(actions, plan_update(row, original))
            
        elseif clip_start < insert_time and clip_end > insert_time then
            -- Straddles: Split
            -- Left Part: Ends at insert_time
            local row_fps_num, row_fps_den = get_row_fps(row)
            local left_dur = insert_time - clip_start

            local tail_trim_delta = left_dur - row.duration  -- negative (shrinking from right)
            row.duration = left_dur
            row.source_out = row.source_out + frame_utils.timeline_to_source(
                tail_trim_delta, row.frame_rate.fps_numerator, row.frame_rate.fps_denominator,
                get_seq_fps(row))

            table.insert(actions, plan_update(row, original))

            -- Right Part: Starts at insert_time + shift_amount
            local right_start = insert_time + shift_amount
            local right_dur = clip_end - insert_time
            local right_src_in = get_source_in(original) + frame_utils.timeline_to_source(
                left_dur, row.frame_rate.fps_numerator, row.frame_rate.fps_denominator,
                get_seq_fps(row))

            local right_clip = {
                id = uuid.generate(),
                project_id = row.project_id,
                track_type = row.track_type,
                name = row.name .. " (2)",
                track_id = row.track_id,
                sequence_id = original.sequence_id,
                master_layer_track_id = original.master_layer_track_id,
                master_audio_track_id = original.master_audio_track_id,
                fps_mismatch_policy = assert(original.fps_mismatch_policy,
                    "clip_mutator: original clip missing fps_mismatch_policy "
                    .. "in resolve_ripple (split right-half)"),
                owner_sequence_id = original.owner_sequence_id,
                timeline_start = right_start,
                duration = right_dur,
                source_in = right_src_in,
                source_out = require_source_out(original, "resolve_ripple"),
                frame_rate = { fps_numerator = row_fps_num, fps_denominator = row_fps_den },
                enabled = row.enabled,
                volume = original.volume,
                created_at = os.time(),
                modified_at = os.time()
            }
            table.insert(actions, plan_insert(right_clip))
        end
    end

    -- For positive shifts (inserting), reverse the update order so rightmost clips
    -- move first, preventing overlap errors when cascading updates
    if shift_amount > 0 then
        local updates = {}
        local non_updates = {}
        for _, action in ipairs(actions) do
            if action.type == "update" then
                table.insert(updates, 1, action)  -- prepend to reverse order
            else
                table.insert(non_updates, action)
            end
        end
        -- Put reversed updates first, then inserts
        actions = {}
        for _, u in ipairs(updates) do
            table.insert(actions, u)
        end
        for _, n in ipairs(non_updates) do
            table.insert(actions, n)
        end
    end

    return true, nil, actions
end

local function get_sequence_fps(db, sequence_id)
    local stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
    assert(stmt, "clip_mutator: failed to prepare sequence fps query")
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec() and stmt:next(), "clip_mutator: sequence not found: " .. tostring(sequence_id))
    local num, den = stmt:value(0), stmt:value(1)
    stmt:finalize()
    assert_fps(num, den, "sequence fps")
    return num, den
end

local function load_sequence_tracks(db, sequence_id)
    local stmt = db:prepare([[
        SELECT id, track_index, track_type
        FROM tracks
        WHERE sequence_id = ?
        ORDER BY track_type ASC, track_index ASC
    ]])
    assert(stmt, "clip_mutator.plan_duplicate_block: failed to prepare tracks query")

    stmt:bind_value(1, sequence_id)
    local ok = stmt:exec()
    assert(ok, "clip_mutator.plan_duplicate_block: failed to execute tracks query")

    local tracks = {}
    while stmt:next() do
        table.insert(tracks, {
            id = stmt:value(0),
            track_index = stmt:value(1),
            track_type = stmt:value(2),
        })
    end
    stmt:finalize()
    return tracks
end

local function build_track_maps(tracks)
    local by_id = {}
    local by_type_index = {}
    for _, track in ipairs(tracks) do
        if track and track.id and track.track_type and track.track_index then
            by_id[track.id] = track
            by_type_index[track.track_type] = by_type_index[track.track_type] or {}
            by_type_index[track.track_type][track.track_index] = track
        end
    end
    return by_id, by_type_index
end

local function merge_intervals(intervals)
    if type(intervals) ~= "table" or #intervals == 0 then
        return {}
    end

    table.sort(intervals, function(a, b)
        return a.start < b.start
    end)

    local merged = {}
    local current = {start = intervals[1].start, ["end"] = intervals[1]["end"]}
    for i = 2, #intervals do
        local next_it = intervals[i]
        if next_it.start <= current["end"] then
            if next_it["end"] > current["end"] then
                current["end"] = next_it["end"]
            end
        else
            table.insert(merged, current)
            current = {start = next_it.start, ["end"] = next_it["end"]}
        end
    end
    table.insert(merged, current)
    return merged
end

local function validate_no_overlaps_per_track(track_intervals)
    for track_id, intervals in pairs(track_intervals) do
        table.sort(intervals, function(a, b)
            return a.start < b.start
        end)
        local prev = nil
        for _, interval in ipairs(intervals) do
            if prev and interval.start < prev["end"] then
                return false, string.format(
                    "clip_mutator.plan_duplicate_block: pasted clips overlap on track %s (%s < %s)",
                    tostring(track_id),
                    tostring(interval.start),
                    tostring(prev["end"])
                )
            end
            prev = interval
        end
    end
    return true
end

local function load_clip_for_duplicate_plan(db, clip_id, sequence_id, seq_fps_num, seq_fps_den)
    local stmt = db:prepare([[
        SELECT c.id, c.project_id, c.name, c.track_id,
               c.owner_sequence_id, c.sequence_id,
               c.timeline_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.volume, c.created_at, c.modified_at,
               t.track_type,
               owner_seq.fps_numerator, owner_seq.fps_denominator,
               nested_seq.kind, nested_seq.fps_numerator, nested_seq.fps_denominator,
               mr.media_id
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences owner_seq ON c.owner_sequence_id = owner_seq.id
        JOIN sequences nested_seq ON c.sequence_id = nested_seq.id
        LEFT JOIN media_refs mr ON mr.owner_sequence_id = c.sequence_id
                                AND nested_seq.kind = 'master'
        WHERE c.id = ?
    ]])
    assert(stmt, "clip_mutator.plan_duplicate_block: failed to prepare clip query")
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    assert(ok, "clip_mutator.plan_duplicate_block: failed to execute clip query")
    if not stmt:next() then
        stmt:finalize()
        return nil
    end

    local owning_sequence_id = stmt:value(4)
    assert(owning_sequence_id == sequence_id,
        string.format("clip_mutator.plan_duplicate_block: clip %s belongs to sequence %s, not %s",
            tostring(clip_id), tostring(owning_sequence_id), tostring(sequence_id)))

    local owning_fps_num = stmt:value(18)
    local owning_fps_den = stmt:value(19)
    assert(owning_fps_num == seq_fps_num and owning_fps_den == seq_fps_den,
        string.format("clip_mutator.plan_duplicate_block: clip %s owning sequence rate mismatch (%s/%s vs %s/%s)",
            tostring(clip_id), tostring(owning_fps_num), tostring(owning_fps_den), tostring(seq_fps_num), tostring(seq_fps_den)))

    local nested_fps_num = stmt:value(21)
    local nested_fps_den = stmt:value(22)
    assert_fps(nested_fps_num, nested_fps_den, "clip (nested-seq) fps")

    local track_type = stmt:value(17)
    local nested_id = stmt:value(5)

    local clip = {
        id = stmt:value(0),
        project_id = stmt:value(1),
        name = stmt:value(2),
        track_id = stmt:value(3),
        owner_sequence_id = owning_sequence_id,
        sequence_id = nested_id,
        master_layer_track_id = stmt:value(10),
        master_audio_track_id = stmt:value(11),
        fps_mismatch_policy = stmt:value(12),
        timeline_start = stmt:value(6),
        duration = stmt:value(7),
        source_in = stmt:value(8),
        source_out = stmt:value(9),
        frame_rate = {fps_numerator = nested_fps_num, fps_denominator = nested_fps_den},
        enabled = stmt:value(13) == 1 or stmt:value(13) == true,
        volume = stmt:value(14),
        created_at = stmt:value(15),
        modified_at = stmt:value(16),
        track_type = track_type,
        source_sequence_kind = stmt:value(20),
        -- V13-resolved chain leaf (nil when nested is itself nested).
        media_id = stmt:value(23),
    }
    stmt:finalize()
    return clip
end

-- Load every source clip referenced by the duplicate request. Returns
-- (clips, min_timeline_start) | (nil, err_string). The min start lets the
-- caller compute a lower bound for delta_frames (clamping prevents the
-- duplicate landing at a negative timeline frame).
local function load_source_clips_for_duplicate(db, sequence_id, clip_ids,
                                               seq_fps_num, seq_fps_den)
    local source_clips = {}
    local min_start
    for _, clip_id in ipairs(clip_ids) do
        local clip = load_clip_for_duplicate_plan(db, clip_id, sequence_id, seq_fps_num, seq_fps_den)
        if not clip then
            return nil, "clip_mutator.plan_duplicate_block: source clip not found: " .. tostring(clip_id)
        end
        assert(type(clip.timeline_start) == "number",
            "clip_mutator.plan_duplicate_block: source clip timeline_start must be integer")
        assert(type(clip.duration) == "number",
            "clip_mutator.plan_duplicate_block: source clip duration must be integer")
        source_clips[#source_clips + 1] = clip
        if not min_start or clip.timeline_start < min_start then
            min_start = clip.timeline_start
        end
    end
    return source_clips, min_start
end

-- Map one source clip to its duplicated counterpart on `mapped_track`,
-- shifted by effective_delta on the timeline. Returns nil for clips that
-- map to no track on the target side or whose duplicate would land
-- exactly on the source.
local function build_duplicated_clip(clip, mapped_track, sequence_id, effective_delta)
    local new_start = clip.timeline_start + effective_delta
    if new_start < 0 then
        return nil, "clip_mutator.plan_duplicate_block: computed negative timeline_start after clamping"
    end
    if new_start == clip.timeline_start and mapped_track.id == clip.track_id then
        return nil  -- no-op (same place, same track)
    end
    local now = os.time()
    return {
        id                    = uuid.generate(),
        project_id            = clip.project_id,
        track_type            = clip.track_type,
        name                  = clip.name,
        track_id              = mapped_track.id,
        owner_sequence_id     = sequence_id,
        sequence_id    = clip.sequence_id,
        master_layer_track_id = clip.master_layer_track_id,
        master_audio_track_id = clip.master_audio_track_id,
        fps_mismatch_policy   = clip.fps_mismatch_policy,
        timeline_start        = new_start,
        duration              = clip.duration,
        source_in             = clip.source_in,
        source_out            = clip.source_out,
        frame_rate            = clip.frame_rate,
        enabled               = clip.enabled,
        created_at            = now,
        modified_at           = now,
        volume                = clip.volume,
        mark_in_frame         = clip.mark_in,
        mark_out_frame        = clip.mark_out,
        playhead_frame        = clip.playhead_frame,
    }
end

-- Walk the source clips, build INSERT mutations for each, and accumulate
-- the planned-interval map (used downstream to validate overlaps and
-- drive occlusion resolution). Returns (mutations, new_clip_ids, intervals_by_track)
-- on success or (nil, err) on failure.
local function plan_duplicate_inserts(source_clips, tracks_by_id, tracks_by_type_index,
                                      anchor_track, sequence_id,
                                      delta_track_index, effective_delta)
    local insert_mutations = {}
    local new_clip_ids = {}
    local intervals_by_track = {}

    for _, clip in ipairs(source_clips) do
        local source_track = clip.track_id and tracks_by_id[clip.track_id] or nil
        assert(source_track, "clip_mutator.plan_duplicate_block: source clip track not found in sequence: "
            .. tostring(clip.track_id))
        local mapped_track = nil
        if source_track.track_type == anchor_track.track_type then
            local target_index = source_track.track_index + delta_track_index
            local by_index = tracks_by_type_index[source_track.track_type]
            mapped_track = by_index and by_index[target_index] or nil
        end
        if mapped_track then
            local new_clip, err = build_duplicated_clip(clip, mapped_track,
                sequence_id, effective_delta)
            if err then
                return nil, err
            end
            if new_clip then
                insert_mutations[#insert_mutations + 1] = plan_insert(new_clip)
                new_clip_ids[#new_clip_ids + 1] = new_clip.id
                intervals_by_track[mapped_track.id] = intervals_by_track[mapped_track.id] or {}
                table.insert(intervals_by_track[mapped_track.id], {
                    start  = new_clip.timeline_start,
                    ["end"] = new_clip.timeline_start + new_clip.duration,
                })
            end
        end
    end
    return insert_mutations, new_clip_ids, intervals_by_track
end

-- Run resolve_occlusions_multi over the merged spans on each track and
-- collect the actions. Returns (mutations, nil) | (nil, err).
local function resolve_duplicate_occlusions(db, intervals_by_track)
    local occlusion_mutations = {}
    for track_id, intervals in pairs(intervals_by_track) do
        local merged = merge_intervals(intervals)
        local ok, err, actions = ClipMutator.resolve_occlusions_multi(db, track_id, merged)
        if not ok then
            return nil, "clip_mutator.plan_duplicate_block: resolve_occlusions_multi failed: " .. tostring(err)
        end
        for _, mut in ipairs(actions) do
            occlusion_mutations[#occlusion_mutations + 1] = mut
        end
    end
    return occlusion_mutations
end

function ClipMutator.plan_duplicate_block(db, params)
    assert(db, "clip_mutator.plan_duplicate_block: db is nil")
    assert(type(params) == "table", "clip_mutator.plan_duplicate_block: params table required")

    local sequence_id = params.sequence_id
    local clip_ids = params.clip_ids
    local target_track_id = params.target_track_id
    local anchor_clip_id = params.anchor_clip_id

    assert(sequence_id and sequence_id ~= "", "clip_mutator.plan_duplicate_block: missing sequence_id")
    assert(type(clip_ids) == "table" and #clip_ids > 0, "clip_mutator.plan_duplicate_block: missing clip_ids")
    assert(target_track_id and target_track_id ~= "", "clip_mutator.plan_duplicate_block: missing target_track_id")

    local seq_fps_num, seq_fps_den = get_sequence_fps(db, sequence_id)

    -- Delta must be integer frames
    local delta_frames = params.delta_frames or 0
    assert(type(delta_frames) == "number", "clip_mutator.plan_duplicate_block: delta_frames must be integer")

    local tracks = load_sequence_tracks(db, sequence_id)
    local tracks_by_id, tracks_by_type_index = build_track_maps(tracks)

    anchor_clip_id = anchor_clip_id or clip_ids[1]
    assert(anchor_clip_id and anchor_clip_id ~= "", "clip_mutator.plan_duplicate_block: missing anchor_clip_id")

    local anchor_clip = load_clip_for_duplicate_plan(db, anchor_clip_id, sequence_id, seq_fps_num, seq_fps_den)
    assert(anchor_clip, "clip_mutator.plan_duplicate_block: anchor clip not found: " .. tostring(anchor_clip_id))

    local anchor_track = anchor_clip.track_id and tracks_by_id[anchor_clip.track_id] or nil
    assert(anchor_track, "clip_mutator.plan_duplicate_block: anchor clip track not found in sequence: " .. tostring(anchor_clip.track_id))

    local target_track = tracks_by_id[target_track_id]
    assert(target_track, "clip_mutator.plan_duplicate_block: target track not found in sequence: " .. tostring(target_track_id))

    assert(target_track.track_type == anchor_track.track_type,
        string.format("clip_mutator.plan_duplicate_block: target track type mismatch (anchor=%s target=%s)",
            tostring(anchor_track.track_type), tostring(target_track.track_type)))

    local delta_track_index = target_track.track_index - anchor_track.track_index
    assert(type(delta_track_index) == "number", "clip_mutator.plan_duplicate_block: invalid delta_track_index")

    if delta_track_index == 0 and delta_frames == 0 then
        return true, nil, {planned_mutations = {}, new_clip_ids = {}}
    end

    local source_clips, load_err = load_source_clips_for_duplicate(
        db, sequence_id, clip_ids, seq_fps_num, seq_fps_den)
    if not source_clips then return false, load_err end

    -- Clamp delta so the duplicated block doesn't land at a negative
    -- timeline frame. resolve_occlusions handles overlap with existing
    -- clips (including the source clip being copied from).
    local min_start
    for _, c in ipairs(source_clips) do
        if not min_start or c.timeline_start < min_start then
            min_start = c.timeline_start
        end
    end
    local lower_bound = -(min_start or 0)
    local effective_delta = math.max(delta_frames, lower_bound)

    local insert_mutations, new_clip_ids, intervals_by_track, plan_err =
        plan_duplicate_inserts(source_clips, tracks_by_id, tracks_by_type_index,
                               anchor_track, sequence_id,
                               delta_track_index, effective_delta)
    if not insert_mutations then return false, plan_err end
    if #insert_mutations == 0 then
        return true, nil, {planned_mutations = {}, new_clip_ids = {}}
    end

    local ok_overlaps, overlap_err = validate_no_overlaps_per_track(intervals_by_track)
    if not ok_overlaps then
        return false, overlap_err
    end

    local occlusion_mutations, occ_err = resolve_duplicate_occlusions(db, intervals_by_track)
    if not occlusion_mutations then return false, occ_err end

    local combined = {}
    for _, mut in ipairs(occlusion_mutations) do combined[#combined + 1] = mut end
    for _, mut in ipairs(insert_mutations)   do combined[#combined + 1] = mut end
    return true, nil, {planned_mutations = combined, new_clip_ids = new_clip_ids}
end

return ClipMutator
