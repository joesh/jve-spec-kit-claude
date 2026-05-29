-- Pure track-mapping for clip duplication (alt-drag copy).
--
-- Single source of truth shared by the drag GHOST preview
-- (ui/timeline/view/timeline_view_renderer) and the COMMIT
-- (core/clip_mutator.plan_duplicate_block). Both must place a duplicated
-- clip on the same track, so both call this — no second implementation to
-- drift. No DB access, no side effects.
--
-- Semantics: the anchor clip moves from its track to `target_track` (same
-- track_type as anchor). Every selected clip shifts by the SAME per-type
-- track delta — anchor +N video tracks => audio clips +N audio tracks
-- (FR: linked V+A pairs duplicate together, audio following the anchor's
-- vertical move within its own track stack). When the destination track of
-- that type does not exist, the clip yields a `needs_create` descriptor:
-- the commit auto-creates the track (see insert.lua auto-create pattern),
-- the preview renders a phantom row. Never falls back to the source track
-- (that would silently misplace the clip — a Rule 2.13 violation).

local M = {}

-- ordered_tracks : array of model track rows, each {id, track_type, track_index}
-- anchor_track   : the grabbed clip's track row
-- target_track   : track row under the cursor (same track_type as anchor_track)
-- source_clips   : array of clips to duplicate, each with {id, track_id}
--
-- Returns: { [clip_id] = target_track_id (string)
--                       | { needs_create = true, track_type = , track_index = } }
function M.map_duplicate_targets(ordered_tracks, anchor_track, target_track, source_clips)
    assert(type(ordered_tracks) == "table", "map_duplicate_targets: ordered_tracks required")
    assert(type(anchor_track) == "table" and anchor_track.track_index,
        "map_duplicate_targets: anchor_track row required")
    assert(type(target_track) == "table" and target_track.track_index,
        "map_duplicate_targets: target_track row required")
    assert(target_track.track_type == anchor_track.track_type, string.format(
        "map_duplicate_targets: target/anchor type mismatch (%s vs %s)",
        tostring(target_track.track_type), tostring(anchor_track.track_type)))
    assert(type(source_clips) == "table", "map_duplicate_targets: source_clips required")

    -- Index the track list once: by id (to find each clip's source track)
    -- and by (type,index) (to resolve each clip's destination track).
    local by_id, by_type_index = {}, {}
    for _, t in ipairs(ordered_tracks) do
        assert(t.id and t.track_type and t.track_index,
            "map_duplicate_targets: track row missing id/track_type/track_index")
        by_id[t.id] = t
        by_type_index[t.track_type] = by_type_index[t.track_type] or {}
        by_type_index[t.track_type][t.track_index] = t
    end

    -- Per-type delta: how many tracks (within the anchor's type) the anchor
    -- moved. Applied identically inside every clip's own track type.
    local delta = target_track.track_index - anchor_track.track_index

    local result = {}
    for _, clip in ipairs(source_clips) do
        assert(clip.id, "map_duplicate_targets: source clip missing id")
        local source_track = by_id[clip.track_id]
        assert(source_track, string.format(
            "map_duplicate_targets: source clip %s on unknown track %s",
            tostring(clip.id), tostring(clip.track_id)))

        local target_index = source_track.track_index + delta
        local existing = by_type_index[source_track.track_type]
            and by_type_index[source_track.track_type][target_index]
        if existing then
            result[clip.id] = existing.id
        else
            result[clip.id] = {
                needs_create = true,
                track_type = source_track.track_type,
                track_index = target_index,
            }
        end
    end
    return result
end

return M
