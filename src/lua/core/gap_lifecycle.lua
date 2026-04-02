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
-- - gap.timeline_start + gap.duration = next media clip's timeline_start
-- - prev media clip's timeline_start + duration = gap.timeline_start
--
-- @file gap_lifecycle.lua
local M = {}

--- Create a gap clip entity with the standard clip interface.
-- Gap clips use the same fields as media clips so the pipeline doesn't distinguish them.
local function make_gap_clip(track_id, timeline_start, duration, seq_fps)
    assert(type(track_id) == "string" or type(track_id) == "number",
        "make_gap_clip: track_id required")
    assert(type(timeline_start) == "number",
        "make_gap_clip: timeline_start must be integer, got " .. type(timeline_start))
    assert(type(duration) == "number" and duration >= 0,
        string.format("make_gap_clip: duration must be >= 0, got %s", tostring(duration)))
    assert(type(seq_fps) == "table" and seq_fps.fps_numerator and seq_fps.fps_denominator,
        "make_gap_clip: seq_fps must have fps_numerator and fps_denominator")

    return {
        id = string.format("gap_%s_%d", tostring(track_id), timeline_start),
        track_id = track_id,
        timeline_start = timeline_start,
        duration = duration,
        clip_kind = "gap",
        media_id = nil,
        source_in = nil,
        source_out = nil,
        fps_numerator = seq_fps.fps_numerator,
        fps_denominator = seq_fps.fps_denominator,
        rate = { fps_numerator = seq_fps.fps_numerator, fps_denominator = seq_fps.fps_denominator },
        enabled = 1,
    }
end

--- Compute all gap clips for a track from its sorted media clips.
-- Called on sequence open to populate gaps.
--
-- @param track_id string The track ID
-- @param sorted_media_clips table Array of media clips sorted by timeline_start
-- @param seq_fps table {fps_numerator, fps_denominator}
-- @return table Array of gap clips (may be empty)
function M.compute_gaps_for_track(track_id, sorted_media_clips, seq_fps)
    return {}
end

--- Locally recompute gaps after an edit.
-- Given the full sorted clip list (media + existing gaps) and the set of changed
-- clip IDs, recompute gap geometry for affected positions only.
--
-- @param track_id string The track ID
-- @param sorted_all_clips table Array of all clips (media + gap) sorted by timeline_start
-- @param changed_clip_ids table Set of clip IDs that changed {[id]=true}
-- @param seq_fps table {fps_numerator, fps_denominator}
-- @return table Updated array of all clips (media + gap)
function M.update_gaps_after_edit(track_id, sorted_all_clips, changed_clip_ids, seq_fps)
    return {}
end

--- Create a zero-length implied gap clip at the given position.
-- Used by multitrack ripple when clips are adjacent and no gap exists.
--
-- @param track_id string The track ID
-- @param position number Integer frame position
-- @param seq_fps table {fps_numerator, fps_denominator}
-- @return table|nil Gap clip, or nil if position is invalid
function M.create_implied_gap(track_id, position, seq_fps)
    return nil
end

return M
