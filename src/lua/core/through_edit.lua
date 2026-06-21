--- core/through_edit.lua — through-edit detection predicate (spec 025
--- FR-001). A *through-edit* is an editorially-invisible cut: two adjacent
--- clips on the same track that come from the same master source track with
--- contiguous source frames, so playing across the cut is indistinguishable
--- from an uncut clip.
---
--- Pure predicate over clip property objects (the in-memory Clip fields:
--- sequence_start, duration, source_in, source_out, the master track ids,
--- and the optional audio subframes). No DB access — usable identically by
--- the renderer (chevron drawing) and the join commands.
---
--- Same-source identity is the master *track* the clip was drawn from, not
--- merely the master sequence: two clips from the same master sequence but
--- different tracks (multicam angles, split channels) are NOT a through-edit.
--- The columns are `master_layer_track_id` (video) / `master_audio_track_id`
--- (audio); spec 021 later renames them to `source_video_track_id` /
--- `source_audio_track_id`.

local M = {}

--- The master source-track id for `clip` in a `kind` ("video"/"audio")
--- timeline track. Both clips in a candidate pair share a track, hence a
--- kind. Returns nil for a master-less clip (gap/generator).
local function master_track_id(clip, kind)
    if kind == "video" then return clip.master_layer_track_id end
    if kind == "audio" then return clip.master_audio_track_id end
    assert(false, "through_edit.master_track_id: unknown track kind " .. tostring(kind))
end

--- True iff `clip_a` (left) and `clip_b` (right) form a through-edit on a
--- `kind` track. `clip_a` must precede `clip_b`.
function M.is_through_edit(clip_a, clip_b, kind)
    assert(clip_a and clip_b, "through_edit.is_through_edit: both clips required")

    local master_a = master_track_id(clip_a, kind)
    local master_b = master_track_id(clip_b, kind)
    if not master_a or not master_b then return false end  -- gap/generator: never
    if master_a ~= master_b then return false end          -- different source track

    -- Flush on the timeline: left ends exactly where right begins.
    if clip_a.sequence_start + clip_a.duration ~= clip_b.sequence_start then
        return false
    end

    -- Contiguous source frames. source_out is the exclusive one-past-last
    -- frame, so equality (not +1) means no source frames are skipped.
    if clip_a.source_out ~= clip_b.source_in then return false end

    -- Audio subframe continuity, only when both values are present.
    local a_sub = clip_a.source_out_subframe
    local b_sub = clip_b.source_in_subframe
    if a_sub ~= nil and b_sub ~= nil and a_sub ~= b_sub then return false end

    return true
end

return M
