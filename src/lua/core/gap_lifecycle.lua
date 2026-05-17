--- Gap lifecycle manager — create, resize, merge, split, delete in-memory gap clips.
--
-- Responsibilities:
-- - Compute gap clips from media clip positions on a track
-- - Locally recompute gaps after clip edits (insert/delete/trim/roll/ripple)
-- - Create implied zero-length gap clips for multitrack ripple
--
-- Non-goals:
-- - Persistence (gaps are in-memory only, discarded on sequence close)
-- - Clip manipulation (gap clips are treated as normal clips by the pipeline)
--
-- Invariants:
-- - Between any two adjacent media clips on the same track, exactly one gap (duration >= 0)
-- - Before the first media clip: one gap from position 0 (if first clip doesn't start at 0)
-- - No two gaps are ever adjacent (merge invariant)
-- - gap.sequence_start + gap.duration = next media clip's sequence_start
-- - prev media clip's sequence_start + duration = gap.sequence_start
--
-- @file gap_lifecycle.lua
local M = {}

--- Create a gap clip entity with the standard clip interface.
-- Gap clips use the same fields as media clips so the pipeline doesn't distinguish them.
local function make_gap_clip(track_id, sequence_start, duration, seq_fps)
    assert(type(track_id) == "string" or type(track_id) == "number",
        "make_gap_clip: track_id required")
    assert(type(sequence_start) == "number",
        "make_gap_clip: sequence_start must be integer, got " .. type(sequence_start))
    assert(type(duration) == "number" and duration >= 0,
        string.format("make_gap_clip: duration must be >= 0, got %s", tostring(duration)))
    assert(type(seq_fps) == "table" and seq_fps.fps_numerator and seq_fps.fps_denominator,
        "make_gap_clip: seq_fps must have fps_numerator and fps_denominator")

    -- Synthesized in-memory gap. Not a DB row. Marked is_gap=true so
    -- readers can distinguish from real (DB-backed) clips. Per FR-018,
    -- V13 has no V8-style row-discriminator.
    return {
        id = string.format("gap_%s_%d", tostring(track_id), sequence_start),
        track_id = track_id,
        sequence_start = sequence_start,
        duration = duration,
        is_gap = true,
        source_in = nil,
        source_out = nil,
        fps_numerator = seq_fps.fps_numerator,
        fps_denominator = seq_fps.fps_denominator,
        frame_rate = { fps_numerator = seq_fps.fps_numerator, fps_denominator = seq_fps.fps_denominator },
        enabled = 1,
    }
end

--- Compute all gap clips for a track from its sorted media clips.
-- Called on sequence open to populate gaps.
--
-- @param track_id string The track ID
-- @param sorted_media_clips table Array of media clips sorted by sequence_start
-- @param seq_fps table {fps_numerator, fps_denominator}
-- @return table Array of gap clips (may be empty)
function M.compute_gaps_for_track(track_id, sorted_media_clips, seq_fps)
    assert(track_id, "compute_gaps_for_track: track_id required")
    assert(type(sorted_media_clips) == "table", "compute_gaps_for_track: sorted_media_clips must be table")
    assert(seq_fps, "compute_gaps_for_track: seq_fps required")

    if #sorted_media_clips == 0 then
        return {}
    end

    local gaps = {}
    local cursor = 0  -- current position scanning left-to-right

    for _, clip in ipairs(sorted_media_clips) do
        assert(type(clip.sequence_start) == "number",
            "compute_gaps_for_track: clip.sequence_start must be integer")
        assert(type(clip.duration) == "number",
            "compute_gaps_for_track: clip.duration must be integer")

        local gap_size = clip.sequence_start - cursor
        -- gap_size < 0 means clips overlap (transient state during overwrite/insert
        -- before occlusion resolves). No gap in overlapping region.
        if gap_size > 0 then
            table.insert(gaps, make_gap_clip(track_id, cursor, gap_size, seq_fps))
        end
        -- Advance cursor past this clip (only if it extends further)
        local clip_end = clip.sequence_start + clip.duration
        if clip_end > cursor then
            cursor = clip_end
        end
    end

    return gaps
end

--- Locally recompute gaps after an edit.
-- Given the full sorted clip list (media + existing gaps) and the set of changed
-- clip IDs, recompute gap geometry for affected positions only.
--
-- @param track_id string The track ID
-- @param sorted_all_clips table Array of all clips (media + gap) sorted by sequence_start
-- @param changed_clip_ids table Set of clip IDs that changed {[id]=true}
-- @param seq_fps table {fps_numerator, fps_denominator}
-- @return table Updated array of all clips (media + gap)
function M.update_gaps_after_edit(track_id, sorted_all_clips, changed_clip_ids, seq_fps)
    assert(track_id, "update_gaps_after_edit: track_id required")
    assert(type(sorted_all_clips) == "table", "update_gaps_after_edit: sorted_all_clips must be table")
    assert(seq_fps, "update_gaps_after_edit: seq_fps required")

    -- Extract only media clips (strip existing gaps), then recompute gaps.
    -- This is correct because gaps are derived state — always recomputable
    -- from media clip positions. Local optimization can come later if needed.
    local media_clips = {}
    for _, clip in ipairs(sorted_all_clips) do
        if not clip.is_gap then
            table.insert(media_clips, clip)
        end
    end

    -- Sort by sequence_start
    table.sort(media_clips, function(a, b)
        if a.sequence_start == b.sequence_start then
            return (a.id or "") < (b.id or "")
        end
        return a.sequence_start < b.sequence_start
    end)

    -- Recompute gaps from media positions
    local gaps = M.compute_gaps_for_track(track_id, media_clips, seq_fps)

    -- Interleave media and gaps into sorted result
    local result = {}
    local gi = 1
    for _, clip in ipairs(media_clips) do
        -- Insert any gaps that come before this clip
        while gi <= #gaps and gaps[gi].sequence_start < clip.sequence_start do
            table.insert(result, gaps[gi])
            gi = gi + 1
        end
        -- Insert gap at same position (gap ends where clip starts)
        while gi <= #gaps and gaps[gi].sequence_start + gaps[gi].duration <= clip.sequence_start
              and gaps[gi].sequence_start >= (result[#result] and (result[#result].sequence_start + result[#result].duration) or 0) do
            if gaps[gi].sequence_start + gaps[gi].duration == clip.sequence_start then
                table.insert(result, gaps[gi])
            end
            gi = gi + 1
        end
        table.insert(result, clip)
    end
    -- Append remaining gaps after last clip
    while gi <= #gaps do
        table.insert(result, gaps[gi])
        gi = gi + 1
    end

    return result
end

--- Create a zero-length implied gap clip at the given position.
-- Used by multitrack ripple when clips are adjacent and no gap exists.
--
-- @param track_id string The track ID
-- @param position number Integer frame position
-- @param seq_fps table {fps_numerator, fps_denominator}
-- @return table|nil Gap clip, or nil if position is invalid
function M.create_implied_gap(track_id, position, seq_fps)
    assert(track_id, "create_implied_gap: track_id required")
    assert(type(position) == "number", "create_implied_gap: position must be integer")
    assert(seq_fps, "create_implied_gap: seq_fps required")

    return make_gap_clip(track_id, position, 0, seq_fps)
end

return M
