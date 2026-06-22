--- core/through_edit.lua — through-edit detection predicate (spec 025
--- FR-001). A *through-edit* is an editorially-invisible cut: two adjacent
--- clips on the same track that come from the same master source track with
--- contiguous source frames, so playing across the cut is indistinguishable
--- from an uncut clip.
---
--- Pure predicate over clip property objects (the in-memory Clip fields:
--- sequence_start, duration, source_in, source_out, sequence_id, the master
--- layer ids, and the optional audio subframes). No DB access — usable
--- identically by the renderer (chevron drawing) and the join commands.
---
--- Same-source identity is the master *sequence* the clip was drawn from —
--- `clip.sequence_id`, the "source tape" (resolved through
--- `media_refs`→`media`). That is the field every ordinary media clip
--- actually carries; a clip with no source sequence (gap / generator) never
--- forms a through-edit.
---
--- `master_layer_track_id` (video) / `master_audio_track_id` (audio) are NOT
--- source identity — they are per-clip *layer/angle selectors* within the
--- master. NULL is the ordinary "use the default layer" value, so NULL==NULL
--- is the same layer. They refine the match only to exclude two clips from
--- the same master sequence drawn from *different explicit* tracks (multicam
--- angles, split channels): a non-NULL mismatch is NOT a through-edit. (Spec
--- 021 later renames these columns to `source_video_track_id` /
--- `source_audio_track_id`.)

local M = {}

--- The explicit master layer/angle selector for `clip` on a `kind`
--- ("video"/"audio") timeline track, or nil when the clip uses the master's
--- default layer (the ordinary case). Both clips in a candidate pair share a
--- track, hence a kind.
local function master_layer_id(clip, kind)
    if kind == "video" then return clip.master_layer_track_id end
    if kind == "audio" then return clip.master_audio_track_id end
    assert(false, "through_edit.master_layer_id: unknown track kind " .. tostring(kind))
end

--- True iff `clip_a` (left) and `clip_b` (right) form a through-edit on a
--- `kind` track. `clip_a` must precede `clip_b`.
function M.is_through_edit(clip_a, clip_b, kind)
    assert(clip_a and clip_b, "through_edit.is_through_edit: both clips required")

    -- Same source: the master sequence the clip was drawn from. A clip with
    -- no source sequence (gap/generator) never forms a through-edit.
    if not clip_a.sequence_id or not clip_b.sequence_id then return false end
    if clip_a.sequence_id ~= clip_b.sequence_id then return false end

    -- Same layer/angle within that master. NULL==NULL (both on the default
    -- layer) matches; a non-NULL mismatch is a different angle/stream.
    if master_layer_id(clip_a, kind) ~= master_layer_id(clip_b, kind) then
        return false
    end

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
