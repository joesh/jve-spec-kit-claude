--- Shared helper: build an insert/placement entry for a __timeline_mutations
--- bucket by re-reading the DB row of `clip_id`. The bucket consumer
--- (TimelineTab.apply_mutations → apply_inserts → normalize_clip_integers)
--- requires the full canonical clip-row shape; an `{id=...}` stub causes a
--- producer-bug assert (pre-audit-pass-5 silent-skipped, leaving the cache
--- stale relative to the DB until the next reload).
---
--- Use Clip.load (not load_v13_row) so the entry carries the joined
--- frame_rate from the nested sequence row — consumers that read
--- clip.frame_rate (batch_ripple_edit.fetch_base_clip,
--- clipboard_actions.copy_mark_range) require it.

local Clip = require("models.clip")

local M = {}

--- @param clip_id string
--- @param command_label string label embedded in the assert error message
--- @return table mutation-bucket entry
function M.build_insert_entry(clip_id, command_label)
    local clip = Clip.load(clip_id)
    assert(clip, string.format(
        "%s: could not re-read clip %s for insert mutation entry",
        tostring(command_label), tostring(clip_id)))
    return {
        id                    = clip.id,
        owner_sequence_id     = clip.owner_sequence_id,
        track_sequence_id     = clip.owner_sequence_id,
        track_id              = clip.track_id,
        sequence_id           = clip.sequence_id,
        sequence_start        = clip.sequence_start,
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

return M
