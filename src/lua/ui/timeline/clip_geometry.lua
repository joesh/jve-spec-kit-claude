--- Clip geometry helpers: pure functions over clip lists. Shared by
--- TimelineTab.load_from_database / apply_mutations and
--- timeline_core_state.recompute_gap_clips_for_tab so all three pipelines
--- agree on track grouping, sort order, content extent, and integer-coord
--- normalization.

local M = {}

--- Group media clips by track_id and sort each track's list by
--- sequence_start (ties broken by clip id for determinism). Asserts on
--- missing track_id — gaps and orphans both indicate a producer bug.
function M.group_and_sort_media_by_track(media_clips)
    local by_track = {}
    for _, c in ipairs(media_clips) do
        assert(c.track_id and c.track_id ~= "", string.format(
            "clip_geometry: clip %s missing track_id", tostring(c.id)))
        local list = by_track[c.track_id]
        if not list then list = {}; by_track[c.track_id] = list end
        table.insert(list, c)
    end
    for _, list in pairs(by_track) do
        table.sort(list, function(a, b)
            if a.sequence_start == b.sequence_start then return a.id < b.id end
            return a.sequence_start < b.sequence_start
        end)
    end
    return by_track
end

--- Last frame occupied by any clip in the list (0 for empty list).
--- Asserts canonical integer coords — any non-number on a clip-shaped row
--- is a producer bug (loader, mutation apply, importer). Silent skip would
--- corrupt scrollbar bounds + viewport policy with no diagnostic (rule 1.14).
function M.compute_content_length(clips)
    local max_end = 0
    for _, c in ipairs(clips) do
        assert(type(c.sequence_start) == "number", string.format(
            "clip_geometry.compute_content_length: clip %s missing sequence_start",
            tostring(c.id)))
        assert(type(c.duration) == "number", string.format(
            "clip_geometry.compute_content_length: clip %s missing duration",
            tostring(c.id)))
        local e = c.sequence_start + c.duration
        if e > max_end then max_end = e end
    end
    return max_end
end

--- Assert canonical integer coords on a clip-shaped row. Post-M4-real
--- (2026-05-27), mutation payloads use the same canonical field names as
--- clip rows — no `_value` aliases to bridge. Any missing/invalid coord
--- is a producer bug; previous boolean-return-on-skip silently dropped
--- clips from apply_inserts, masking real bugs (rule 1.14 / 2.13 / 2.32).
function M.normalize_clip_integers(clip)
    assert(clip, "clip_geometry.normalize_clip_integers: clip required")
    assert(type(clip.sequence_start) == "number", string.format(
        "clip_geometry: clip %s sequence_start must be number, got %s",
        tostring(clip.id), type(clip.sequence_start)))
    assert(type(clip.duration) == "number" and clip.duration > 0, string.format(
        "clip_geometry: clip %s duration must be positive number, got %s",
        tostring(clip.id), tostring(clip.duration)))
    if clip.source_in ~= nil then
        assert(type(clip.source_in) == "number", string.format(
            "clip_geometry: clip %s source_in must be number", tostring(clip.id)))
    end
    if clip.source_out ~= nil then
        assert(type(clip.source_out) == "number", string.format(
            "clip_geometry: clip %s source_out must be number", tostring(clip.id)))
    end
end

return M
