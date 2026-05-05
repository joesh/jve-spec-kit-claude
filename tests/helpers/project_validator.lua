--- Project validator — checkRep for JVP database, in-memory timeline, undo stack.
--
-- Three layers of validation, callable independently or together:
--   validate_jvp(db)           — database integrity (no mocks, real SQL)
--   validate_timeline(ts, db)  — in-memory state matches DB, gap invariants
--   validate_undo_stack(db, sequence_id) — cursor validity, parent chain, isolation
--   validate_all(db, ts, sequence_id)    — all of the above
--
-- Returns: {ok = bool, errors = {string...}}
-- On failure, errors describe exactly which invariant broke.
--
-- Design: pure validation — never mutates state, never writes to DB.
--
-- @file project_validator.lua

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function result_new()
    return {ok = true, errors = {}}
end

local function fail(result, msg)
    result.ok = false
    table.insert(result.errors, msg)
end

local function merge(target, source)
    if not source.ok then
        target.ok = false
    end
    for _, err in ipairs(source.errors) do
        table.insert(target.errors, err)
    end
end

--- Execute a SQL query and iterate rows with a callback.
-- callback receives the prepared statement positioned at each row.
local function each_row(db, sql, callback)
    local stmt = db:prepare(sql)
    assert(stmt, "project_validator: failed to prepare: " .. sql)
    assert(stmt:exec(), "project_validator: failed to exec: " .. sql)
    while stmt:next() do
        callback(stmt)
    end
    stmt:finalize()
end

--- Execute a SQL query and return a single scalar value.
local function scalar(db, sql)
    local stmt = db:prepare(sql)
    assert(stmt, "project_validator: failed to prepare: " .. sql)
    assert(stmt:exec(), "project_validator: failed to exec: " .. sql)
    local value = nil
    if stmt:next() then
        value = stmt:value(0)
    end
    stmt:finalize()
    return value
end

-- ---------------------------------------------------------------------------
-- JVP Database Validation
-- ---------------------------------------------------------------------------

--- Check that all frame coordinate columns contain integers (not floats).
local function check_integer_frames(db, result)
    local frame_columns = {
        {"clips", "timeline_start_frame"},
        {"clips", "duration_frames"},
        {"clips", "source_in_frame"},
        {"clips", "source_out_frame"},
        {"clips", "playhead_frame"},
        {"clips", "mark_in_frame"},
        {"clips", "mark_out_frame"},
        {"sequences", "playhead_frame"},
        {"sequences", "view_start_frame"},
        {"sequences", "view_duration_frames"},
        {"sequences", "start_timecode_frame"},
        {"sequences", "video_scroll_offset"},
        {"sequences", "audio_scroll_offset"},
        {"media", "duration_frames"},
    }

    for _, spec in ipairs(frame_columns) do
        local tbl, col = spec[1], spec[2]
        -- Check for non-integer numeric values (SQLite typeof returns 'real' for floats)
        local sql = string.format(
            "SELECT id, %s FROM %s WHERE %s IS NOT NULL AND typeof(%s) = 'real' AND %s != CAST(%s AS INTEGER)",
            col, tbl, col, col, col, col)
        each_row(db, sql, function(stmt)
            fail(result, string.format(
                "FLOAT_FRAME: %s.%s is float (%s) for id=%s",
                tbl, col, tostring(stmt:value(1)), tostring(stmt:value(0))))
        end)
    end
end

--- Check clip duration > 0 (schema CHECK should catch this, but verify).
local function check_clip_durations(db, result)
    each_row(db,
        "SELECT id, name, duration_frames FROM clips WHERE duration_frames <= 0",
        function(stmt)
            fail(result, string.format(
                "ZERO_DURATION: clip %s (%s) has duration=%d",
                tostring(stmt:value(0)), tostring(stmt:value(1)), stmt:value(2)))
        end)
end

--- Check no overlapping clips on VIDEO tracks.
-- The DB trigger prevents this on write, but we verify read state too.
local function check_video_overlaps(db, result)
    local sql = [[
        SELECT c1.id, c1.name, c2.id, c2.name, c1.track_id,
               c1.timeline_start_frame, c1.duration_frames,
               c2.timeline_start_frame, c2.duration_frames
        FROM clips c1
        JOIN clips c2 ON c1.track_id = c2.track_id AND c1.id < c2.id
        JOIN tracks t ON t.id = c1.track_id
        WHERE t.track_type = 'VIDEO'
          AND 1=1
          AND c1.timeline_start_frame < (c2.timeline_start_frame + c2.duration_frames)
          AND (c1.timeline_start_frame + c1.duration_frames) > c2.timeline_start_frame
    ]]
    each_row(db, sql, function(stmt)
        fail(result, string.format(
            "VIDEO_OVERLAP: clips %s (%s) [%d..%d] and %s (%s) [%d..%d] overlap on track %s",
            stmt:value(0), stmt:value(1),
            stmt:value(5), stmt:value(5) + stmt:value(6),
            stmt:value(2), stmt:value(3),
            stmt:value(7), stmt:value(7) + stmt:value(8),
            stmt:value(4)))
    end)
end

--- Check foreign key integrity.
local function check_foreign_keys(db, result)
    each_row(db, "PRAGMA foreign_key_check", function(stmt)
        fail(result, string.format(
            "FK_VIOLATION: table=%s rowid=%s parent=%s fkid=%s",
            tostring(stmt:value(0)), tostring(stmt:value(1)),
            tostring(stmt:value(2)), tostring(stmt:value(3))))
    end)
end

--- Check fps values are positive.
local function check_fps_positive(db, result)
    -- V13: clips no longer carry fps; rate derives from nested_sequence_id.
    local tables = {
        {"sequences", "fps_numerator", "fps_denominator"},
        {"media", "fps_numerator", "fps_denominator"},
    }
    for _, spec in ipairs(tables) do
        local tbl, num_col, den_col = spec[1], spec[2], spec[3]
        local sql = string.format(
            "SELECT id, %s, %s FROM %s WHERE %s <= 0 OR %s <= 0",
            num_col, den_col, tbl, num_col, den_col)
        each_row(db, sql, function(stmt)
            fail(result, string.format(
                "BAD_FPS: %s id=%s has fps %s/%s",
                tbl, tostring(stmt:value(0)),
                tostring(stmt:value(1)), tostring(stmt:value(2))))
        end)
    end
end

--- Check source range validity for timeline clips.
-- Reverse clips legitimately have source_in > source_out (JVE convention:
-- playback direction is derived from the sign of source_out - source_in).
-- This check flags clips where source_in == source_out (zero source range)
-- which is always invalid — even freeze frames have at least 1 frame.
local function check_source_range(db, result)
    each_row(db,
        [[SELECT id, name, source_in_frame, source_out_frame
          FROM clips
          WHERE 1=1
            AND source_in_frame IS NOT NULL
            AND source_out_frame IS NOT NULL
            AND source_out_frame = source_in_frame]],
        function(stmt)
            fail(result, string.format(
                "ZERO_SOURCE_RANGE: clip %s (%s) has source_in=%d == source_out=%d",
                tostring(stmt:value(0)), tostring(stmt:value(1)),
                stmt:value(2), stmt:value(3)))
        end)
end

--- Check source_out consistency by computing the implied speed ratio.
--- Speed = actual_source_range / unity_source_range.
--- Legitimate speeds are ~0.01x to ~100x. Our unit mismatch bug produced
--- speeds of ~0.0005 (missing ×1920 factor) — clearly detectable.
local function check_source_out_speed_ratio(db, result, sequence_id_filter)
    local where_clause = ""
    if sequence_id_filter then
        where_clause = string.format(" AND t.sequence_id = '%s'", sequence_id_filter)
    end
    -- V13: clip's source units depend on the OWNER track type:
    --   * VIDEO clips → source_in/out are in nested-sequence FRAMES at
    --     nested.fps_numerator/denominator. Unity = dur * nested_fps/seq_fps.
    --   * AUDIO clips → source_in/out are in nested-sequence SAMPLES at
    --     nested.audio_sample_rate. Unity = dur * audio_sr / seq_fps.
    -- The pre-013 single-fps formula generated false ABSURD_SPEED on every
    -- audio clip with implied speed = audio_sample_rate / seq_fps. See
    -- todo_audio_media_tc_rate_normalization in MEMORY.md.
    local sql = string.format([[
        SELECT c.id, c.name, c.source_in_frame, c.source_out_frame,
               c.duration_frames,
               nested.fps_numerator, nested.fps_denominator,
               s.fps_numerator, s.fps_denominator,
               t.track_type, nested.audio_sample_rate
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN sequences s ON t.sequence_id = s.id
        JOIN sequences nested ON c.nested_sequence_id = nested.id
        WHERE 1=1
          AND c.source_in_frame IS NOT NULL
          AND c.source_out_frame IS NOT NULL
          AND c.duration_frames > 0
          %s
    ]], where_clause)

    local MIN_SPEED = 0.001  -- 1/1000x (Resolve allows down to ~0.1% via Change Clip Speed)
    local MAX_SPEED = 100.0  -- 100x fast-forward

    each_row(db, sql, function(stmt)
        local clip_id = stmt:value(0)
        local source_in = stmt:value(2)
        local source_out = stmt:value(3)
        local duration = stmt:value(4)
        local clip_fps_num = stmt:value(5)
        local clip_fps_den = stmt:value(6)
        local seq_fps_num = stmt:value(7)
        local seq_fps_den = stmt:value(8)
        local track_type = stmt:value(9)
        local nested_audio_sr = stmt:value(10)

        local actual_source_range = source_out - source_in
        -- Reverse clips have negative source range — use absolute value for speed
        if actual_source_range < 0 then actual_source_range = -actual_source_range end

        -- Pick the right source-unit rate per track type (see comment above).
        local src_num, src_den
        if track_type == "AUDIO" then
            if not (nested_audio_sr and nested_audio_sr > 0) then
                fail(result, string.format(
                    "MISSING_AUDIO_RATE: audio clip %s (%s) — nested master "
                    .. "%s has no audio_sample_rate; importer dropped it",
                    tostring(clip_id), tostring(stmt:value(1)),
                    tostring(stmt:value(0))))
                return
            end
            src_num, src_den = nested_audio_sr, 1
        else
            src_num, src_den = clip_fps_num, clip_fps_den
        end

        -- Unity source range = duration * source_rate / seq_rate
        local unity_source_range = duration * src_num * seq_fps_den
            / (src_den * seq_fps_num)

        if unity_source_range > 0 then
            local speed = actual_source_range / unity_source_range
            if speed < MIN_SPEED or speed > MAX_SPEED then
                fail(result, string.format(
                    "ABSURD_SPEED: clip %s (%s) implied speed=%.4f "
                    .. "(source_range=%d unity_range=%.0f source_in=%d source_out=%d "
                    .. "dur=%d src_rate=%s/%s seq_rate=%d/%d track=%s)",
                    tostring(clip_id), tostring(stmt:value(1)),
                    speed, source_out - source_in, unity_source_range,
                    source_in, source_out, duration,
                    tostring(src_num), tostring(src_den),
                    seq_fps_num, seq_fps_den, tostring(track_type)))
            end
        end
    end)
end

--- Check orphan clips (track_id references nonexistent track).
-- FK should catch this but verify.
local function check_orphan_clips(db, result)
    each_row(db,
        [[SELECT c.id, c.name, c.track_id
          FROM clips c
          WHERE c.track_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM tracks t WHERE t.id = c.track_id)]],
        function(stmt)
            fail(result, string.format(
                "ORPHAN_CLIP: clip %s (%s) references nonexistent track %s",
                tostring(stmt:value(0)), tostring(stmt:value(1)), tostring(stmt:value(2))))
        end)
end

--- Check track index uniqueness per sequence/type (UNIQUE constraint backup).
local function check_track_index_uniqueness(db, result)
    each_row(db,
        [[SELECT sequence_id, track_type, track_index, COUNT(*) as cnt
          FROM tracks
          GROUP BY sequence_id, track_type, track_index
          HAVING cnt > 1]],
        function(stmt)
            fail(result, string.format(
                "DUPLICATE_TRACK_INDEX: sequence=%s type=%s index=%d has %d tracks",
                tostring(stmt:value(0)), tostring(stmt:value(1)),
                stmt:value(2), stmt:value(3)))
        end)
end

--- Check video overlaps scoped to a single sequence (fast path).
local function check_video_overlaps_for_sequence(db, sequence_id, result)
    local sql = string.format([[
        SELECT c1.id, c1.name, c2.id, c2.name, c1.track_id,
               c1.timeline_start_frame, c1.duration_frames,
               c2.timeline_start_frame, c2.duration_frames
        FROM clips c1
        JOIN clips c2 ON c1.track_id = c2.track_id AND c1.id < c2.id
        JOIN tracks t ON t.id = c1.track_id
        WHERE t.track_type = 'VIDEO'
          AND t.sequence_id = '%s'
          AND 1=1
          AND c1.timeline_start_frame < (c2.timeline_start_frame + c2.duration_frames)
          AND (c1.timeline_start_frame + c1.duration_frames) > c2.timeline_start_frame
    ]], sequence_id)
    each_row(db, sql, function(stmt)
        fail(result, string.format(
            "VIDEO_OVERLAP: clips %s (%s) [%d..%d] and %s (%s) [%d..%d] overlap on track %s",
            stmt:value(0), stmt:value(1),
            stmt:value(5), stmt:value(5) + stmt:value(6),
            stmt:value(2), stmt:value(3),
            stmt:value(7), stmt:value(7) + stmt:value(8),
            stmt:value(4)))
    end)
end

--- Check integer frames scoped to clips in a specific sequence.
local function check_integer_frames_for_sequence(db, sequence_id, result)
    local frame_columns = {
        "timeline_start_frame", "duration_frames",
        "source_in_frame", "source_out_frame",
        "playhead_frame", "mark_in_frame", "mark_out_frame",
    }
    for _, col in ipairs(frame_columns) do
        local sql = string.format(
            [[SELECT c.id, c.%s FROM clips c
              JOIN tracks t ON c.track_id = t.id
              WHERE t.sequence_id = '%s'
                AND c.%s IS NOT NULL
                AND typeof(c.%s) = 'real'
                AND c.%s != CAST(c.%s AS INTEGER)]],
            col, sequence_id, col, col, col, col)
        each_row(db, sql, function(stmt)
            fail(result, string.format(
                "FLOAT_FRAME: clips.%s is float (%s) for id=%s",
                col, tostring(stmt:value(1)), tostring(stmt:value(0))))
        end)
    end
end

--- Check clip durations scoped to a sequence.
local function check_clip_durations_for_sequence(db, sequence_id, result)
    each_row(db,
        string.format(
            [[SELECT c.id, c.name, c.duration_frames FROM clips c
              JOIN tracks t ON c.track_id = t.id
              WHERE t.sequence_id = '%s' AND c.duration_frames <= 0]], sequence_id),
        function(stmt)
            fail(result, string.format(
                "ZERO_DURATION: clip %s (%s) has duration=%d",
                tostring(stmt:value(0)), tostring(stmt:value(1)), stmt:value(2)))
        end)
end

--- Check source range validity scoped to a sequence.
-- Reverse clips legitimately have source_in > source_out (JVE convention:
-- playback direction is derived from the sign of source_out - source_in).
-- Flag only the zero-range case — even freeze frames have ≥ 1 frame.
-- Mirrors the project-wide check_source_range (fix 197b000).
local function check_source_range_for_sequence(db, sequence_id, result)
    each_row(db,
        string.format(
            [[SELECT c.id, c.name, c.source_in_frame, c.source_out_frame
              FROM clips c
              JOIN tracks t ON c.track_id = t.id
              WHERE t.sequence_id = '%s'
                AND 1=1
                AND c.source_in_frame IS NOT NULL
                AND c.source_out_frame IS NOT NULL
                AND c.source_out_frame = c.source_in_frame]], sequence_id),
        function(stmt)
            fail(result, string.format(
                "ZERO_SOURCE_RANGE: clip %s (%s) has source_in=source_out=%d",
                tostring(stmt:value(0)), tostring(stmt:value(1)),
                stmt:value(2)))
        end)
end

--- Full JVP database validation (all sequences — slow for large projects).
-- @param db  Database connection (read-only access sufficient)
-- @return table {ok=bool, errors={string...}}
function M.validate_jvp(db)
    assert(db, "validate_jvp: db required")
    local result = result_new()

    check_foreign_keys(db, result)
    check_integer_frames(db, result)
    check_clip_durations(db, result)
    check_video_overlaps(db, result)
    check_fps_positive(db, result)
    check_source_range(db, result)
    check_source_out_speed_ratio(db, result)
    check_orphan_clips(db, result)
    check_track_index_uniqueness(db, result)

    return result
end

--- Fast JVP validation scoped to a single sequence.
-- Use this between operations in integration tests.
-- @param db  Database connection
-- @param sequence_id  Sequence to validate
-- @return table {ok=bool, errors={string...}}
function M.validate_jvp_for_sequence(db, sequence_id)
    assert(db, "validate_jvp_for_sequence: db required")
    assert(sequence_id, "validate_jvp_for_sequence: sequence_id required")
    local result = result_new()

    check_integer_frames_for_sequence(db, sequence_id, result)
    check_clip_durations_for_sequence(db, sequence_id, result)
    check_video_overlaps_for_sequence(db, sequence_id, result)
    check_source_range_for_sequence(db, sequence_id, result)
    check_source_out_speed_ratio(db, result, sequence_id)

    return result
end

-- ---------------------------------------------------------------------------
-- Timeline (In-Memory) Validation
-- ---------------------------------------------------------------------------

--- Check that in-memory clips match the DB for a given sequence.
local function check_clips_match_db(ts, db, sequence_id, result)
    -- Get in-memory clips (media only — gaps are derived)
    local mem_clips = ts.get_clips()
    if not mem_clips then
        fail(result, "TIMELINE_NO_CLIPS: get_clips() returned nil")
        return
    end

    local mem_media = {}
    for _, clip in ipairs(mem_clips) do
        if not clip.is_gap then
            mem_media[clip.id] = clip
        end
    end

    -- Get DB clips for this sequence
    local db_clips = {}
    each_row(db,
        string.format(
            [[SELECT c.id, c.timeline_start_frame, c.duration_frames,
                     c.source_in_frame, c.source_out_frame
              FROM clips c
              JOIN tracks t ON c.track_id = t.id
              WHERE t.sequence_id = '%s' AND 1=1]],
            sequence_id),
        function(stmt)
            db_clips[stmt:value(0)] = {
                timeline_start = stmt:value(1),
                duration = stmt:value(2),
                source_in = stmt:value(3),
                source_out = stmt:value(4),
            }
        end)

    -- Check memory has all DB clips
    for id, db_clip in pairs(db_clips) do
        local mem = mem_media[id]
        if not mem then
            fail(result, string.format(
                "CLIP_MISSING_IN_MEMORY: DB clip %s not in timeline_state", id))
        else
            if mem.timeline_start ~= db_clip.timeline_start then
                fail(result, string.format(
                    "CLIP_START_MISMATCH: clip %s memory=%d db=%d",
                    id, mem.timeline_start, db_clip.timeline_start))
            end
            if mem.duration ~= db_clip.duration then
                fail(result, string.format(
                    "CLIP_DURATION_MISMATCH: clip %s memory=%d db=%d",
                    id, mem.duration, db_clip.duration))
            end
            if mem.source_in ~= db_clip.source_in then
                fail(result, string.format(
                    "CLIP_SOURCE_IN_MISMATCH: clip %s memory=%d db=%d",
                    id, mem.source_in, db_clip.source_in))
            end
            if mem.source_out ~= db_clip.source_out then
                fail(result, string.format(
                    "CLIP_SOURCE_OUT_MISMATCH: clip %s memory=%d db=%d",
                    id, mem.source_out, db_clip.source_out))
            end
        end
    end

    -- Check memory has no extra clips
    for id, _ in pairs(mem_media) do
        if not db_clips[id] then
            fail(result, string.format(
                "CLIP_EXTRA_IN_MEMORY: memory clip %s not in DB", id))
        end
    end
end

--- Check gap clip invariants on all tracks in the sequence.
local function check_gap_invariants(ts, result)
    local clips = ts.get_clips()
    if not clips then return end

    -- Group clips by track
    local by_track = {}
    for _, clip in ipairs(clips) do
        local tid = clip.track_id
        if not by_track[tid] then by_track[tid] = {} end
        table.insert(by_track[tid], clip)
    end

    for track_id, track_clips in pairs(by_track) do
        -- Sort by timeline_start
        table.sort(track_clips, function(a, b)
            if a.timeline_start == b.timeline_start then
                return (a.id or "") < (b.id or "")
            end
            return a.timeline_start < b.timeline_start
        end)

        -- Check: no two adjacent gaps
        local prev_was_gap = false
        for _, clip in ipairs(track_clips) do
            local is_gap = clip.is_gap == true
            if is_gap and prev_was_gap then
                fail(result, string.format(
                    "ADJACENT_GAPS: track %s has adjacent gaps at position %d",
                    track_id, clip.timeline_start))
            end
            prev_was_gap = is_gap
        end

        -- Check: gaps connect correctly to neighbors
        for i = 1, #track_clips do
            local clip = track_clips[i]
            local next_clip = track_clips[i + 1]

            if next_clip then
                local clip_end = clip.timeline_start + clip.duration
                if clip_end ~= next_clip.timeline_start then
                    -- Allow zero-length gaps between adjacent media clips
                    -- (they may not have been materialized yet)
                    if not (not clip.is_gap and not next_clip.is_gap
                            and clip_end == next_clip.timeline_start) then
                        fail(result, string.format(
                            "GAP_DISCONTINUITY: track %s: clip %s ends at %d but next clip %s starts at %d",
                            track_id, clip.id, clip_end, next_clip.id, next_clip.timeline_start))
                    end
                end
            end

            -- Check: gap duration >= 0
            if clip.is_gap == true and clip.duration < 0 then
                fail(result, string.format(
                    "NEGATIVE_GAP: track %s gap %s has duration %d",
                    track_id, clip.id, clip.duration))
            end

            -- Check: media clip duration > 0
            if not clip.is_gap and clip.duration <= 0 then
                fail(result, string.format(
                    "ZERO_MEDIA_CLIP: track %s clip %s has duration %d",
                    track_id, clip.id, clip.duration))
            end
        end

        -- Check: between any two adjacent media clips, exactly one gap
        local media_only = {}
        for _, clip in ipairs(track_clips) do
            if not clip.is_gap then
                table.insert(media_only, clip)
            end
        end

        for i = 1, #media_only - 1 do
            local curr = media_only[i]
            local next_media = media_only[i + 1]
            local curr_end = curr.timeline_start + curr.duration
            local gap_size = next_media.timeline_start - curr_end

            if gap_size > 0 then
                -- There should be exactly one gap between these clips
                local gap_count = 0
                for _, clip in ipairs(track_clips) do
                    if clip.is_gap == true
                        and clip.timeline_start >= curr_end
                        and clip.timeline_start < next_media.timeline_start then
                        gap_count = gap_count + 1
                    end
                end
                if gap_count ~= 1 then
                    fail(result, string.format(
                        "GAP_COUNT: track %s between clips %s (end=%d) and %s (start=%d): expected 1 gap, found %d",
                        track_id, curr.id, curr_end, next_media.id, next_media.timeline_start, gap_count))
                end
            end
        end

        -- Check: gap before first clip if it doesn't start at 0
        if #media_only > 0 and media_only[1].timeline_start > 0 then
            local leading_gap = false
            for _, clip in ipairs(track_clips) do
                if clip.is_gap == true and clip.timeline_start == 0 then
                    leading_gap = true
                    if clip.duration ~= media_only[1].timeline_start then
                        fail(result, string.format(
                            "LEADING_GAP_SIZE: track %s leading gap duration=%d but first clip starts at %d",
                            track_id, clip.duration, media_only[1].timeline_start))
                    end
                    break
                end
            end
            if not leading_gap then
                fail(result, string.format(
                    "MISSING_LEADING_GAP: track %s first clip starts at %d but no gap from 0",
                    track_id, media_only[1].timeline_start))
            end
        end
    end
end

--- Check selection state consistency.
local function check_selection_consistency(ts, result)
    -- Selected clips should exist in the clip list
    local selected = ts.get_selected_clips and ts.get_selected_clips()
    if selected and #selected > 0 then
        local clips = ts.get_clips()
        if clips then
            local clip_ids = {}
            for _, clip in ipairs(clips) do
                if clip.id then clip_ids[clip.id] = true end
            end
            for _, sel in ipairs(selected) do
                local sel_id = type(sel) == "table" and sel.id or sel
                if sel_id and not clip_ids[sel_id] then
                    fail(result, string.format(
                        "SELECTED_CLIP_MISSING: selected clip %s not in clip list",
                        tostring(sel_id)))
                end
            end
        end
    end

    -- Selected edges should reference existing clips
    local edges = ts.get_selected_edges and ts.get_selected_edges()
    if edges and #edges > 0 then
        local clips = ts.get_clips()
        if clips then
            local clip_ids = {}
            for _, clip in ipairs(clips) do
                if clip.id then clip_ids[clip.id] = true end
            end
            for _, edge in ipairs(edges) do
                if edge.clip_id and not clip_ids[edge.clip_id] then
                    fail(result, string.format(
                        "SELECTED_EDGE_MISSING: edge references clip %s not in clip list",
                        tostring(edge.clip_id)))
                end
                if edge.edge_type ~= "in" and edge.edge_type ~= "out" then
                    fail(result, string.format(
                        "BAD_EDGE_TYPE: edge on clip %s has edge_type=%s (expected 'in' or 'out')",
                        tostring(edge.clip_id), tostring(edge.edge_type)))
                end
            end
        end
    end
end

--- Full timeline in-memory validation.
-- @param ts  timeline_state module (must be initialized)
-- @param db  Database connection
-- @param sequence_id  Active sequence ID
-- @return table {ok=bool, errors={string...}}
function M.validate_timeline(ts, db, sequence_id)
    assert(ts, "validate_timeline: timeline_state required")
    assert(db, "validate_timeline: db required")
    assert(sequence_id, "validate_timeline: sequence_id required")
    local result = result_new()

    check_clips_match_db(ts, db, sequence_id, result)
    check_gap_invariants(ts, result)
    check_selection_consistency(ts, result)

    return result
end

-- ---------------------------------------------------------------------------
-- Undo Stack Validation
-- ---------------------------------------------------------------------------

--- Check that sequence_numbers are unique and monotonically assigned.
local function check_sequence_numbers(db, result)
    -- UNIQUE constraint should enforce this, but verify no gaps/duplicates
    -- in the parent chain
    local count = scalar(db, "SELECT COUNT(*) FROM commands")
    if not count or count == 0 then return end  -- empty history is valid

    -- Check for duplicate sequence numbers
    each_row(db,
        [[SELECT sequence_number, COUNT(*) as cnt
          FROM commands
          GROUP BY sequence_number
          HAVING cnt > 1]],
        function(stmt)
            fail(result, string.format(
                "DUPLICATE_SEQ_NUM: sequence_number=%d appears %d times",
                stmt:value(0), stmt:value(1)))
        end)
end

--- Check that parent_sequence_number references exist.
local function check_parent_chain(db, result)
    each_row(db,
        [[SELECT c.sequence_number, c.command_type, c.parent_sequence_number
          FROM commands c
          WHERE c.parent_sequence_number IS NOT NULL
            AND c.parent_sequence_number > 0
            AND NOT EXISTS (
                SELECT 1 FROM commands p
                WHERE p.sequence_number = c.parent_sequence_number
            )]],
        function(stmt)
            fail(result, string.format(
                "ORPHAN_PARENT: command seq=%d (%s) has parent_sequence_number=%d which doesn't exist",
                stmt:value(0), tostring(stmt:value(1)), stmt:value(2)))
        end)
end

--- Check that per-sequence cursor points to a valid command.
local function check_sequence_cursors(db, result)
    each_row(db,
        [[SELECT s.id, s.name, s.current_sequence_number
          FROM sequences s
          WHERE s.current_sequence_number IS NOT NULL
            AND s.current_sequence_number > 0
            AND NOT EXISTS (
                SELECT 1 FROM commands c
                WHERE c.sequence_number = s.current_sequence_number
            )]],
        function(stmt)
            fail(result, string.format(
                "ORPHAN_CURSOR: sequence %s (%s) cursor=%d points to nonexistent command",
                tostring(stmt:value(0)), tostring(stmt:value(1)), stmt:value(2)))
        end)
end

--- Check that undo_group_id references a valid command (the root of the group).
local function check_undo_groups(db, result)
    each_row(db,
        [[SELECT c.sequence_number, c.command_type, c.undo_group_id
          FROM commands c
          WHERE c.undo_group_id IS NOT NULL
            AND NOT EXISTS (
                SELECT 1 FROM commands r
                WHERE r.sequence_number = c.undo_group_id
            )]],
        function(stmt)
            fail(result, string.format(
                "ORPHAN_GROUP: command seq=%d (%s) has undo_group_id=%d which doesn't exist",
                stmt:value(0), tostring(stmt:value(1)), stmt:value(2)))
        end)
end

--- Check that commands tagged with a sequence_id reference a real sequence.
local function check_command_sequence_refs(db, result)
    each_row(db,
        [[SELECT c.sequence_number, c.command_type, c.sequence_id
          FROM commands c
          WHERE c.sequence_id IS NOT NULL
            AND NOT EXISTS (
                SELECT 1 FROM sequences s
                WHERE s.id = c.sequence_id
            )]],
        function(stmt)
            fail(result, string.format(
                "ORPHAN_CMD_SEQ: command seq=%d (%s) references nonexistent sequence %s",
                stmt:value(0), tostring(stmt:value(1)), tostring(stmt:value(2))))
        end)
end

--- Check that parent_sequence_number < sequence_number (parent is always earlier).
local function check_parent_ordering(db, result)
    each_row(db,
        [[SELECT sequence_number, command_type, parent_sequence_number
          FROM commands
          WHERE parent_sequence_number IS NOT NULL
            AND parent_sequence_number >= sequence_number]],
        function(stmt)
            fail(result, string.format(
                "PARENT_AFTER_CHILD: command seq=%d (%s) has parent=%d >= self",
                stmt:value(0), tostring(stmt:value(1)), stmt:value(2)))
        end)
end

--- Full undo stack validation.
-- @param db  Database connection
-- @return table {ok=bool, errors={string...}}
function M.validate_undo_stack(db)
    assert(db, "validate_undo_stack: db required")
    local result = result_new()

    check_sequence_numbers(db, result)
    check_parent_chain(db, result)
    check_parent_ordering(db, result)
    check_sequence_cursors(db, result)
    check_undo_groups(db, result)
    check_command_sequence_refs(db, result)

    return result
end

-- ---------------------------------------------------------------------------
-- Combined Validation
-- ---------------------------------------------------------------------------

--- Run all validators. Timeline validation is optional (skipped if ts is nil).
-- Uses full-project JVP scan (slow for large projects).
-- @param db  Database connection
-- @param ts  timeline_state module or nil (skip timeline checks)
-- @param sequence_id  Active sequence ID or nil (skip timeline checks)
-- @return table {ok=bool, errors={string...}}
function M.validate_all(db, ts, sequence_id)
    assert(db, "validate_all: db required")
    local result = result_new()

    merge(result, M.validate_jvp(db))
    merge(result, M.validate_undo_stack(db))

    if ts and sequence_id then
        merge(result, M.validate_timeline(ts, db, sequence_id))
    end

    return result
end

--- Fast validation scoped to a single sequence.
-- Use between operations in integration tests.
-- @param db  Database connection
-- @param sequence_id  Active sequence ID
-- @param ts  timeline_state module or nil (skip in-memory checks)
-- @return table {ok=bool, errors={string...}}
function M.validate_sequence(db, sequence_id, ts)
    assert(db, "validate_sequence: db required")
    assert(sequence_id, "validate_sequence: sequence_id required")
    local result = result_new()

    merge(result, M.validate_jvp_for_sequence(db, sequence_id))
    merge(result, M.validate_undo_stack(db))

    if ts then
        merge(result, M.validate_timeline(ts, db, sequence_id))
    end

    return result
end

--- Assert that validation passes. Errors on failure with full diagnostics.
-- @param db  Database connection
-- @param ts  timeline_state module or nil
-- @param sequence_id  Active sequence ID or nil
-- @param context  string describing when this check runs (e.g., "after roll edit")
function M.assert_valid(db, ts, sequence_id, context)
    local result
    if sequence_id then
        result = M.validate_sequence(db, sequence_id, ts)
    else
        result = M.validate_all(db, ts, sequence_id)
    end
    if not result.ok then
        local msg = string.format(
            "PROJECT VALIDATION FAILED%s:\n  %s",
            context and (" (" .. context .. ")") or "",
            table.concat(result.errors, "\n  "))
        error(msg, 2)
    end
end

return M
